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

function Resolve-AzdResourceGroupOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $Exists,
        [AllowEmptyString()][string] $RecordedOwnership,
        [AllowNull()][object] $Tags,
        [Parameter(Mandatory)][string] $EnvironmentName
    )

    if (-not $Exists) { return 'create-pending' }
    if ($RecordedOwnership -notin @('create-pending', 'created')) {
        throw "Resource group 'rg-$EnvironmentName' already exists without a matching local creation receipt. Choose a fresh azd environment name; resource-group adoption is not automatic."
    }
    $environmentTag = [string]$Tags.'azd-env-name'
    $workloadTag = [string]$Tags.workload
    if ($environmentTag -cne $EnvironmentName -or $workloadTag -cne 'device-notifications') {
        throw "Resource group 'rg-$EnvironmentName' does not have the exact expected ownership tags. Refusing reuse."
    }
    return 'created'
}

function Get-AzdResourceGroupOwnershipState {
    [CmdletBinding()]
    param()

    foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_ENV_NAME')) { [void](Get-AzdEnvironmentValue $name) }
    if (-not $env:AZURE_SUBSCRIPTION_ID -or -not $env:AZURE_ENV_NAME) {
        throw 'AZURE_SUBSCRIPTION_ID and AZURE_ENV_NAME are required for resource-group ownership validation.'
    }
    $resourceGroupName = "rg-$($env:AZURE_ENV_NAME)"
    $existsText = ([string](& az group exists --subscription $env:AZURE_SUBSCRIPTION_ID --name $resourceGroupName --only-show-errors --output tsv)).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $existsText -notin @('true', 'false')) {
        throw "Unable to determine whether resource group '$resourceGroupName' exists."
    }
    $exists = $existsText -eq 'true'
    $tags = $null
    if ($exists) {
        $groupJson = & az group show --subscription $env:AZURE_SUBSCRIPTION_ID --name $resourceGroupName `
            --query '{name:name,tags:tags}' --only-show-errors --output json
        if ($LASTEXITCODE -ne 0 -or -not $groupJson) { throw "Unable to read resource group '$resourceGroupName'." }
        $group = $groupJson | ConvertFrom-Json
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$group.name, $resourceGroupName)) {
            throw 'Azure returned a different resource group than the exact requested name.'
        }
        $tags = $group.tags
    }
    return [pscustomobject]@{ Name = $resourceGroupName; Exists = $exists; Tags = $tags }
}

function Initialize-AzdResourceGroupOwnership {
    [CmdletBinding()]
    param()

    $state = Get-AzdResourceGroupOwnershipState
    $recorded = Get-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_OWNERSHIP'
    $ownership = Resolve-AzdResourceGroupOwnership -Exists $state.Exists -RecordedOwnership $recorded `
        -Tags $state.Tags -EnvironmentName $env:AZURE_ENV_NAME
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_NAME' $state.Name
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_OWNERSHIP' $ownership
    return $ownership
}

function Confirm-AzdResourceGroupOwnership {
    [CmdletBinding()]
    param([switch] $AllowMissing)

    $state = Get-AzdResourceGroupOwnershipState
    $recordedName = Get-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_NAME'
    $recorded = Get-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_OWNERSHIP'
    if ($recordedName -and -not [System.StringComparer]::OrdinalIgnoreCase.Equals($recordedName, $state.Name)) {
        throw "Recorded resource group '$recordedName' does not match expected group '$($state.Name)'."
    }
    if (-not $state.Exists -and $AllowMissing) { return $false }
    if (-not $state.Exists) { throw "Expected resource group '$($state.Name)' does not exist." }
    $ownership = Resolve-AzdResourceGroupOwnership -Exists $true -RecordedOwnership $recorded `
        -Tags $state.Tags -EnvironmentName $env:AZURE_ENV_NAME
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_NAME' $state.Name
    Set-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_OWNERSHIP' $ownership
    return $true
}

Export-ModuleMember -Function Assert-TenantMatch, Assert-AzdTenantContext, Get-AzdEnvironmentValue, Set-AzdEnvironmentValue,
    Resolve-AzdResourceGroupOwnership, Get-AzdResourceGroupOwnershipState, Initialize-AzdResourceGroupOwnership,
    Confirm-AzdResourceGroupOwnership
