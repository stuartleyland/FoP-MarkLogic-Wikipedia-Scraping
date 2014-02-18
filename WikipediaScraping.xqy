module namespace wiki = "http://ixxus.com/wikipediascraping";

import module namespace functx = "http://www.functx.com" at "/MarkLogic/functx/functx-1.0-nodoc-2007-01.xqy";
import module namespace sem = "http://marklogic.com/semantics" at "/MarkLogic/semantics.xqy";
import module namespace util = "http://ixxus.com/util" at "Utilities.xqy";

declare namespace wikimedia = "http://www.mediawiki.org/xml/export-0.8/";
declare namespace foaf = "http://xmlns.com/foaf/0.1/";

declare variable $wikipediaBaseUrl as xs:string := "http://en.wikipedia.org/wiki/";

declare function ImportPagesFromWikipediaExportFile($xmlFileLocation as xs:string)
{
	let $page := xdmp:document-get($xmlFileLocation)
	return
		for $title in $page//wikimedia:title/text()
		let $title := fn:replace($title, " ", "_")
		return
			ImportWikipediaPage($title, fn:true(), "")
					
};

declare function ImportWikipediaPage($title as xs:string, $downloadLinkedPages as xs:boolean, $startingDocumentUri as xs:string)
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
				SavePageToDatabase($page, $downloadLinkedPages, $startingDocumentUri)
};

declare function CreateWikipediaLinkFromTitle($title) as xs:string
{
	fn:concat($wikipediaBaseUrl, $title)
};

declare function DownloadWikipediaPage($url as xs:string) as node()?
{
	try
	{
		DownloadPageWithEncoding($url, "utf-8")
	}
	catch ($error)
	{
		try
		{
			let $_ := xdmp:log("Had an error downloading the page, will try with different encoding")
			return
				DownloadPageWithEncoding($url, "iso-8859-1")
		}
		catch ($error)
		{
			xdmp:log($error)
		}
	}
};

