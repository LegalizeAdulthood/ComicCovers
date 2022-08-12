'use strict';

const async = require('async');
const cheerio = require('cheerio');
const fs = require('fs');
const path = require('path');
const request = require('request');
const _ = require('underscore');

var page = 1;
var collection = { "url": 'https://my.comics.org/collection/33548', "name": '', "covers": [] };
function processPage(html)
{
    const $ = cheerio.load(html);
    var pageNum = parseInt($($('ul.pagination li.active')[0]).text());
    if (page !== pageNum)
        return false;

    if (collection.name.length === 0) {
        collection.name = /Collection details: *(.*[^\s])\s+\//.exec($('h1').text())[1];
        console.log('Collection: ' + collection.name);
    }
    console.log('Page ' + page);
    $('div .thumbnail').each(function(index, elem) {
        var url = $(this).find('img')[0].attribs['src'];
        url = /^(.*)\?/.exec(url)[1].replace('/w100', '/w400');
        var pieces = /^(.*[^\s])\s\(.*\) #([0-9]+)/.exec($(this).find('div .caption').text());
        var name = (pieces[1] + ' #' + pieces[2]).replace(/ /g, '').replace(/The/g, '').replace(/[\?:]/g, '');
        collection.covers.push([name, url]);
    });
    ++page;
    return true;
}

function fetchPage(page, next)
{
    request(collection.url + '/?page=' + page, function(err, res, html) {
        if (err) {
            next(err);
            return;
        }
        if (processPage(html))
            fetchPage(++page, next);
        else
            next();
    });
}

function fetchCover(cover, next)
{
    var url = cover[1];
    var filename = path.join(collection.name, cover[0] + '.jpg');
    console.log('Fetch ' + url + ' as ' + filename);
    request(url, next).pipe(fs.createWriteStream(filename));
}

function processCollection()
{
    fs.mkdir(collection.name, function() {
        async.eachLimit(collection.covers, 5, fetchCover, function() {
            console.log('Done');
        });
    });
}

fetchPage(page, function() {
    processCollection();
});
