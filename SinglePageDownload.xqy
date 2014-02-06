import module namespace wiki = "http://ixxus.com/wikipediascraping" at "WikipediaScraping.xqy";
wiki:ImportWikipediaPage("Train", fn:false())
(:wiki:ImportWikipediaPage("Category:Typesetting", fn:false()):)