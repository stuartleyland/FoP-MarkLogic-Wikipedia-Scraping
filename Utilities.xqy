module namespace util = "http://ixxus.com/util";

declare function RunCommandInDifferentTransaction($command as xs:string, $variables as item()*)
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
};