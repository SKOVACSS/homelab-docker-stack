@{
    # These scripts are interactive CLI tools that deliberately use
    # Write-Host for colored console output, and Create-/Generate- verbs
    # for readability - not exported module functions, so approved-verb
    # naming and ShouldProcess plumbing don't apply the way they would to
    # a shared module. Excluded here rather than suppressed line-by-line.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseBOMForUnicodeEncodedFile',
        'PSAvoidTrailingWhitespace'
    )
}
