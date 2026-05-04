@{
    # Module identity
    ModuleVersion     = '1.0.0'
    GUID              = 'f7e2a4b1-3c9d-4e6f-8a0b-1d5f2e3c7a8b'
    Author            = 'PSFct'
    Description       = 'Read, write, and manage FCT archive files.'

    # Minimum PowerShell version (7+ required for cross-platform .NET APIs)
    PowerShellVersion = '5.1'

    # Module entry point
    RootModule        = 'PSFct.psm1'

    # Public surface
    FunctionsToExport = @(
        'New-FctArchive'
        'Get-FctItem'
        'Add-FctItem'
        'Expand-FctArchive'
        'Remove-FctItem'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('FCT', 'Archive', 'CrossPlatform')
            ProjectUri = 'https://github.com/J4n1X/PSFct'
        }
    }
}
