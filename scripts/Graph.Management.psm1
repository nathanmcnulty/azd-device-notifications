function Get-RequiredGraphPermissionNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Routing)

    $names = @('AuditLog.Read.All', 'DeviceManagementManagedDevices.Read.All')
    if (@($Routing.monitoredGroupIds).Count -gt 0) { $names += @('User.ReadBasic.All', 'GroupMember.Read.All') }
    return $names
}

function Resolve-GraphPermissionPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $GraphServicePrincipal, [Parameter(Mandatory)][string[]] $RequiredNames)

    $plan = foreach ($name in $RequiredNames) {
        $roles = @($GraphServicePrincipal.appRoles | Where-Object { $_.value -eq $name -and $_.allowedMemberTypes -contains 'Application' })
        if ($roles.Count -ne 1) { throw "Unable to resolve exactly one Microsoft Graph application role '$name'." }
        [pscustomobject]@{ Name = $name; Id = [string]$roles[0].id }
    }
    return @($plan)
}

function Invoke-GraphJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [object] $Body,
        [Parameter(Mandatory)][string] $SubscriptionId,
        [string] $TenantId = $env:AZURE_TENANT_ID,
        [switch] $RetryNotFound
    )

    $url = if ($Uri.StartsWith('https://')) { $Uri } else { "https://graph.microsoft.com/v1.0$Uri" }
    $maxAttempts = if ($RetryNotFound) { 9 } else { 6 }
    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
        $token = & az account get-access-token --subscription $SubscriptionId --tenant $TenantId --resource-type ms-graph --query accessToken -o tsv
        if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Unable to acquire a Microsoft Graph token from the active Azure CLI session.' }
        try {
            $parameters = @{ Method = $Method; Uri = $url; Headers = @{ Authorization = "Bearer $token" }; ContentType = 'application/json' }
            if ($null -ne $Body) { $parameters.Body = $Body | ConvertTo-Json -Depth 10 -Compress }
            $response = Invoke-RestMethod @parameters
            return $response
        } catch {
            $status = [int]$_.Exception.Response.StatusCode
            $transient = ($status -eq 404 -and $RetryNotFound) -or $status -eq 408 -or $status -eq 429 -or $status -ge 500
            if (-not $transient -or $attempt -eq ($maxAttempts - 1)) { throw "Microsoft Graph $Method $Uri failed with HTTP $status. $($_.Exception.Message)" }
            $retryAfter = $_.Exception.Response.Headers.RetryAfter
            $seconds = if ($retryAfter -and $retryAfter.Delta) { [Math]::Ceiling($retryAfter.Delta.TotalSeconds) } else { [Math]::Min([Math]::Pow(2, $attempt), 15) }
            Start-Sleep -Seconds ([Math]::Max(1, $seconds))
        }
    }
}

Export-ModuleMember -Function Get-RequiredGraphPermissionNames, Resolve-GraphPermissionPlan, Invoke-GraphJson
