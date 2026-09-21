@{
    # These scripts are interactive CLI tools that deliberately use
    # Write-Host for colored console output, and Create-/Generate- verbs
    # for readability - not exported module functions, so approved-verb
    # naming and ShouldProcess plumbing don't apply the way they would to
    # a shared module. Excluded here rather than suppressed line-by-line.
    # PSUseBOMForUnicodeEncodedFile is deliberately NOT excluded, unlike the
    # others below: it's not a style preference. A non-ASCII (emoji) script
    # without a BOM fails to even parse under the default Windows
    # PowerShell 5.1 (it assumes the system ANSI codepage for BOM-less
    # files, unlike PowerShell 7's UTF-8-by-default) - confirmed live,
    # every script in this folder except setup-directories.ps1 was
    # completely broken under the actual default `powershell.exe` before
    # this was caught. See CHANGELOG.md.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidTrailingWhitespace'
    )
}
