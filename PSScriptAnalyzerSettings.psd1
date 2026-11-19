# PSScriptAnalyzer gate for the Windows widgets (CI runs it; see README > Develop).
# Every default rule runs except those listed below, which the code doesn't follow by design:
# WPF/CLI scripts print with Write-Host, use plural nouns, swallow best-effort cleanup errors, and have
# no -WhatIf (ShouldProcess) because they are not cmdlets.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingEmptyCatchBlock',
        'PSAvoidUsingWriteHost',
        'PSReviewUnusedParameter',
        'PSUseSingularNouns',
        'PSAvoidOverwritingBuiltInCmdlets',
        'PSAvoidAssignmentToAutomaticVariable',
        'PSAvoidUsingPlainTextForPassword'
    )
}
