@{
    RootModule        = 'AzSqlAccessSync.psm1'
    ModuleVersion     = '0.9.0'
    GUID              = '53254f22-bd9f-4bfd-b759-b7d2276c5a48'
    Author            = 'Bjørn Christopher Wang'
    Copyright         = '(c) 2026 Bjørn Christopher Wang. Licensed under the MIT License.'
    Description       = 'Synchronizes and verifies Azure SQL Server login, user, role, and permission access based on JSON configuration files. Supports Entra ID (external) and SQL logins, database/server roles, and VIEW permissions.'
    PowerShellVersion = '7.0'
    RequiredModules   = @(
        @{ ModuleName = 'Az.Accounts';  ModuleVersion = '2.0.0' },
        @{ ModuleName = 'Az.Resources'; ModuleVersion = '6.0.0' },
        @{ ModuleName = 'Az.Sql';       ModuleVersion = '3.0.0' },
        @{ ModuleName = 'SqlServer';    ModuleVersion = '22.0.0' }
    )
    FunctionsToExport = @('Sync-SqlUserAccess', 'Sync-SqlRoles', 'Get-SqlAccessReport')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Azure', 'SQL', 'AccessManagement', 'EntraID', 'AzureSQL', 'DBA', 'RBAC')
            ProjectUri   = 'https://github.com/wabby80/AzSqlAccessSync'
            LicenseUri   = 'https://github.com/wabby80/AzSqlAccessSync/blob/main/LICENSE'
            ReleaseNotes = 'https://github.com/wabby80/AzSqlAccessSync/blob/main/CHANGELOG.md'
        }
    }
}
