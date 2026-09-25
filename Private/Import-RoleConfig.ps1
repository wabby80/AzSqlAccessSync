function Import-RoleConfig {
    param(
        [Parameter(Mandatory)]
        [string]$RolesFolderPath,
        [Parameter(Mandatory)]
        [string]$Environment
    )

    # Same loader as Sync-SqlRoles' own (separate, inline) copy. The folder comes from the caller
    # (profile RolesFolderPath or -RolesFolderPath), never from inside the module.
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