declare function DownloadPageWithEncoding($url as xs:string, $encoding as xs:string) as node()?
{
	try
	{
		let $_ := xdmp:sleep(500)
		let $_ := xdmp:log(fn:concat("About to download page from [", $url, "] using encoding [", $encoding, "]")) 
		let $responseAndPage := xdmp:http-get
			(
				$url,
				<options xmlns="xdmp:http-get">
					<format xmlns="xdmp:document-get">xml</format>
					<encoding xmlns="xdmp:document-get">{$encoding}</encoding>
				</options>
			)
		let $response := $responseAndPage[1]
		let $responseCode := $response/*:code/text()
		return
			if ($responseCode = 200) then
				$responseAndPage[2]
			else
				(
					xdmp:log(fn:concat("Got response code [", $responseCode, "]")),
					xdmp:log("Not downloading page")
				)
	}
	catch ($error)
	{
		xdmp:rethrow()
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

declare function GetTitleFromPage($page as node())
{
	let $title := fn:replace($page/html/head/title/text(), " - Wikipedia, the free encyclopedia", "")
	return
		$title
};

declare function DownloadLinkedPagesFromCategoryPage($page as node())
{
	let $linksDiv := $page//*:div[@id="mw-pages"]
	let $links := GetLinkedPages($linksDiv)
	return
		for $link in $links
		return ImportWikipediaPage($link, fn:true(), "")
			
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

declare function SavePageToDatabase($page as node(), $downloadLinkedPages as xs:boolean, $startingDocumentUri as xs:string)
{
	let $command := fn:concat
		("
			declare variable $filenameExt external;
			declare variable $documentExt external;
			xdmp:document-insert($filenameExt, $documentExt)
		")
	
	let $document := CreateDocument($page)
	let $originalTitle := GetTitleFromPage($page)
	let $filename := fn:concat("/Article/", $originalTitle, ".xml")

	let $_ := util:RunCommandInDifferentTransaction
		(
			$command, 
			(xs:QName("filenameExt"), $filename, xs:QName("documentExt"), $document)
		)
	
	let $content := $page/html/body/div[@id="content"]
	let $imageDivs := $content//div[@class="thumbinner"][descendant::a/img][not(descendant::div[@class="PopUpMediaTransform"])][not(descendant::div[@class="mediaContainer"])]
	let $_ := SaveImagesToDatabase($imageDivs, $filename)
	let $_ := RetrieveAndSaveFlickrImages($originalTitle, $filename)
	let $_ := CreateTriplesForLinkedPage($filename, $startingDocumentUri)
	let $_ := ExtractAndSavePersonData($page, $filename)
	return
		if ($downloadLinkedPages = fn:true()) then
			let $links := GetLinkedPages($content)
			return
				DownloadLinkedPages($links, $filename)
		else
			()
};

declare function ExtractAndSavePersonData($page as node(), $filename as xs:string)
{
	let $contentNode := GetContentNode($page)
	let $createTripleCommand := CreateTripleCommand()
	for $row in $contentNode/table[data(@id) = "persondata"]//tr
		
		let $pred := GetPredicateFromPersonDataRow($row)
		let $pred := functx:words-to-camel-case($pred)
		let $obj := GetObjectFromPersonDataRow($row)
		return
			if (not(fn:empty($obj)) and not($obj = ""))
			then util:RunCommandInDifferentTransaction
				(
					$createTripleCommand,
					(
					xs:QName("documentUriExt"), $filename, 
					xs:QName("nodeToAddToExt"), "personData",
					xs:QName("subjectUriExt"), $filename, 
					xs:QName("predicateExt"), $pred,
					xs:QName("objectUriExt"), $obj
					)
				)
			else ()
};

declare function GetPredicateFromPersonDataRow($row as node()) as xs:string
{
	if (exists($row/td[1]))	
	then fn:string($row/td[1])
	else ""
};

declare function GetObjectFromPersonDataRow($row as node()) as xs:string
{
	if (exists($row/td[2]))	
	then fn:string($row/td[2])
	else ""
};

declare function CreateDocument($page as node()) as element()
{
    let $title := GetTitleFromPage($page)
	let $content := GetContentNode($page)
	let $headings := GetSectionHeadings($content)
	return
		<article id="{sem:uuid()}">
			<title>{$title}</title>
			<summary>
			{
				for $paragraph in $content/*	[not(preceding::div[@id="toc"])]
								[not(self::div[@id="toc"])]
								[not(self::div[fn:contains(data(@class), "toclimit")])]
								[not(div[fn:contains(data(@class),"thumb")])]
								[not(self::div[fn:contains(data(@class),"dablink")])]
								[not(self::table[fn:contains(data(@class), "infobox")])]
								[not(self::table[fn:contains(data(@class), "navbox")])]
								[not(data(@role))]

				return
					$paragraph
			}
			</summary>
			<sections>
			{
				for $heading in $headings
				let $nextHeading := $heading/following-sibling::h2[1]
				let $fullSection := $heading/following-sibling::* except ($nextHeading, $nextHeading/following-sibling::*)
				let $sectionContent := $fullSection except ($fullSection[self::h3], $fullSection[self::h3]/following-sibling::*)
				return
				 <section id="{sem:uuid()}">
				 	<title>{$heading/span/text()}</title>
					<content>{$sectionContent}</content>
					<sections>
					    {LoopInSubSection(3, $content, $heading)}
					</sections>
				 </section>
			}
			</sections>
			<linkedPages/>
			<images/>
			<captions/>
			<imageDescriptions/>
			<personData/>
		</article>
};

declare function GetContentNode($page as node()) as node()
{
	$page/html/body/div[@id="content"]/div[@id="bodyContent"]/div[@id="mw-content-text"]
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

declare function LoopInSubSection($level, $content, $heading)
{
	let $precedingLevel := $level - 1
	let $nextLevel := $level + 1
	let $contentHeadings := $content//*[local-name(.)=fn:concat("h",$level)][span[@class='mw-headline']]
	return
		for $localHeading in $contentHeadings
		let $headingBeforeSubHeading := $localHeading/preceding-sibling::*[local-name(.)=fn:concat("h",$precedingLevel)][1]
		return 
			if ($headingBeforeSubHeading = $heading) then
			let $nextSubHeading := $localHeading/following-sibling::*[local-name(.)=fn:concat("h",$level)][1]
			let $fullSubSection := $localHeading/following-sibling::* except ($nextSubHeading, $nextSubHeading/following-sibling::*)
			let $subSectionContent := $fullSubSection except ($fullSubSection[self::*[local-name(.)=fn:concat("h",$nextLevel)]], $fullSubSection[self::*[local-name(.)=fn:concat("h",$nextLevel)]]/following-sibling::*)
			return
				<section id="{sem:uuid()}">
				<title>{$localHeading/span/text()}</title>
				<content>{$subSectionContent}</content>
				<sections>
				{
					LoopInSubSection($nextLevel, $content, $localHeading)
				}
				</sections>
				</section>
			else ( )
};

declare function ChildrenLoopInSectionContent($node)
{
	for $L as node() in $node/node()
	return
		LoopInSectionContent($L)
};

declare function LoopInSectionContent($node as node())
{
	typeswitch ($node)

		case element(sub)
		return
			if ($node/node()) then
				<sub>{ChildrenLoopInSectionContent($node)}</sub>
			else ( )

		case element(sup)
		return
			if ($node/node()) then
				<sup>{ChildrenLoopInSectionContent($node)}</sup>
			else ( )

		case element(i)
		return
			if ($node/node()) then
				<i>{ChildrenLoopInSectionContent($node)}</i>
			else ( )

		case element(b)
		return
			if ($node/node()) then
				<b>{ChildrenLoopInSectionContent($node)}</b>
			else ( )

		case $x as element (p)
		return
			if ($node/node()) then
				<p>{$x/text()}</p>
			else ( )	

		case $x as element (span)
		return
			if ($node/node()) then
				if(data($x/@class) = "mw-headline") then
					<heading>{$x/text()}</heading>
				else ( )
			else ( )

		case $x as element (div)
		return
			if ($node/node()) then
				<div>
					{$x/text()}
					{ChildrenLoopInSectionContent($node)}
				</div>
			else ( )

		default
		return
			ChildrenLoopInSectionContent($node)
};

declare function SaveImagesToDatabase($imageDivs as item()*, $documentUri as xs:string)
{
	for $imageDiv in $imageDivs
	return
		if ($imageDiv/div[@class="thumbcaption"]) then
			HandleImageDiv($imageDiv, $documentUri)
		else
			let $childDivs := $imageDiv/child::*
			return
				SaveImagesToDatabase($childDivs, $documentUri)
};

declare function HandleImageDiv($imageDiv as node(), $documentUri as xs:string)
{
	let $imageUrl := GetImageUrl($imageDiv)
	let $imageFilenameOnWikipedia := GetImageFilenameOnWikipedia($imageUrl)
	let $imageFilenameForStorage := GetImageFilenameForStorage($imageFilenameOnWikipedia)
	let $imageCaption := GetImageCaption($imageDiv)
	let $imageDescription := GetImageDescription($imageFilenameOnWikipedia)
	return SaveAndLinkImage($imageUrl, $imageFilenameForStorage, $documentUri, $imageCaption, $imageDescription)
};

(: 
## Save the image to the database
## Create triples to link the image and the caption, and the image and the description
## $imageDescription can be empty
:)
declare function SaveAndLinkImage($imageUrl, $imageFilenameForStorage, $documentUri, $imageCaption, $imageDescription)
{
	let $insertImageCommand := CreateInsertImageCommand()
	let $createTripleCommand := CreateTripleCommand()

	let $_ := util:RunCommandInDifferentTransaction
		(
			$insertImageCommand, 
			(xs:QName("urlExt"), $imageUrl, xs:QName("filenameExt"), $imageFilenameForStorage)
		)
	let $_ := util:RunCommandInDifferentTransaction
		(
			$createTripleCommand,
			(
				xs:QName("documentUriExt"), $documentUri, 
				xs:QName("nodeToAddToExt"), "images",
				xs:QName("subjectUriExt"), $imageFilenameForStorage, 
				xs:QName("predicateExt"), "included in",
				xs:QName("objectUriExt"), $documentUri
			)
		)
	let $_ := util:RunCommandInDifferentTransaction
		(
			$createTripleCommand,
			(
				xs:QName("documentUriExt"), $documentUri, 
				xs:QName("nodeToAddToExt"), "captions",
				xs:QName("subjectUriExt"), $imageFilenameForStorage, 
				xs:QName("predicateExt"), "has caption",
				xs:QName("objectUriExt"), $imageCaption
			)
		)
	return
		if (not($imageDescription = "")) then
			util:RunCommandInDifferentTransaction
			(
				$createTripleCommand,
				(
					xs:QName("documentUriExt"), $documentUri, 
					xs:QName("nodeToAddToExt"), "imageDescriptions",
					xs:QName("subjectUriExt"), $imageFilenameForStorage, 
					xs:QName("predicateExt"), "has description",
					xs:QName("objectUriExt"), $imageDescription
				)
			)
		else
			()
};

declare function RetrieveAndSaveFlickrImages($title, $documentUri)
{
	let $title := fn:replace($title, " ", "_")
	let $dbpedia_prefix := "http://dbpedia.org/resource/"
	let $dbpediaResourceURL := fn:concat($dbpedia_prefix, $title)
	let $_ := xdmp:log(fn:concat("Finding Flickr Images for ", $dbpediaResourceURL))
	let $photoSparQL := fn:concat("SELECT ?o WHERE { <", $dbpediaResourceURL, "> <http://dbpedia.org/property/hasPhotoCollection> ?o } ")
	let $hasPhotoCollection := sem:sparql($photoSparQL)
	let $hasPhotoCollectionURI := map:get($hasPhotoCollection[1], "o")
	let $hasPhotoCollectionResource := xdmp:http-get($hasPhotoCollectionURI)
	(: Initial Resource is a 403; find the new location :)
	let $hasPhotoCollectionResource := 
		try {
			xdmp:http-get($hasPhotoCollectionResource/*:headers/*:location/text())
		} catch ($exc)
		{
			<Root><errorMessage>{$exc}</errorMessage><code>404</code></Root>
		}
	let $resourceHttpType := $hasPhotoCollectionResource//*:code/text()
	let $rdfResource := 
		if ($resourceHttpType = "404")
		then
			<Error><format-string>DBpedia resource ({$hasPhotoCollectionURI}) does not exist</format-string></Error>
		else
			try {
			xdmp:unquote($hasPhotoCollectionResource[2])/*:html/*:body/*:pre/text()
			} catch ($exc)
			{
			<Error><xqueryMessage>{$exc}</xqueryMessage></Error>
			}
	let $rdfDescription :=
		try {
			xdmp:unquote($rdfResource)/rdf:RDF/rdf:Description
		} catch ($exc)
		{
			()
		}
	let $_ := 	if (fn:empty($rdfDescription))
			then xdmp:log(fn:concat("Empty RDF description for ", $title, ": ", xdmp:quote($rdfResource//*:format-string/text())))
			else ()
	for $desc in $rdfDescription
	return 
		for $dep in $desc/foaf:depiction
			let $imageUrl := data($dep/@rdf:resource)
			let $imageFilenameForStorage := fn:concat("/FlickrImage/", fn:replace(fn:replace($imageUrl, "://", "_"), "/", "_"))
			let $imageCaption := "Flickr Caption"
			let $imageDescription := "Flickr Desc"
			(: #################### :)
			(: ###### TODO ######## :)
			(: #################### :)
			(: Get a meaningful caption and description, possibly by visiting the FlickrURL :)
			(: #################### :)
			return SaveAndLinkImage($imageUrl, $imageFilenameForStorage, $documentUri, $imageCaption, $imageDescription)
};

declare function CreateInsertImageCommand() as xs:string
{
	fn:concat
		('
			declare variable $urlExt external;
			declare variable $filenameExt external;
			xdmp:document-load(
				$urlExt,
				<options xmlns="xdmp:document-load">
					<uri>
						{$filenameExt}
					</uri>
				</options>
				)
		')
};

declare function CreateTripleCommand() as xs:string
{
	fn:concat
		('
			declare variable $documentUriExt external;
			declare variable $nodeToAddToExt external;
			declare variable $subjectUriExt external;
			declare variable $predicateExt external;
			declare variable $objectUriExt external;
			
			let $document := fn:doc($documentUriExt)
			let $triplesNode := $document/article/*[local-name(.) = $nodeToAddToExt]
			return
				xdmp:node-insert-child
					(
						$triplesNode, 
						<triple>
						{
							sem:triple($subjectUriExt, $predicateExt, $objectUriExt)
						}
						</triple>
					)
		')
};

declare function GetImageUrl($imageDiv as node()) as xs:string
{
	let $imageTag := GetImageTag($imageDiv)
	let $imageUrl := data($imageTag/@src)
	let $imageUrl := fn:replace($imageUrl, "//", "http://")
	return
		if (fn:contains($imageUrl, "/thumb/")) then
			let $imageUrl := fn:replace($imageUrl, "/thumb", "")
			let $imageUrl := functx:substring-before-last($imageUrl, "/")
			return
				$imageUrl
		else
			$imageUrl
};

declare function GetImageTag($imageDiv as node()) as node()?
{
	if ($imageDiv/div[@class="thumbimage"]) then
		$imageDiv/div[@class="thumbimage"]/a/img
	else
		if ($imageDiv/a/img) then
			$imageDiv/a/img
		else
			$imageDiv/div/a/img
};

declare function GetImageFilenameOnWikipedia($url as xs:string) as xs:string
{
	let $filename := functx:substring-after-last($url, "/")
	return
		if ($filename = "") then
			let $_ := xdmp:log(fn:concat("Empty image filename for URL [", $url, "]"))
			return
				""
		else
			$filename
};

declare function GetImageFilenameForStorage($filenameOnWikipedia as xs:string) as xs:string
{
	fn:concat("/Image/", $filenameOnWikipedia)
};

declare function GetImageCaption($imageDiv as node()) as xs:string
{
	let $captionElements := $imageDiv/div[@class="thumbcaption"]//text()[not(ancestor::div[@class="magnify"])]
	return
		util:CombineStringsAndFixSpacing($captionElements)
};

declare function GetImageDescription($imageFilenameOnWikipedia as xs:string) as xs:string
{
	let $detailsPageUrl := fn:concat($wikipediaBaseUrl, "File:", $imageFilenameOnWikipedia)
	let $detailsPage := DownloadWikipediaPage($detailsPageUrl)
	return
		if (fn:empty($detailsPage)) then
			""
		else
			let $content := GetContentNode($detailsPage)
			let $descriptionElements := GetImageDescriptionElements($content)
			return
				util:CombineStringsAndFixSpacing($descriptionElements)
};

declare function GetImageDescriptionElements($content as node()) as item()*
{
	let $detailsTable := $content/div[@id="shared-image-desc"]/div[@class="hproduct"]/table
	return
		(: This is for a standard image hosted on Wikipedia without any notices/comments 
		   Example: http://en.wikipedia.org/wiki/File:BNSF_5350_20040808_Prairie_du_Chien_WI.jpg :)
		if (fn:exists($detailsTable)) then
			$detailsTable/tr/td[@class="description"]//text()
		else
			(: This is for an image hosted on Wikipedia that does have notices/comments
			   Exmaple: http://en.wikipedia.org/wiki/File:Passengers_in_Amtrak_lounge_car_of_San_Joaquin_%28train%29_2014.jpg :)
			$content//tr[th[. = "Description"]]/td//text()
};

declare function CreateTriplesForLinkedPage($documentUri as xs:string, $startingDocumentUri as xs:string)
{
	if ($startingDocumentUri = "") then
		()
	else
		let $addTripleCommand := CreateTripleCommand()
		let $_ := util:RunCommandInDifferentTransaction
			(
				$addTripleCommand,
				(
					xs:QName("documentUriExt"), $documentUri, 
					xs:QName("nodeToAddToExt"), "linkedPages",
					xs:QName("subjectUriExt"), $startingDocumentUri, 
					xs:QName("predicateExt"), "links to",
					xs:QName("objectUriExt"), $documentUri
				)
			)
		return
			()
		
};

declare function DownloadLinkedPages($links as item()*, $startingDocumentUri as xs:string)
{
	for $link in $links
	return
		ImportWikipediaPage($link, fn:false(), $startingDocumentUri)
};
