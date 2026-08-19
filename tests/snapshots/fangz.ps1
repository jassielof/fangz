Register-ArgumentCompleter -Native -CommandName 'fangz' -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $tokens = $commandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text }
    & fangz __complete @tokens | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}
