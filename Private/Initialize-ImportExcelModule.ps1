function Initialize-ImportExcelModule {
    <#
    .SYNOPSIS
        Pre-flight check for -ExportToExcel: ensures the ImportExcel module is installed and loaded.

    .DESCRIPTION
        ImportExcel is a soft dependency of this module - deliberately not in AzSqlAccessSync.psd1's
        RequiredModules, so Import-Module AzSqlAccessSync keeps working for everyone who never uses
        -ExportToExcel. For the people who do, this installs it automatically (CurrentUser scope) if
        it isn't already available, rather than making that a manual prerequisite step.
    #>
    if (Get-Module -Name ImportExcel) { return }

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Host 'ImportExcel module not found - installing (required for -ExportToExcel)...' -ForegroundColor Yellow
        try {
            Install-Module -Name ImportExcel -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        } catch {
            throw "Could not install the ImportExcel module automatically: $($_.Exception.Message). Install it manually with: Install-Module ImportExcel -Scope CurrentUser"
        }
    }

    Import-Module ImportExcel -ErrorAction Stop
}
