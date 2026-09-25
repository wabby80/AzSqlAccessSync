function Expand-EntraPrincipalChain {
    <#
    .SYNOPSIS
        Resolves a top-level Entra login/group name down to its leaf principals.

    .DESCRIPTION
        Entry point for Entra resolution: looks up the login name declared in Logins/*.json, and if
        it's a security group, recurses through nested group membership (via
        Expand-ResolvedEntraObject) until every branch reaches an actual User, Managed Identity, or
        Service Principal. A login that isn't a group at all (an individual Entra object) returns
        itself as the sole leaf. Only meaningful for `type: external` logins - `type: sql` logins
        are already leaves and never call this.
    #>
    param(
        [Parameter(Mandatory)] [string]$PrincipalName,
        [Parameter(Mandatory)] [hashtable]$Cache
    )

    $obj = Resolve-EntraObject -Name $PrincipalName -Cache $Cache
    return @(Expand-ResolvedEntraObject -Obj $obj -Cache $Cache)
}
