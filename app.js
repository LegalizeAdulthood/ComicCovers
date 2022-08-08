'use strict';

const cheerio = require('cheerio');
const request = require('request');

request('https://my.comics.org/collection/33548/', function(err, res, html) {
    const $ = cheerio.load(html);
    $('div .thumbnail').each(function(index, elem) {
        var url = $(this).find('img')[0].attribs['src'];
        url = /^(.*)\?/.exec(url)[1].replace('/w100', '/w400');
        var pieces = /^(.*[^\s])\s\(.*\) #([0-9]+)/.exec($(this).find('div .caption').text());
        var name = (pieces[1] + ' #' + pieces[2]).replace(/ /g, '');
        console.log('url=' + url);
        console.log('name=' + name);
    });
});
