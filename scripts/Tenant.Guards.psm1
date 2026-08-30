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

    foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_ENV_NAME')) {
        [void](Get-AzdEnvironmentValue $name -Authoritative)
    }
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
    param([Parameter(Mandatory)][string] $Name, [switch] $Authoritative)

    $processValue = [Environment]::GetEnvironmentVariable($Name)
    if (-not $Authoritative -and $null -ne $processValue -and $processValue -ne '') { return $processValue }
    if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
        if ($Authoritative) { [Environment]::SetEnvironmentVariable($Name, $null, 'Process') }
        return $null
    }
    $value = & azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($Authoritative) { [Environment]::SetEnvironmentVariable($Name, $null, 'Process') }
        return $null
    }
    $value = ($value -join "`n").Trim()
    if ($value) {
        [Environment]::SetEnvironmentVariable($Name, $value, 'Process')
        return $value
    }
    if ($Authoritative) { [Environment]::SetEnvironmentVariable($Name, $null, 'Process') }
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

function Sync-AzdTargetEnvironment {
    [CmdletBinding()]
    param([switch] $RequireProvisioned)

    $baseNames = @('AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID')
    $provisionedNames = @('AZURE_RESOURCE_GROUP', 'AZURE_FUNCTION_APP_NAME', 'AZURE_FUNCTION_APP_URL',
        'AZURE_WORKLOAD_CLIENT_ID', 'AZURE_WORKLOAD_PRINCIPAL_ID')
    foreach ($name in $baseNames + $provisionedNames + @('TEAMS_BOT_NAME')) {
        [void](Get-AzdEnvironmentValue $name -Authoritative)
    }
    foreach ($name in $baseNames) {
        if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is missing from the selected azd environment." }
    }
    if ($RequireProvisioned) {
        foreach ($name in $provisionedNames) {
            if (-not [Environment]::GetEnvironmentVariable($name)) {
                throw "$name is missing from the selected azd environment. Provision the exact environment before continuing."
            }
        }
    }
}

function Assert-AzdResourceGroupNameBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $EnvironmentName,
        [AllowEmptyString()][string] $ResourceGroupName,
        [AllowEmptyString()][string] $RecordedResourceGroupName,
        [switch] $AllowDerived
    )

    $expectedName = "rg-$EnvironmentName"
    if ($ResourceGroupName -and
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals($ResourceGroupName, $expectedName)) {
        throw "AZURE_RESOURCE_GROUP '$ResourceGroupName' does not match exact target '$expectedName'."
    }
    if (-not $ResourceGroupName -and -not $AllowDerived) {
        throw "AZURE_RESOURCE_GROUP is missing; exact target '$expectedName' cannot be confirmed from an azd output."
    }
    if ($RecordedResourceGroupName -and
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals($RecordedResourceGroupName, $expectedName)) {
        throw "Recorded resource group '$RecordedResourceGroupName' does not match exact target '$expectedName'."
    }
    return $expectedName
}

function Assert-AzdFunctionResourceBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Function,
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $FunctionAppName,
        [Parameter(Mandatory)][string] $EnvironmentName
    )

    $expectedId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$Function.name, $FunctionAppName) -or
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$Function.resourceGroup, $ResourceGroupName) -or
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$Function.id, $expectedId) -or
        [string]$Function.tags.'azd-env-name' -cne $EnvironmentName -or
        [string]$Function.tags.workload -cne 'device-notifications' -or
        [string]$Function.tags.'azd-service-name' -cne 'notifier') {
        throw 'The Function App does not match the exact resource ID and ownership tags for the selected azd environment.'
    }
}

