'use strict';

const cheerio = require('cheerio');
const request = require('request');

var page = 1;
var collection = {"name": "", "covers": []};
function processPage(html)
{
    const $ = cheerio.load(html);
    if (collection.name.length === 0)
        collection.name = /Collection details: *(.*[^\s])\s+\//.exec($('h1').text())[1];
    $('div .thumbnail').each(function(index, elem) {
        var url = $(this).find('img')[0].attribs['src'];
        url = /^(.*)\?/.exec(url)[1].replace('/w100', '/w400');
        var pieces = /^(.*[^\s])\s\(.*\) #([0-9]+)/.exec($(this).find('div .caption').text());
        var name = (pieces[1] + ' #' + pieces[2]).replace(/ /g, '');
        collection.covers.push([name, url]);
    });
    var pageNum = parseInt($($('ul.pagination li.active')[0]).text());
    return page++ === pageNum;
}

function fetchPage(page, next)
{
    request('https://my.comics.org/collection/33548/?page=' + page, function(err, res, html) {
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

fetchPage(page, function() {
    console.log(JSON.stringify(collection, null, 4));
});
