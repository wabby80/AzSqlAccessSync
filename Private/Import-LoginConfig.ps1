function Import-LoginConfig {
    param(
        [Parameter(Mandatory)]
        [string]$LoginsFolderPath,
        [Parameter(Mandatory)]
        [string]$Environment,
        [string[]]$IgnoreList = @()
    )

    if (-not (Test-Path $LoginsFolderPath)) {
        throw "Logins folder not found: $LoginsFolderPath"
    }

    $loginFiles   = Get-ChildItem -Path $LoginsFolderPath -Filter *.json
    $allLogins    = @()
    $matchedFiles = 0

    foreach ($file in $loginFiles) {
        $jsonText = Get-Content $file.FullName -Raw
        $jsonObj  = $jsonText | ConvertFrom-Json
        if ($jsonObj.acceptedenvironments -and ($Environment -in $jsonObj.acceptedenvironments)) {
            $matchedFiles++
            $jsonText = $jsonText -replace '\$\{environment\}', $Environment.ToLower()
            $jsonObj  = $jsonText | ConvertFrom-Json
            $allLogins += $jsonObj.logins
        }
    }

    if ($matchedFiles -eq 0) {
        throw "No login JSON files in '$LoginsFolderPath' match environment '$Environment'."
    }

    return $allLogins | Where-Object { $_.login -notin $IgnoreList }
}
