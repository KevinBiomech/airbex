var template = require('./index.html')
, _ = require('lodash')

function depthToAccumulative(depth) {
    function toHash(pairs) {
        return _.reduce(pairs, function(p, c) {
            p[c[0]] = c[1]
            return p
        }, {})
    }

    if (depth.bids.length && depth.asks.length) {
        var center = (parseFloat(depth.bids[0][0]) + parseFloat(depth.asks[0][0])) / 2
        , maxSpread = 0.4

        depth.bids = depth.bids.filter(function(x) {
            return x[0] >= center * (1 - maxSpread)
        })

        depth.asks = depth.asks.filter(function(x) {
            return x[0] <= center * (1 + maxSpread)
        })
    }

    var hash = {
        bids: toHash(depth.bids),
        asks: toHash(depth.asks)
    },
    prices = _.pluck(depth.bids, 0)
    .concat(_.pluck(depth.asks, 0))
    .sort(function(a, b) { return a - b })

    var series = {
        bids: _.map(prices, function(p) {
            return [+p, +hash.bids[p] || null]
        }),
        asks: _.map(prices, function(p) {
            return [+p, +hash.asks[p] || null]
        })
    }

    var i

    for (i = 1; i < prices.length; i++) {
        if (!series.asks[i][1]) continue
        series.asks[i][1] += series.asks[i-1][1]
    }

    for (i = prices.length - 2; i >= 0; i--) {
        if (!series.bids[i][1]) continue
        series.bids[i][1] += series.bids[i+1][1]
    }

    return series
}

function vohlcToPrices(vohlc) {
    var prices = []

    // Transform to Highstock format
    for (var i = 0; i < vohlc.length; i++) {
        prices.push([+new Date(vohlc[i].date), +vohlc[i].close])
    }

    return prices
}

function splitVohlc(data) {
    var ohlc = [], volume = []

    for (var i = 0; i < data.length; i++) {
        ohlc.push([
            +new Date(data[i].date),
            +data[i].open,
            +data[i].high,
            +data[i].low,
            +data[i].close
        ])

        volume.push([
            +new Date(data[i].date),
            +data[i].volume
        ])
    }

    return { volume: volume, ohlc: ohlc }
}

module.exports = function(market) {
    var base = api.getBaseCurrency(market)
    , quote = api.getQuoteCurrency(market)
    , $el = $('<div class=trade-stats>').html(template({
        market: market,
        base: base,
        quote: quote
    }))
    , controller = {
        $el: $el
    }

    var navMode = $.cookie('tradeMode') == 'advanced' ? 'limit' : 'market'

        
    
    api.on('depth:' + market, depthChart)
    
    $el.on('remove', function() {
        api.off('depth:' + market, depthChart)
    })
    
    var orderBookChart;
    var $accu = $el.find('.book-accu')
    
    function initOrderBookChart(accu){
        var options = _.clone(require('./book-accu.json'), true)
        options.series[0].name = i18n('trade.stats.accu.buyers', base)
        options.series[1].name = i18n('trade.stats.accu.sellers', base)
        options.title.text = i18n('trade.stats.accu.title', base, quote)
        options.yAxis.title.text = i18n('trade.stats.accu.yAxis', base)
        options.xAxis.title.text = i18n('trade.stats.accu.xAxis', quote, base)
        options.series[0].data = accu.bids
        options.series[1].data = accu.asks
        orderBookChart = $accu.highcharts(options)
    }
    
    function depthChart(depth){
        console.log("depthChart #bids %s, #asks %s", depth.bids.length, depth.asks.length);
        var accu = depthToAccumulative(depth);
        if(!orderBookChart){
            initOrderBookChart(accu);
        } else {
            var chart = $accu.highcharts();
            chart.series[0].setData(accu.bids);
            chart.series[1].setData(accu.asks);
        }
    }

    var vohlc = api.call('v1/markets/' + market + '/vohlc')

    function afterSetExtremes(e) {

        var url;
        var currentExtremes = this.getExtremes();
        var range = e.max - e.min;
        var duration = '1m';
        var oneDay = 1000 * 60 * 60 * 24;
        if(range === oneDay) duration = '1d';
        var oneWeek = oneDay * 7;
        if(range === oneWeek) duration = '1w';
        var oneMonth = oneWeek * 30;
        if(range === oneMonth) duration = '1m';
        
        console.log("afterSetExtremes %s %s", e.max, e.min)
        var chart = $el.find('.price-history').highcharts();
        chart.showLoading('Loading data from server...');
        api.call('v1/markets/' + market + '/vohlc', null, {qs:{"range":duration}})
        .then(vohlcToPrices)
        .then(function(prices) {
            chart.series[0].setData(prices);
            chart.hideLoading();
        })
    }
    
    vohlc.then(vohlcToPrices).then(function(prices) {
        var options = _.clone(require('./price-history.json'), true);
        options.xAxis.events.afterSetExtremes = afterSetExtremes;
        options.series[0].data = prices
        options.title.text = i18n('trade.stats.price history.title', base, quote)
        options.yAxis.title.text = i18n('trade.stats.price history.yAxis', quote, base)
        options.xAxis.title.text = i18n('trade.stats.price history.xAxis')

        var $prices = $el.find('.price-history')
        $prices.highcharts('StockChart', options)
    })

    vohlc.then(splitVohlc).then(function(data) {
        var options = _.clone(require('./vohlc.json'), true)
        options.series[0].data = data.ohlc
        options.series[1].data = data.volume
        options.title.text = i18n('trade.stats.vohlc.title', base, quote)
        options.yAxis[0].title.text = i18n('trade.stats.vohlc.yAxis.price', quote, base)
        options.yAxis[1].title.text = i18n('trade.stats.vohlc.yAxis.volume', base)
        options.xAxis.title.text = i18n('trade.stats.vohlc.xAxis')

        var $vohlc = $el.find('.vohlc')
        $vohlc.highcharts('StockChart', options)
    })

    return controller
}
