module namespace wiki = "http://ixxus.com/wikipediascraping";

import module namespace functx = "http://www.functx.com" at "/MarkLogic/functx/functx-1.0-nodoc-2007-01.xqy";
import module namespace sem = "http://marklogic.com/semantics" at "/MarkLogic/semantics.xqy";

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
	let $_ := SaveImagesToDatabase($content, $filename)
	
	return
		if ($downloadLinkedPages = fn:true()) then
			let $links := GetLinkedPages($content)
			return
				DownloadLinkedPages($links)
		else
			()
};

declare function CreateDocument($page as node()) as element()
{
	let $title := GetTitleFromPage($page)
	let $content := $page/html/body/div[@id="content"]/div[@id="bodyContent"]/div[@id="mw-content-text"]
	let $headings := GetSectionHeadings($content)
	return
		<article>
			<title>{$title}</title>
			<summary>
			{
				for $paragraph in $content/p[not(preceding-sibling::div[@id="toc"])]
				return
					fn:string($paragraph)
			}
			</summary>
			<sections>
			{
				for $heading in $headings
				return
					<section>
						<heading>{$heading/span/text()}</heading>
						<content>
						{
							for $paragraph in $heading/following-sibling::p[preceding-sibling::h2[1] = $heading]
							return
								fn:string($paragraph)
						}
						</content>
					</section>
			}
			</sections>
			<linkedPages/>
			<images/>
		</article>
};

declare function GetSectionHeadings($content as node()) as item()*
{
	$content/h2
		[
			span
				[
					@class="mw-headline"
					and not(./text() = "References") 
					and not(./text() = "Further reading")
					and not(./text() = "See also")
					and not(./text() = "External links")
				]
		]
};

declare function SaveImagesToDatabase($content as node(), $documentUri as xs:string)
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
		
	let $addTripleCommand := fn:concat
		('
			declare variable $imageUriExt external;
			declare variable $documentUriExt external;
			
			let $document := fn:doc($documentUriExt)
			let $imagesNode := $document/article/images
			return
				xdmp:node-insert-child
					(
						$imagesNode, 
						<triple>
						{
							sem:triple($imageUriExt, "included on", $documentUriExt)
						}
						</triple>
					)
		')

	let $images := GetImagesFromPage($content)
	let $_ := xdmp:log(fn:concat("Going to download ", count($images), " images"))
	return
		for $image in $images
		let $filename := functx:substring-after-last($image, "/")
		let $filename := fn:concat("/Image/", $filename)
		let $_ := xdmp:eval
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
		let $_ := xdmp:eval
			(
				$addTripleCommand,
				(
					xs:QName("imageUriExt"), $filename,
					xs:QName("documentUriExt"), $documentUri
				),
				<options xmlns="xdmp:eval">
					<isolation>different-transaction</isolation>
					<prevent-deadlocks>true</prevent-deadlocks>
				</options>
			)
		return
			()
};

declare function GetImagesFromPage($content) as item()*
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