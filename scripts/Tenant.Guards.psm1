function Assert-TenantMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedTenantId,
        [Parameter(Mandatory)][string] $SubscriptionTenantId,
        [Parameter(Mandatory)][string] $ActiveTenantId
    )

    foreach ($id in @($ExpectedTenantId, $SubscriptionTenantId, $ActiveTenantId)) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($id, [ref]$parsed)) {
            throw 'Tenant context values must all be valid tenant GUIDs.'
        }
    }
    if ($ExpectedTenantId -ne $SubscriptionTenantId -or $ExpectedTenantId -ne $ActiveTenantId) {
        throw "Tenant context mismatch. azd expects '$ExpectedTenantId', the subscription belongs to '$SubscriptionTenantId', and Azure CLI is active in '$ActiveTenantId'."
    }
}

function Assert-AzdTenantContext {
    [CmdletBinding()]
    param()

    if (-not $env:AZURE_SUBSCRIPTION_ID -or -not $env:AZURE_TENANT_ID) {
        throw 'AZURE_SUBSCRIPTION_ID and AZURE_TENANT_ID are required.'
    }
    $subscription = & az account show --subscription $env:AZURE_SUBSCRIPTION_ID --query '{id:id,tenantId:tenantId}' -o json
    if ($LASTEXITCODE -ne 0 -or -not $subscription) { throw 'Unable to resolve the configured Azure subscription.' }
    $subscription = $subscription | ConvertFrom-Json
    $subscriptionTenant = $subscription.tenantId
    if ($LASTEXITCODE -ne 0 -or -not $subscriptionTenant) { throw 'Unable to resolve the subscription tenant.' }
    $active = & az account show --query '{id:id,tenantId:tenantId}' -o json
    if ($LASTEXITCODE -ne 0 -or -not $active) { throw 'Unable to resolve the active Azure CLI context.' }
    $active = $active | ConvertFrom-Json
    Assert-TenantMatch -ExpectedTenantId $env:AZURE_TENANT_ID -SubscriptionTenantId $subscriptionTenant.Trim() -ActiveTenantId $active.tenantId.Trim()
    if ($active.id -ne $env:AZURE_SUBSCRIPTION_ID) {
        throw "Azure subscription mismatch. azd expects '$($env:AZURE_SUBSCRIPTION_ID)' but Azure CLI is active in '$($active.id)'. Run 'az account set --subscription $($env:AZURE_SUBSCRIPTION_ID)' and retry."
    }
}

function Get-AzdEnvironmentValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name)

    $processValue = [Environment]::GetEnvironmentVariable($Name)
    if ($null -ne $processValue -and $processValue -ne '') { return $processValue }
    if (-not (Get-Command azd -ErrorAction SilentlyContinue)) { return $null }
    $value = & azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $value = ($value -join "`n").Trim()
    if ($value) {
        [Environment]::SetEnvironmentVariable($Name, $value, 'Process')
        return $value
    }
    return $null
}

function Set-AzdEnvironmentValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][AllowEmptyString()][string] $Value)

    & azd env set $Name $Value | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to set azd environment value '$Name'." }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

Export-ModuleMember -Function Assert-TenantMatch, Assert-AzdTenantContext, Get-AzdEnvironmentValue, Set-AzdEnvironmentValue
