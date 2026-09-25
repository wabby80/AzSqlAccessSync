function Import-RoleConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Environment
    )

    # Roles are a single shared definition set for the whole module, not per-environment-profile
    # config, so the folder is resolved relative to this script rather than read from a profile —
    # same convention Sync-SqlRoles uses for its own (separate, inline) copy of this loader.
    $rolesFolderPath = Join-Path $PSScriptRoot '..\Roles'
    if (-not (Test-Path $rolesFolderPath)) {
        throw "Roles folder not found: $rolesFolderPath"
    }

    $roleFiles = Get-ChildItem -Path $rolesFolderPath -Filter *.json
    $roleDefs  = foreach ($file in $roleFiles) {
        $roleConfig = Get-Content $file.FullName -Raw | ConvertFrom-Json
        if ($roleConfig.acceptedenvironments -and ($Environment -in $roleConfig.acceptedenvironments)) {
            $roleConfig.roles
        }
    }

    return @($roleDefs)
}
