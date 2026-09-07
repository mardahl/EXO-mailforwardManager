@{
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSAvoidUsingEmptyCatchBlock'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
        'PSReviewUnusedParameter'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }
}
