'use strict';

const async = require('async');
const cheerio = require('cheerio');
const fs = require('fs');
const path = require('path');
const process = require('process');
const _ = require('underscore');
const puppeteer = require('puppeteer-extra');
const StealthPlugin = require('puppeteer-extra-plugin-stealth');

puppeteer.use(StealthPlugin());

const BROWSER_EXE = findBrowserExecutable();
let browser = null;
let scrapePage = null;
const BROWSER_PROFILE_DIR = process.env.COMIC_COVERS_BROWSER_PROFILE || path.join(__dirname, defaultBrowserProfileName(BROWSER_EXE));
const CLOUDFLARE_TIMEOUT_MS = readPositiveInt(process.env.COMIC_COVERS_CLOUDFLARE_TIMEOUT_MS, 180000);
const COLLECTION_CONCURRENCY = readPositiveInt(process.env.COMIC_COVERS_COLLECTION_CONCURRENCY, 1);
const COVER_CONCURRENCY = readPositiveInt(process.env.COMIC_COVERS_COVER_CONCURRENCY, 1);
const NAVIGATION_TIMEOUT_MS = readPositiveInt(process.env.COMIC_COVERS_NAVIGATION_TIMEOUT_MS, 90000);
const REQUEST_DELAY_MS = readPositiveInt(process.env.COMIC_COVERS_REQUEST_DELAY_MS, 1500);
const HEADLESS = /^(1|true|yes)$/i.test(process.env.COMIC_COVERS_HEADLESS || '');
const WARM_UP_CLOUDFLARE = /^(1|true|yes)$/i.test(process.env.COMIC_COVERS_WARM_UP || '');
let nextBrowserOperation = Promise.resolve();

function readPositiveInt(value, defaultValue)
{
    const parsed = Number(value);
    if (Number.isFinite(parsed) && parsed > 0) {
        return parsed;
    }
    return defaultValue;
}

function sleep(ms)
{
    return new Promise(function(resolve) { setTimeout(resolve, ms); });
}

function envValue(name)
{
    return process.env[name] || process.env[name.toUpperCase()] || process.env[name.toLowerCase()];
}

function addBrowserCandidate(candidates, base, relativePath)
{
    if (base) {
        candidates.push(path.join(base, relativePath));
    }
}

function findBrowserExecutable()
{
    const configured = process.env.COMIC_COVERS_BROWSER_EXE;
    if (configured) {
        if (!fs.existsSync(configured)) {
            throw new Error('COMIC_COVERS_BROWSER_EXE does not exist: ' + configured);
        }
        return configured;
    }

    const candidates = [];
    addBrowserCandidate(candidates, envValue('ProgramFiles'), 'BraveSoftware\\Brave-Browser\\Application\\brave.exe');
    addBrowserCandidate(candidates, envValue('ProgramFiles(x86)'), 'BraveSoftware\\Brave-Browser\\Application\\brave.exe');
    addBrowserCandidate(candidates, envValue('LocalAppData'), 'BraveSoftware\\Brave-Browser\\Application\\brave.exe');
    addBrowserCandidate(candidates, envValue('ProgramFiles'), 'Google\\Chrome\\Application\\chrome.exe');
    addBrowserCandidate(candidates, envValue('ProgramFiles(x86)'), 'Google\\Chrome\\Application\\chrome.exe');
    addBrowserCandidate(candidates, envValue('LocalAppData'), 'Google\\Chrome\\Application\\chrome.exe');

    for (const candidate of candidates) {
        if (fs.existsSync(candidate)) {
            return candidate;
        }
    }

    return puppeteer.executablePath();
}

function defaultBrowserProfileName(browserExe)
{
    if (/brave\.exe$/i.test(browserExe || '')) {
        return '.browser-profile-brave';
    }
    return '.browser-profile';
}

async function withScrapePage(operation)
{
    const previousOperation = nextBrowserOperation;
    let release;
    nextBrowserOperation = new Promise(function(resolve) { release = resolve; });
    await previousOperation;

    try {
        const page = await getScrapePage();
        await sleep(REQUEST_DELAY_MS);
        return await operation(page);
    } finally {
        release();
    }
}

