module namespace wiki = "http://ixxus.com/wikipediascraping";

import module namespace functx = "http://www.functx.com" at "/MarkLogic/functx/functx-1.0-nodoc-2007-01.xqy";
import module namespace sem = "http://marklogic.com/semantics" at "/MarkLogic/semantics.xqy";
import module namespace util = "http://ixxus.com/util" at "Utilities.xqy";

declare namespace wikimedia = "http://www.mediawiki.org/xml/export-0.8/";

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
		let $_ := xdmp:sleep(500)
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
	
	let $document := CreateDocumentRecursively($page)
	let $filename := GetTitleFromPage($page)
	let $filename := fn:concat("/Article/", $filename, ".xml")

	let $_ := util:RunCommandInDifferentTransaction
		(
			$command, 
			(xs:QName("filenameExt"), $filename, xs:QName("documentExt"), $document)
		)
	
	let $content := $page/html/body/div[@id="content"]
	let $imageDivs := $content//div[@class="thumbinner"]
	let $_ := SaveImagesToDatabase($imageDivs, $filename)
	let $_ := CreateTriplesForLinkedPage($filename, $startingDocumentUri)
	return
		if ($downloadLinkedPages = fn:true()) then
			let $links := GetLinkedPages($content)
			return
				DownloadLinkedPages($links, $filename)
		else
			()
};

declare function CreateDocument($page as node()) as element()
{
	let $title := GetTitleFromPage($page)
	let $content := GetContentNode($page)
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
				let $nextHeading := $heading/following-sibling::h2[1]
				let $fullSection := $heading/following-sibling::* except ($nextHeading, $nextHeading/following-sibling::*)
				let $sectionContent := $fullSection except ($fullSection[self::h3], $fullSection[self::h3]/following-sibling::*)
				return
					<section>
						<title>{$heading/span/text()}</title>
						<content>{$sectionContent}</content>
						<sub-sections>
						{
							for $subheading in $content//h3[span[@class='mw-headline']]
							let $headingBeforeSubHeading := $subheading/preceding-sibling::h2[1]
								return
									if ($headingBeforeSubHeading = $heading) then
									let $nextSubHeading := $subheading/following-sibling::h3[1]
									let $fullSubSection := $subheading/following-sibling::* except ($nextSubHeading, $nextSubHeading/following-sibling::*)
									let $subSectionContent := $fullSubSection except ($fullSubSection[self::h4], $fullSubSection[self::h4]/following-sibling::*)
									return
										<section>
											<title>{$subheading/span/text()}</title>
											<content>{$subSectionContent}</content>
											<sub-sections>
											{
												for $subSubHeading in $content//h4[span[@class='mw-headline']]
												let $subHeadingBeforeSubSubHeading := $subSubHeading/preceding-sibling::h3[1]
												return
													if ($subHeadingBeforeSubSubHeading = $subheading) then
														let $nextSubSubHeading := $subSubHeading/following-sibling::h4[1]
														let $fullSubSubSection := $subSubHeading/following-sibling::* except ($nextSubSubHeading, $nextSubSubHeading/following-sibling::*)
														let $subSubSectionContent := $fullSubSubSection except ($fullSubSubSection[self::h5], $fullSubSubSection[self::h5]/following-sibling::*)
														return
															<section>
															<title>{$subSubHeading/span/text()}</title>
															<content>{$subSubSectionContent}</content>
															</section>
													else
													()
											}
											</sub-sections>
										</section>
									else
										()
						}
						</sub-sections>
					</section>
			}
			</sections>
			<linkedPages/>
			<images/>
			<captions/>
			<imageDescriptions/>
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

declare function SaveImagesToDatabase($imageDivs as item()*, $documentUri as xs:string)
{
	for $imageDiv in $imageDivs
	return
		let $childDivs := $imageDiv/div[not (@thumbcaption)]
		let $numberOfChildDivs := count($childDivs)
		return
			if ($numberOfChildDivs = 0) then
				()
			else
				if ($numberOfChildDivs = 1) then
					HandleImageDiv($imageDiv, $documentUri)
				else
					for $childDiv in $childDivs
					return
						SaveImagesToDatabase($childDiv, $documentUri)
};

declare function HandleImageDiv($imageDiv as node(), $documentUri as xs:string)
{
	let $insertImageCommand := CreateInsertImageCommand()
	let $createTripleCommand := CreateTripleCommand()
	
	let $imageUrl := GetImageUrl($imageDiv)
	let $imageFilenameOnWikipedia := GetImageFilenameOnWikipedia($imageUrl)
	let $imageFilenameForStorage := GetImageFilenameForStorage($imageFilenameOnWikipedia)
	let $imageCaption := GetImageCaption($imageDiv)
	let $imageDescription := GetImageDescription($imageFilenameOnWikipedia)
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
	let $imageTag := $imageDiv//a[@class="image"]/img
	let $imageUrl := data($imageTag/@src)
	let $imageUrl := fn:replace($imageUrl, "//", "http://")
	let $imageUrl := fn:replace($imageUrl, "/thumb", "")
	let $imageUrl := functx:substring-before-last($imageUrl, "/")
	return
		$imageUrl
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
		let $_ := xdmp:log(fn:concat("Starting document URI: [", $startingDocumentUri, "]"))
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


declare function CreateDocumentRecursively($page as node()) as element()
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
				let $nextHeading := $heading/following-sibling::h2[1]
				let $fullSection := $heading/following-sibling::* except ($nextHeading, $nextHeading/following-sibling::*)
				let $sectionContent := $fullSection except ($fullSection[self::h3], $fullSection[self::h3]/following-sibling::*)
				return
				 <section>
				 	<title>{$heading/span/text()}</title>
					<content>{$sectionContent}</content>
					<sub-sections>
					    {loop_in_subsection(3, $content, $heading)}
					</sub-sections>
				 </section>
			}
			</sections>
			<linkedPages/>
			<images/>
			<captions/>
		</article>
};



 declare function loop_in_subsection($level, $content, $heading)
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
				<sub-section>
					<title>{$localHeading/span/text()}</title>
					<content>{$subSectionContent}</content>
					<sub-sections>
						{loop_in_subsection($nextLevel, $content, $localHeading)}
					</sub-sections>
				</sub-section>
		 else ( )
 };
 
 
 declare function children_loop_in_section_content ($node)
{
  for $L as node() in $node/node()
  return
      loop_in_section_content($L)
};
 
 
declare function loop_in_section_content ($node as node())
{
typeswitch ($node)
	   
   case element(sub)
     return
       if ($node/node())
       then
         <sub>{children_loop_in_section_content($node)}</sub>
       else ( )
 
   case element(sup)
     return
       if ($node/node())
       then
         <sup>{children_loop_in_section_content($node)}</sup>
       else ( )
 
   case element(i)
     return
       if ($node/node())
       then
         <i>{children_loop_in_section_content($node)}</i>
       else ( )
     
   case element(b)
     return
       if ($node/node())
       then
         <b>{children_loop_in_section_content($node)}</b>
       else ( )
	
   case $x as element (p)
	 return
	   if ($node/node())
       then
         <p>{$x/text()}</p>
       else ( )	
	   
   case $x as element (span)
	 return
	   if ($node/node())
       then
		 if(data($x/@class) = "mw-headline")
		 then
		   <heading>{$x/text()}</heading>
		 else ( )
       else ( )
	   
   case $x as element (div)
	 return
	   if ($node/node())
	   then
		<div>
		{$x/text()}
		{children_loop_in_section_content($node)}
		</div>
       else ( )
 
   default
     return
       children_loop_in_section_content($node)
};



