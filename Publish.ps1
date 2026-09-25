<#
.SYNOPSIS
    Publishes AzSqlAccessSync to a PowerShell repository (PSGallery by default).

.DESCRIPTION
    Publish-Module packages every file in the folder it's given, so this copies an explicit
    allow-list of module files into a temporary staging folder and publishes from there.
    Repository-only files (PSGALLERY.md, CLAUDE.md, this script, .git, ...) are never included,
    and a new file only ships once it's added to $include below.

.PARAMETER NuGetApiKey
    Gallery API key. Defaults to $env:PSGALLERY_API_KEY. Not needed with -WhatIf.

.PARAMETER Repository
    Target repository. Defaults to PSGallery.

.PARAMETER WhatIf
    Stages and validates the package and runs Publish-Module -WhatIf, without publishing.

.EXAMPLE
    ./Publish.ps1 -WhatIf

.EXAMPLE
    ./Publish.ps1 -NuGetApiKey $key
#>
param(
    [string]$NuGetApiKey = $env:PSGALLERY_API_KEY,
    [string]$Repository  = 'PSGallery',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$moduleName = 'AzSqlAccessSync'
$include = @(
    "$moduleName.psd1"
    "$moduleName.psm1"
    'Public'
    'Private'
    'Logins'
    'Roles'
    'Profiles'
    'README.md'
    'CHANGELOG.md'
    'LICENSE'
)

if (-not $WhatIf -and -not $NuGetApiKey) {
    throw 'No API key: pass -NuGetApiKey or set $env:PSGALLERY_API_KEY.'
}

# Publish-Module requires the folder name to match the module name.
$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) "$moduleName-publish-$([guid]::NewGuid())"
$stagingPath = Join-Path $stagingRoot $moduleName
New-Item -ItemType Directory -Path $stagingPath | Out-Null

try {
    foreach ($item in $include) {
        Copy-Item -Path (Join-Path $PSScriptRoot $item) -Destination $stagingPath -Recurse
    }

    $manifest = Test-ModuleManifest -Path (Join-Path $stagingPath "$moduleName.psd1")
    Write-Host "Staged $moduleName $($manifest.Version) in $stagingPath" -ForegroundColor Cyan
    Get-ChildItem -Path $stagingPath -Recurse -File |
        ForEach-Object { Write-Host "  $($_.FullName.Substring($stagingPath.Length + 1))" }

    $publishArgs = @{
        Path       = $stagingPath
        Repository = $Repository
        WhatIf     = $WhatIf
    }
    # -WhatIf needs no real key, but Publish-Module still requires the parameter.
    $publishArgs.NuGetApiKey = if ($NuGetApiKey) { $NuGetApiKey } else { 'whatif' }

    Publish-Module @publishArgs
    if (-not $WhatIf) {
        Write-Host "Published $moduleName $($manifest.Version) to $Repository" -ForegroundColor Green
    }
} finally {
    Remove-Item -Path $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
