import module namespace wiki = "http://ixxus.com/wikipediascraping" at "WikipediaScraping.xqy";
(:wiki:ImportWikipediaPage("Train", fn:false(), ""):)
(:wiki:ImportWikipediaPage("Train", fn:true(), ""):)
(:wiki:ImportWikipediaPage("Category:Typesetting", fn:false()):)
wiki:ImportWikipediaPage("American_Civil_War", fn:false(), "")