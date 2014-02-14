module namespace util = "http://ixxus.com/util";

declare function RunCommandInDifferentTransaction($command as xs:string, $variables as item()*)
{
	try
	{
		RunCommand($command, $variables)
	}
	catch ($error)
	{
		try
		{
			let $_ := xdmp:log("Had an error running a command in a different transaction. Will try again.")
			return
				RunCommand($command, $variables)
		}
		catch ($error)
		{
			(
				xdmp:log("Had an error re-running the command, will now fail."),
				xdmp:log("Command:"),
				xdmp:log($command),
				xdmp:log($error)
			)
			
		}
	}
};

declare function RunCommand($command as xs:string, $variables as item()*)
{
	try
	{
		xdmp:eval
			(
				$command,
				$variables,
				<options xmlns="xdmp:eval">
					<isolation>different-transaction</isolation>
					<prevent-deadlocks>true</prevent-deadlocks>
				</options>
			)
	}
	catch ($error)
	{
		xdmp:rethrow()
	}
};

declare function CombineStringsAndFixSpacing($elements as item()*) as xs:string
{
	let $text := fn:string-join($elements, " ")
	let $text := fn:normalize-space($text)
	return
		$text
};