async function getBrowser()
{
    if (!browser) {
        browser = await puppeteer.launch({
            executablePath: BROWSER_EXE,
            headless: HEADLESS ? 'new' : false,
            userDataDir: BROWSER_PROFILE_DIR,
            args: [
                '--no-sandbox',
                '--disable-setuid-sandbox',
                '--disable-dev-shm-usage',
                '--disable-accelerated-2d-canvas',
                '--disable-gpu',
                '--window-size=1366,900'
            ]
        });
        console.log('Browser executable: ' + BROWSER_EXE);
        console.log('Browser profile: ' + BROWSER_PROFILE_DIR);
        if (!HEADLESS) {
            console.log('If Cloudflare asks, complete the check in the Chromium window. The clearance will be reused.');
        }
    }
    return browser;
}

async function configurePage(page)
{
    page.setDefaultNavigationTimeout(NAVIGATION_TIMEOUT_MS);
    page.setDefaultTimeout(NAVIGATION_TIMEOUT_MS);

    await page.setViewport({ width: 1366, height: 900 });

    await page.setExtraHTTPHeaders({
        'Accept-Language': 'en-US,en;q=0.9'
    });
}

async function newConfiguredPage()
{
    const browser = await getBrowser();
    const page = await browser.newPage();

    await configurePage(page);

    return page;
}

async function getScrapePage()
{
    if (!scrapePage || scrapePage.isClosed()) {
        scrapePage = await newConfiguredPage();
    }
    return scrapePage;
}

function isCloudflareChallenge(html)
{
    if (!html) {
        return false;
    }
    if (isCollectionPage(html)) {
        return false;
    }

    const $ = cheerio.load(html);
    const title = $('title').text().trim().toLowerCase();
    const bodyText = $('body').text().replace(/\s+/g, ' ').trim().toLowerCase();
    const lowerHtml = html.toLowerCase();

    return title === 'just a moment...' ||
        (title.indexOf('attention required') !== -1 && title.indexOf('cloudflare') !== -1) ||
        bodyText.indexOf('checking if the site connection is secure') !== -1 ||
        bodyText.indexOf('review the security of your connection') !== -1 ||
        (bodyText.indexOf('verify you are human') !== -1 && bodyText.indexOf('cloudflare') !== -1) ||
        (bodyText.indexOf('enable javascript and cookies to continue') !== -1 && bodyText.indexOf('cloudflare') !== -1) ||
        (lowerHtml.indexOf('cf-turnstile') !== -1 && bodyText.indexOf('verify') !== -1 && bodyText.indexOf('cloudflare') !== -1);
}

function isCollectionPage(html)
{
    const $ = cheerio.load(html || '');
    const h1Text = $('h1').text();
    return /Collection Details:/i.test(h1Text) || $('div .thumbnail img').length > 0;
}

function isLoginPage(page, html)
{
    const currentUrl = page.url();
    const lowerHtml = (html || '').toLowerCase();
    return /\/accounts\/login\/|\/login\//i.test(currentUrl) ||
        lowerHtml.indexOf('name="username"') !== -1 && lowerHtml.indexOf('name="password"') !== -1 ||
        lowerHtml.indexOf('sign in') !== -1 && lowerHtml.indexOf('password') !== -1;
}

async function getPageContent(page)
{
    for (let attempt = 0; attempt < 3; ++attempt) {
        try {
            return await page.content();
        } catch (err) {
            await sleep(1000);
        }
    }
    return await page.content();
}

async function hasCloudflareClearance(page, url)
{
    try {
        const cookies = await page.cookies(url);
        return _.some(cookies, function(cookie)
        {
            return cookie.name === 'cf_clearance';
        });
    } catch (err) {
        return false;
    }
}

async function waitForReadablePage(page, url)
{
    await page.waitForNetworkIdle({ idleTime: 500, timeout: 10000 }).catch(function() {});
    const html = await getPageContent(page);
    if (isLoginPage(page, html)) {
        throw new Error('Collection page redirected to login after Cloudflare: ' + page.url());
    }
    if (isCloudflareChallenge(html)) {
        return null;
    }
    return html;
}

