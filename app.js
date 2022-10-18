'use strict';

const async = require('async');
const cheerio = require('cheerio');
const fs = require('fs');
const path = require('path');
const process = require('process');
const request = require('request');
const _ = require('underscore');

function fetchCover(collection, cover, next)
{
    var url = cover[1];
    var filename = path.join(collection.name, cover[0] + '.jpg');
    fs.access(filename, fs.constants.F_OK, function(err) {
        if (err) {
            // file does not (yet) exist
            console.log('Fetch ' + url + ' as ' + filename);
            request(url, next).pipe(fs.createWriteStream(filename));
        } else {
            console.log('Skipping ' + filename);
            next();
        }
    });
}

function processCollection(collection, next)
{
    if (collection.name === '') {
        console.log(JSON.stringify(collection, null, 4));
        next(collection);
        return;
    }
    fs.mkdir(collection.name, function(err) {
        if (err && err.code !== 'EEXIST') {
            console.log(collection.name + ' mkdir: ' + err);
            next(err);
            return;
        }

        async.eachLimit(collection.covers, 5, function(cover, nextCover) { fetchCover(collection, cover, nextCover); }, next);
    });
}

function processPage(collection, page, html)
{
    const $ = cheerio.load(html);
    var pageNum = parseInt($($('ul.pagination li.active')[0]).text());
    if (page !== pageNum)
        return false;

    if (collection.name.length === 0) {
        collection.name = /Collection details: *(.*[^\s])\s+\//.exec($('h1').text())[1].replace(/[?:]/g, '');
        console.log('Collection: ' + collection.name);
    }
    console.log(collection.name + ' Page ' + page);
    $('div .thumbnail').each(function(index, elem) {
        var url = $(this).find('img')[0].attribs['src'];
        if (/noupload/.test(url))
            return;

        url = /nocover/.test(url) ?
            'https://files1.comics.org/static/img/nocover_large.png' :
            /^(.*)\?/.exec(url)[1].replace('/w100', '/w400');
        var issueName = $(this).find('div .caption').text();
        var pieces = /^(.*[^\s])\s\(.* ([0-9]+) series\) #([0-9]+)/.exec(issueName);
        var name;
        if (pieces !== null) {
            name = pieces[1] + '(' + pieces[2] + ')#' + pieces[3];
        } else {
            pieces = /^(.*[^\s])\s\(.* ([0-9]+) series\)/.exec(issueName);
            name = pieces[1] + '(' + pieces[2] + ')';
        }
        name = name.replace(/ /g, '').replace(/The/g, '').replace(/[?:/'";&*$^{}[\]|\\<>]/g, '');
        collection.covers.push([name, url]);
    });
    ++page;
    return true;
}

function fetchPage(collection, page, next)
{
    request(collection.url + '?page=' + page, function(err, res, html) {
        if (err) {
            next(err);
            return;
        }
        if (processPage(collection, page, html))
            fetchPage(collection, ++page, next);
        else
            next();
    });
}

function fetchCollection(url, next)
{
    var page = 1;
    var collection = { url: url, name: '', covers: [] };
    fetchPage(collection, page, function(err) {
        if (err) { next(err); return; }

        processCollection(collection, next);
    });
}

function main()
{
    if (process.argv.length !== 3) {
        console.log("node app.js <url-file>");
        process.exit(1);
    }

    var urlFile = process.argv[2];
    fs.readFile(urlFile, { encoding: 'utf8' }, function(err, data) {
        if (err) { console.log("Err: " + err); return err; }

        data = data.trim().replace(/\r/g, '');
        var urls = data.split("\n");
        async.eachLimit(urls, 10, fetchCollection);
    });
}

main();
