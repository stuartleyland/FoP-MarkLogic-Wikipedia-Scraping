module namespace wiki = "http://ixxus.com/wikipediascraping";

import module namespace functx = "http://www.functx.com" at "/MarkLogic/functx/functx-1.0-nodoc-2007-01.xqy";

declare namespace wikimedia = "http://www.mediawiki.org/xml/export-0.8/";

declare variable $wikipediaBaseUrl as xs:string := "http://en.wikipedia.org/wiki/";

declare function ImportPagesFromWikipediaExportFile($xmlFileLocation as xs:string)
{
	let $page := xdmp:document-get($xmlFileLocation)
	return
		for $title in $page//wikimedia:title/text()
		let $title := fn:replace($title, " ", "_")
		return
			ImportWikipediaPage($title, fn:true())
					
};

declare function ImportWikipediaPage($title as xs:string, $downloadLinkedPages as xs:boolean)
{
	let $url := CreateWikipediaLinkFromTitle($title)
	let $page := DownloadWikipediaPage($url)
	return
		if (fn:empty($page)) then
			()
		else
			if (PageIsCategoryPage($page)) then
				DownloadLinkedPagesFromCategoryPage($page)
			else
				SavePageToDatabase($page, $downloadLinkedPages)
};

declare function CreateWikipediaLinkFromTitle($title) as xs:string
{
	fn:concat($wikipediaBaseUrl, $title)
};

declare function DownloadWikipediaPage($url as xs:string) as node()
{
	try
	{
		let $_ := xdmp:sleep(1000)
		let $_ := xdmp:log(fn:concat("About to download page from [", $url, "]")) 
		let $responseAndPage := xdmp:http-get
			(
				$url,
				<options xmlns="xdmp:http-get">
					<format xmlns="xdmp:document-get">xml</format>
				</options>
			)
		let $response := $responseAndPage[1]
		let $responseCode := $response/*:code/text()
		let $_ := xdmp:log(fn:concat("Got response code [", $responseCode, "]")) 
		return
			if ($responseCode = 200) then
				$responseAndPage[2]
			else
				xdmp:log("Not downloading page")
	}
	catch ($error)
	{
		xdmp:log($error)
	}
};

declare function PageIsCategoryPage($page as node()) as xs:boolean
{
	let $title := GetTitleFromPage($page)
	return
		if (fn:contains($title, "Category:")) then
			fn:true()
		else
			fn:false()
};

declare function DownloadLinkedPagesFromCategoryPage($page as node())
{
	let $linksDiv := $page//*:div[@id="mw-pages"]
	let $links := GetLinkedPages($linksDiv)
	return
		for $link in $links
		return ImportWikipediaPage($link, fn:true())
			
};

declare function SavePageToDatabase($page as node(), $downloadLinkedPages as xs:boolean)
{
	let $command := fn:concat
		("
			declare variable $filenameExt external;
			declare variable $documentExt external;
			xdmp:document-insert($filenameExt, $documentExt)
		")
	
	let $document := CreateDocument($page)
	let $filename := GetTitleFromPage($page)
	let $filename := fn:concat("/Article/", $filename, ".xml")

	let $_ := xdmp:eval
		(
			$command, 
			(
				xs:QName("filenameExt"), $filename, 
				xs:QName("documentExt"), $document
			),
			<options xmlns="xdmp:eval">
				<isolation>different-transaction</isolation>
				<prevent-deadlocks>true</prevent-deadlocks>
			</options>
		)
	
	let $content := $page/html/body/div[@id="content"]
	let $_ := SaveImagesToDatabase($content)
	
	return
		if ($downloadLinkedPages = fn:true()) then
			let $links := GetLinkedPages($content)
			return
				DownloadLinkedPages($links)
		else
			()
};

declare function CreateDocument($page as node())
{
	let $title := GetTitleFromPage($page)
	let $content := $page/html/body/div[@id="content"]
	let $document := 
		<article>
			<title>{$title}</title>
			<content>{$content}</content>
		</article>
	let $_ := xdmp:log(fn:concat("Document: ", $document))
	return
		$document
};

declare function SaveImagesToDatabase($content)
{
	let $insertCommand := fn:concat
		(
			'declare variable $urlExt external;
			declare variable $filenameExt external;
			xdmp:document-load(
				$urlExt,
				<options xmlns="xdmp:document-load">
					<uri>
						{$filenameExt}
					</uri>
				</options>
				)'
		)
		
	let $images := GetImagesFromPage($content)
	return
		for $image in $images
		let $_ := xdmp:log(fn:concat("Going to download the following image [", $image, "]"))
		let $filename := functx:substring-after-last($image, "/")
		let $filename := fn:concat("/Image/", $filename)
		return
			let $eval := xdmp:eval
			(
				$insertCommand,
				(
					xs:QName("urlExt"), $image,
					xs:QName("filenameExt"), $filename
				),
				<options xmlns="xdmp:eval">
					<isolation>different-transaction</isolation>
					<prevent-deadlocks>true</prevent-deadlocks>
				</options>
			)
			let $_ := xdmp:log($eval)
			return
				()
			
};

declare function GetImagesFromPage($content)
{
	let $images := fn:distinct-values
		(
			$content//img
			[@src
				[
					contains(., "/thumb/")
				]
			]/@src
		)
	return
	for $image in $images
	let $image := fn:replace($image, "//", "http://")
	let $image := fn:replace($image, "/thumb", "")
	let $image := functx:substring-before-last($image, "/")
	return
		$image
};

declare function GetTitleFromPage($page as node())
{
	let $title := fn:replace($page/html/head/title/text(), " - Wikipedia, the free encyclopedia", "")
	return
		$title
};

declare function DownloadLinkedPages($links)
{
	for $link in $links
	return
		ImportWikipediaPage($link, fn:false())
			
};

declare function GetLinkedPages($content as node()) as item()*
{
	let $links := fn:distinct-values
		(
			$content//a
			[@href
				[
					not(contains(., "#")) 
					and not(contains(., "File:")) 
					and not(contains(., "action=edit"))
					and not(contains(., "Special:"))
					and not(contains(., "Help:"))
					and not(contains(., "Wikipedia:"))
					and not(contains(., "Portal:"))
					and not(contains(., "Category:"))
					and not(contains(., "Template"))
					and starts-with(., "/wiki/")
				]
			]/@href)
	return
		for $link in $links
		return
			fn:replace($link, "/wiki/", "")
};