async function waitForCloudflare(page, url)
{
    let html = await getPageContent(page);
    if (!isCloudflareChallenge(html)) {
        if (isLoginPage(page, html)) {
            throw new Error('Collection page redirected to login: ' + page.url());
        }
        return { html: html, challenged: false };
    }

    if (HEADLESS) {
        throw new Error('Cloudflare challenge detected for ' + url +
            '. Run without COMIC_COVERS_HEADLESS so the browser window can complete the check once.');
    }

    console.log('Cloudflare challenge for ' + url);
    console.log('Waiting up to ' + Math.ceil(CLOUDFLARE_TIMEOUT_MS / 1000) + ' seconds for the browser to clear it...');
    await page.bringToFront().catch(function() {});

    const deadline = Date.now() + CLOUDFLARE_TIMEOUT_MS;
    let lastProgressSeconds = 0;
    while (Date.now() < deadline) {
        await sleep(2000);

        const waitedSeconds = Math.floor((CLOUDFLARE_TIMEOUT_MS - (deadline - Date.now())) / 1000);
        if (waitedSeconds - lastProgressSeconds >= 15) {
            lastProgressSeconds = waitedSeconds;
            console.log('Still waiting for Cloudflare clearance for ' + url + ' (' + waitedSeconds + 's)');
        }

        if (await hasCloudflareClearance(page, url)) {
            console.log('Cloudflare clearance cookie found; reloading requested page...');
            await page.goto(url, {
                waitUntil: 'domcontentloaded',
                timeout: NAVIGATION_TIMEOUT_MS
            });
            html = await waitForReadablePage(page, url);
            if (html) {
                return { html: html, challenged: true };
            }
        }

        html = await getPageContent(page);
        if (!isCloudflareChallenge(html)) {
            html = await waitForReadablePage(page, url);
            if (html) {
                return { html: html, challenged: true };
            }
        }
    }

    throw new Error('Timed out waiting for Cloudflare challenge to clear for ' + url);
}

function syncDirectory(collection, next)
{
    fs.readdir(collection.dir, function(err, files)
    {
        if (err) { return next(err); }

        async.eachLimit(files, 20, function(file, nextFile)
        {
            var fullPath = path.join(collection.dir, file);
            if (!_.find(collection.covers, function(cover) { return cover[0] === file; })) {
                collection.removed.push(file);
                fs.unlink(fullPath, nextFile);
                return;
            }
            fs.stat(fullPath, function(err, stats)
            {
                if (err) {
                    nextFile(err); return;
                }
                if (stats.size === 0) {
                    collection.zero.push(file);
                    fs.unlink(fullPath, nextFile);
                    return;
                }
                nextFile();
            });
        }, next);
    });
}

async function fetchWithPuppeteer(url)
{
    try {
        return await withScrapePage(async function(page)
        {
            await page.goto(url, {
                waitUntil: 'domcontentloaded',
                timeout: NAVIGATION_TIMEOUT_MS
            });

            const result = await waitForCloudflare(page, url);
            return result.html;
        });
    } catch (err) {
        console.error('Error fetching', url, ':', err.message);
        throw err;
    }
}

async function downloadWithPuppeteer(url)
{
    try {
        return await withScrapePage(async function(page)
        {
            let response = await page.goto(url, {
                waitUntil: 'domcontentloaded',
                timeout: NAVIGATION_TIMEOUT_MS
            });
            const result = await waitForCloudflare(page, url);
            if (result.challenged || !response || !/^image\//i.test(response.headers()['content-type'] || '')) {
                response = await page.goto(url, {
                    waitUntil: 'networkidle2',
                    timeout: NAVIGATION_TIMEOUT_MS
                });
            }

            const contentType = response ? response.headers()['content-type'] || '' : '';
            if (!/^image\//i.test(contentType)) {
                throw new Error('Expected image from ' + url + ', got ' + (contentType || 'no content type'));
            }

            return await response.buffer();
        });
    } catch (err) {
        throw err;
    }
}

function fetchCover(collection, cover, next)
{
    var url = cover[1];
    var filename = path.join(collection.dir, cover[0]);
    fs.access(filename, fs.constants.F_OK, function(err)
    {
        if (err) {
            // file does not (yet) exist
            collection.added.push(cover[0]);
            downloadWithPuppeteer(url)
                .then(function(body)
                {
                    fs.writeFile(filename, body, next);
                })
                .catch(next);
        } else {
            next();
        }
    });
}

function processCollection(collection, next)
{
    if (collection.name === '') {
        var err = new Error("Empty name for collection\n" + JSON.stringify(collection, null, 4));
        console.log(err.message);
        next(err);
        return;
    }
    fs.mkdir(collection.dir, function(err)
    {
        if (err && err.code !== 'EEXIST') {
            console.log(collection.name + ' mkdir: ' + err);
            next(err);
            return;
        }

        syncDirectory(collection, function(err)
        {
            if (err) { return next(err); }

            async.eachLimit(collection.covers, COVER_CONCURRENCY, function(cover, nextCover)
            {
                fetchCover(collection, cover, nextCover);
            }, next);
        });
    });
}

