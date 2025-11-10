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

let browser = null;

async function getBrowser()
{
    if (!browser) {
        browser = await puppeteer.launch({
            headless: 'new',
            args: [
                '--no-sandbox',
                '--disable-setuid-sandbox',
                '--disable-dev-shm-usage',
                '--disable-accelerated-2d-canvas',
                '--disable-gpu'
            ]
        });
    }
    return browser;
}

async function getPage()
{
    const browser = await getBrowser();
    const page = await browser.newPage();

    // Set a realistic viewport
    await page.setViewport({ width: 1920, height: 1080 });

    // Set additional headers
    await page.setExtraHTTPHeaders({
        'Accept-Language': 'en-US,en;q=0.9'
    });

    return page;
}

function syncDirectory(collection, next)
{
    fs.readdir(collection.name, function(err, files)
    {
        if (err) { return next(err); }

        async.eachLimit(files, 20, function(file, nextFile)
        {
            var fullPath = path.join(collection.name, file);
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
    const page = await getPage();

    try {
        await page.goto(url, {
            waitUntil: 'networkidle0',
            timeout: 60000
        });

        // Wait a bit for any dynamic content
        // await page.waitForTimeout(1000);

        const html = await page.content();
        await page.close();
        return html;
    } catch (err) {
        console.error('Error fetching', url, ':', err.message);
        await page.close();
        throw err;
    }
}

async function downloadWithPuppeteer(url)
{
    const page = await getPage();

    try {
        const response = await page.goto(url, {
            waitUntil: 'networkidle0',
            timeout: 60000
        });
        const buffer = await response.buffer();
        await page.close();
        return buffer;
    } catch (err) {
        await page.close();
        throw err;
    }
}

function fetchCover(collection, cover, next)
{
    var url = cover[1];
    var filename = path.join(collection.name, cover[0]);
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
        console.log("Empty name for collection\n" + JSON.stringify(collection, null, 4));
        next(collection);
        return;
    }
    fs.mkdir(collection.name, function(err)
    {
        if (err && err.code !== 'EEXIST') {
            console.log(collection.name + ' mkdir: ' + err);
            next(err);
            return;
        }

        syncDirectory(collection, function(err)
        {
            if (err) { return next(err); }

            async.eachLimit(collection.covers, 5, function(cover, nextCover)
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

    if (collection.name.length === 0) {
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
        collection.name = tmp[1].trim().replace(/[?:]/g, '');
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
    fetchWithPuppeteer(collection.url + '?page=' + page)
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
            next();
        });
}

function fetchCollection(collections, url, next)
{
    var page = 1;
    var collection = { url: url, name: '', covers: [], added: [], removed: [], zero: [] };
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
    fs.readFile(urlFile, { encoding: 'utf8' }, function(err, data)
    {
        if (err) { console.log("Err: " + err); return err; }

        var urls = JSON.parse(data);
        var collections = [];
        async.eachLimit(urls, 10, function(url, next)
        {
            fetchCollection(collections, url.url, next);
        }, async function()
        {
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
            process.exit(0);
        });
    });
}

main();
