Register-ArgumentCompleter -Native -CommandName 'fangz' -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $tokens = $commandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text }
    & fangz __complete @tokens | Where-Object { $_ } | ForEach-Object {
        $value, $description = $_ -split "`t", 2
        if (-not $description) { $description = $value }
        [System.Management.Automation.CompletionResult]::new($value, $value, 'ParameterValue', $description)
    }
}