function processPage(collection, page, html)
{
    const $ = cheerio.load(html);
    var activeListItems = $('ul.pagination li.active');
    var pageNum = 1;
    if (activeListItems.length > 0)
        pageNum = parseInt($(activeListItems[0]).text());
    if (page !== pageNum)
        return false;

    if (collection.remoteName.length === 0) {
        var h1 = $('h1');
        if (h1.length === 0) {
            console.log('Malformed collection ' + collection.url + '; no h1 found');
            return false;
        }

        var h1Text = h1.text().trim();
        var tmp = /Collection Details:\s*(.+?)(?:\s*\/|$)/s.exec(h1Text);
        if (!tmp) {
            console.log('ERROR: Could not parse collection name from H1:', h1Text);
            return false;
        }

        collection.remoteName = tmp[1].trim().replace(/[?:]/g, '');
        if (collection.name.length === 0) {
            collection.name = collection.remoteName;
            collection.dir = path.join(collection.baseDir, collection.name);
        }
        console.log('Collection: ' + collection.name);
    }

    $('div .thumbnail').each(function(index, elem)
    {
        var imgElem = $(this).find('img')[0];
        if (!imgElem || !imgElem.attribs || !imgElem.attribs['src']) {
            return;
        }
        var url = imgElem.attribs['src'];
        if (/noupload/.test(url))
            return;

        if (/nocover/.test(url)) {
            url = 'https://files1.comics.org/static/img/nocover_large.png';
        } else {
            // Handle URLs that might not have a query string
            var urlMatch = /^(.*?)(\?|$)/.exec(url);
            if (urlMatch) {
                url = urlMatch[1].replace('/w100', '/w400');
            }
        }

        var issueName = $(this).find('div .caption').text().trim();
        if (!issueName) {
            return;
        }

        var pieces = /^(.*[^\s])\s+\(.* ([0-9]+) series\)\s+#([-0-9]+)/.exec(issueName);
        var name;
        if (pieces !== null) {
            name = pieces[1] + '(' + pieces[2] + ')#' + pieces[3];
        } else {
            pieces = /^(.*[^\s])\s+\(.* ([0-9]+) series\)/.exec(issueName);
            if (pieces !== null) {
                name = pieces[1] + '(' + pieces[2] + ')';
            } else {
                console.log('Could not parse issue name:', issueName);
                return;
            }
        }
        name = name.replace(/ /g, '').replace(/The/g, '').replace(/[?:/'";&*$^{}[\]|\\<>]/g, '');
        collection.covers.push([name + '.jpg', url]);
    });
    ++page;
    return true;
}

function fetchPage(collection, page, next)
{
    fetchWithPuppeteer(collectionPageUrl(collection.url, page))
        .then(function(html)
        {
            if (processPage(collection, page, html)) {
                fetchPage(collection, ++page, next);
            } else {
                next();
            }
        })
        .catch(function(err)
        {
            console.log(collection.url + ' error: ' + err.message);
            next(err);
        });
}

function fetchCollection(collections, entry, baseDir, next)
{
    var page = 1;
    var collection = {
        url: entry.url,
        name: (entry.name || '').replace(/[?:]/g, ''),
        remoteName: '',
        baseDir: baseDir,
        dir: '',
        covers: [],
        added: [],
        removed: [],
        zero: []
    };
    if (collection.name.length > 0) {
        collection.dir = path.join(collection.baseDir, collection.name);
    }
    fetchPage(collection, page, function(err)
    {
        if (err) { next(err); return; }

        processCollection(collection, function(err)
        {
            collections.push(collection);
            next(err);
        });
    });
}

function configuredCollectionNames(urls, collections)
{
    var names = _.map(urls, function(entry)
    {
        return (entry.name || '').replace(/[?:]/g, '');
    });

    names = names.concat(_.map(collections, function(collection)
    {
        return collection.name || '';
    }));

    return new Set(names.filter(function(name)
    {
        return name.length > 0;
    }));
}

function pruneUnlistedCollections(urls, baseDir, collections, next)
{
    var configuredNames = configuredCollectionNames(urls, collections);
    fs.readdir(baseDir, { withFileTypes: true }, function(err, entries)
    {
        if (err) { return next(err); }

        async.eachLimit(entries, 5, function(entry, nextEntry)
        {
            if (!entry.isDirectory() || configuredNames.has(entry.name)) {
                nextEntry();
                return;
            }

            pruneUnlistedCollection(baseDir, entry.name, collections, nextEntry);
        }, next);
    });
}

function pruneUnlistedCollection(baseDir, name, collections, next)
{
    var dir = path.join(baseDir, name);
    fs.readdir(dir, function(err, files)
    {
        if (err) { return next(err); }

        var collection = {
            url: '',
            name: name,
            remoteName: '',
            baseDir: baseDir,
            dir: dir,
            covers: [],
            added: [],
            removed: [],
            zero: []
        };

        async.eachLimit(files, 20, function(file, nextFile)
        {
            if (!/\.jpg$/i.test(file)) {
                nextFile();
                return;
            }

            fs.unlink(path.join(dir, file), function(err)
            {
                if (!err) {
                    collection.removed.push(file);
                }
                nextFile(err);
            });
        }, function(err)
        {
            if (err) { return next(err); }

            if (collection.removed.length === 0) {
                next();
                return;
            }

            fs.rmdir(dir, function(err)
            {
                if (err && err.code !== 'ENOTEMPTY') {
                    next(err);
                    return;
                }

                collections.push(collection);
                next();
            });
        });
    });
}

function collectionPageUrl(collectionUrl, page)
{
    const url = new URL(collectionUrl);
    url.searchParams.set('page', String(page));
    return url.href;
}

async function warmUpCloudflare(urls)
{
    const first = _.find(urls, function(url) { return url && url.url; });
    if (!first) {
        return;
    }

    const url = collectionPageUrl(first.url, 1);
    console.log('Checking browser clearance for ' + url);
    await fetchWithPuppeteer(url);
}

function coverSortKey(file)
{
    var leftParen = file.indexOf('(');
    var rightParen = file.indexOf(')');
    var hash = file.indexOf('#');
    var dot = file.lastIndexOf('.');
    return file.substr(0, leftParen) + '.' + file.substr(leftParen + 1, rightParen - leftParen - 1) + '.' +
        String(1000 + Number(file.substr(hash + 1, dot - hash - 1))).substr(1);
}

function printCollection(collection, covers, prefix)
{
    if (covers.length) {
        console.log(collection + ' ' + prefix + ':');
        _.each(_.sortBy(covers, coverSortKey), function(name) { console.log(name); });
    }
}

async function main()
{
    if (process.argv.length !== 3) {
        console.log("node app.js <url-file>");
        process.exit(1);
    }

    var urlFile = process.argv[2];
    fs.readFile(urlFile, { encoding: 'utf8' }, async function(err, data)
    {
        if (err) { console.log("Err: " + err); return err; }

        var urls = JSON.parse(data);
        var baseDir = path.dirname(path.resolve(urlFile));
        var collections = [];

        if (WARM_UP_CLOUDFLARE) {
            try {
                await warmUpCloudflare(urls);
            } catch (err) {
                console.log('ERROR: ' + (err.message || err));
                if (browser) {
                    await browser.close();
                }
                process.exit(1);
                return;
            }
        }

        async.eachLimit(urls, COLLECTION_CONCURRENCY, function(url, next)
        {
            fetchCollection(collections, url, baseDir, next);
        }, async function(err)
        {
            if (err) {
                console.log('ERROR: ' + (err.message || err));
            } else {
                try {
                    await new Promise(function(resolve, reject)
                    {
                        pruneUnlistedCollections(urls, baseDir, collections, function(err)
                        {
                            if (err) {
                                reject(err);
                            } else {
                                resolve();
                            }
                        });
                    });
                } catch (pruneErr) {
                    err = pruneErr;
                    console.log('ERROR: ' + (err.message || err));
                }
            }
            _.each(collections, function(collection)
            {
                printCollection(collection.name, collection.added, 'added');
                printCollection(collection.name, collection.removed, 'removed');
                printCollection(collection.name, collection.zero, 'removed zero-length');
                if (collection.added.length + collection.removed.length + collection.zero.length) {
                    console.log('');
                }
            });

            // Close browser when done
            if (browser) {
                await browser.close();
            }
            process.exit(err ? 1 : 0);
        });
    });
}

main();