function Assert-AzdResourceGroupTarget {
    [CmdletBinding()]
    param([switch] $AllowDerived)

    Sync-AzdTargetEnvironment
    $recordedName = Get-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_NAME' -Authoritative
    return Assert-AzdResourceGroupNameBinding -EnvironmentName $env:AZURE_ENV_NAME `
        -ResourceGroupName $env:AZURE_RESOURCE_GROUP -RecordedResourceGroupName $recordedName -AllowDerived:$AllowDerived
}

function Get-AzdFunctionTarget {
    [CmdletBinding()]
    param([switch] $AllowMissing)

    if ($AllowMissing) { Sync-AzdTargetEnvironment } else { Sync-AzdTargetEnvironment -RequireProvisioned }
    Assert-AzdTenantContext
    $expectedResourceGroup = Assert-AzdResourceGroupTarget -AllowDerived:$AllowMissing
    $resourceGroupExists = if ($AllowMissing) {
        Confirm-AzdResourceGroupOwnership -AllowMissing
    } else {
        Confirm-AzdResourceGroupOwnership
    }
    if (-not $resourceGroupExists) { return $null }

    $functionsJson = & az functionapp list --subscription $env:AZURE_SUBSCRIPTION_ID --resource-group $expectedResourceGroup `
        --query '[].{name:name,resourceGroup:resourceGroup,id:id,tags:tags,defaultHostName:defaultHostName}' --only-show-errors --output json
    if ($LASTEXITCODE -ne 0 -or -not $functionsJson) { throw "Unable to enumerate Function Apps in '$expectedResourceGroup'." }
    $functions = @($functionsJson | ConvertFrom-Json)
    $matches = if ($env:AZURE_FUNCTION_APP_NAME) {
        @($functions | Where-Object {
                [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.name, $env:AZURE_FUNCTION_APP_NAME)
            })
    } elseif ($AllowMissing) {
        @($functions | Where-Object {
                [string]$_.tags.'azd-env-name' -ceq $env:AZURE_ENV_NAME -and
                [string]$_.tags.workload -ceq 'device-notifications' -and
                [string]$_.tags.'azd-service-name' -ceq 'notifier'
            })
    } else { @() }
    if ($matches.Count -eq 0 -and $AllowMissing) { return $null }
    if ($matches.Count -ne 1) {
        throw "Expected exactly one Function App '$($env:AZURE_FUNCTION_APP_NAME)' in '$expectedResourceGroup'; found $($matches.Count)."
    }
    $function = $matches[0]
    $expectedFunctionName = if ($env:AZURE_FUNCTION_APP_NAME) { $env:AZURE_FUNCTION_APP_NAME } else { [string]$function.name }
    Assert-AzdFunctionResourceBinding -Function $function -SubscriptionId $env:AZURE_SUBSCRIPTION_ID `
        -ResourceGroupName $expectedResourceGroup -FunctionAppName $expectedFunctionName -EnvironmentName $env:AZURE_ENV_NAME
    if ($env:AZURE_FUNCTION_APP_URL) {
        $functionUrl = $null
        try { $functionUrl = [uri]$env:AZURE_FUNCTION_APP_URL } catch { throw 'AZURE_FUNCTION_APP_URL is not a valid URI.' }
        if ($functionUrl.Scheme -ne 'https' -or
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals($functionUrl.Host, [string]$function.defaultHostName)) {
            throw 'AZURE_FUNCTION_APP_URL does not match the exact Function App default host name.'
        }
    }

    if ($env:AZURE_WORKLOAD_CLIENT_ID -and $env:AZURE_WORKLOAD_PRINCIPAL_ID) {
        $identityJson = & az functionapp identity show --subscription $env:AZURE_SUBSCRIPTION_ID `
            --resource-group $expectedResourceGroup --name $expectedFunctionName --only-show-errors --output json
        if ($LASTEXITCODE -ne 0 -or -not $identityJson) { throw 'Unable to read the exact Function App managed identity.' }
        $identity = $identityJson | ConvertFrom-Json
        $assigned = @($identity.userAssignedIdentities.PSObject.Properties)
        if ($assigned.Count -ne 1 -or
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$assigned[0].Value.clientId, $env:AZURE_WORKLOAD_CLIENT_ID) -or
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$assigned[0].Value.principalId, $env:AZURE_WORKLOAD_PRINCIPAL_ID)) {
            throw 'The Function App managed identity does not match the authoritative azd workload outputs.'
        }
    }
    [Environment]::SetEnvironmentVariable('AZURE_RESOURCE_GROUP', $expectedResourceGroup, 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_FUNCTION_APP_NAME', $expectedFunctionName, 'Process')
    return $function
}

function Get-AzdResourceGroupOwnershipState {
    [CmdletBinding()]
    param()

    foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_ENV_NAME')) { [void](Get-AzdEnvironmentValue $name -Authoritative) }
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
    $recorded = Get-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_OWNERSHIP' -Authoritative
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
    $recordedName = Get-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_NAME' -Authoritative
    $recorded = Get-AzdEnvironmentValue 'DEVICE_NOTIFICATION_AZURE_RESOURCE_GROUP_OWNERSHIP' -Authoritative
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
    Resolve-AzdResourceGroupOwnership, Sync-AzdTargetEnvironment, Assert-AzdResourceGroupNameBinding,
    Assert-AzdFunctionResourceBinding, Assert-AzdResourceGroupTarget, Get-AzdFunctionTarget,
    Get-AzdResourceGroupOwnershipState, Initialize-AzdResourceGroupOwnership, Confirm-AzdResourceGroupOwnership
