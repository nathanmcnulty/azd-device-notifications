function Test-OrdinalIgnoreCaseEqual {
    param([AllowNull()][string] $Left, [AllowNull()][string] $Right)

    return [System.StringComparer]::OrdinalIgnoreCase.Equals($Left, $Right)
}

function Assert-ExactExchangeConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Connections,
        [Parameter(Mandatory)][string] $ExpectedTenantId,
        [Parameter(Mandatory)][string] $ExpectedAdminUpn
    )

    $connected = @($Connections | Where-Object State -eq 'Connected')
    if ($connected.Count -ne 1) {
        throw "Exchange Online must have exactly one active connection; found $($connected.Count)."
    }
    $connection = $connected[0]
    if (-not (Test-OrdinalIgnoreCaseEqual ([string]$connection.TenantID) $ExpectedTenantId)) {
        throw "Exchange Online is connected to tenant '$($connection.TenantID)' instead of expected tenant '$ExpectedTenantId'."
    }
    if (-not (Test-OrdinalIgnoreCaseEqual ([string]$connection.UserPrincipalName) $ExpectedAdminUpn)) {
        throw "Exchange Online is connected as '$($connection.UserPrincipalName)' instead of expected administrator '$ExpectedAdminUpn'."
    }
    return $connection
}

function Get-AzureCliExchangeAccessToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ExpectedTenantId)

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required to acquire the Exchange Online access token.'
    }
    $responseJson = $null
    $response = $null
    try {
        $responseJson = & az account get-access-token --tenant $ExpectedTenantId `
            --resource 'https://outlook.office365.com' --query '{accessToken:accessToken,tenant:tenant}' `
            --output json --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $responseJson) {
            throw 'Azure CLI could not acquire a cached Exchange Online access token for the expected tenant.'
        }
        try { $response = $responseJson | ConvertFrom-Json -ErrorAction Stop } catch {
            throw 'Azure CLI returned an invalid Exchange Online access-token response.'
        }
        if (-not (Test-OrdinalIgnoreCaseEqual ([string]$response.tenant) $ExpectedTenantId)) {
            throw 'Azure CLI returned an Exchange Online access token for a different tenant.'
        }
        $accessToken = [string]$response.accessToken
        if ([string]::IsNullOrWhiteSpace($accessToken)) {
            throw 'Azure CLI returned an empty Exchange Online access token.'
        }
        return $accessToken
    }
    finally {
        $responseJson = $null
        $response = $null
    }
}

function Invoke-ExchangeOnlineTokenConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AccessToken,
        [Parameter(Mandatory)][string] $ExpectedTenantId,
        [Parameter(Mandatory)][string] $ExpectedAdminUpn
    )

    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Connect-ExchangeOnline -AccessToken $AccessToken -Organization $ExpectedTenantId `
        -UserPrincipalName $ExpectedAdminUpn -ShowBanner:$false -ErrorAction Stop
}

function Get-ActiveExchangeOnlineConnections {
    [CmdletBinding()]
    param()

    return @(Get-ConnectionInformation)
}

function Connect-AzdExchangeOnline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedTenantId,
        [Parameter(Mandatory)][string] $ExpectedAdminUpn
    )

    $accessToken = $null
    try {
        $accessToken = Get-AzureCliExchangeAccessToken -ExpectedTenantId $ExpectedTenantId
        Invoke-ExchangeOnlineTokenConnection -AccessToken $accessToken -ExpectedTenantId $ExpectedTenantId `
            -ExpectedAdminUpn $ExpectedAdminUpn
        return Assert-ExactExchangeConnection -Connections @(Get-ActiveExchangeOnlineConnections) `
            -ExpectedTenantId $ExpectedTenantId -ExpectedAdminUpn $ExpectedAdminUpn
    }
    finally {
        $accessToken = $null
    }
}

function Assert-RecordedExchangeBinding {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string] $RecordedClientId,
        [AllowEmptyString()][string] $RecordedPrincipalId,
        [AllowEmptyString()][string] $RecordedAdminUpn,
        [AllowEmptyString()][string] $RecordedTenantId,
        [AllowEmptyString()][string] $RecordedSenderMailbox,
        [Parameter(Mandatory)][string] $ExpectedClientId,
        [Parameter(Mandatory)][string] $ExpectedPrincipalId,
        [Parameter(Mandatory)][string] $ExpectedAdminUpn,
        [Parameter(Mandatory)][string] $ExpectedTenantId,
        [Parameter(Mandatory)][string] $ExpectedSenderMailbox,
        [switch] $RequireRecorded
    )

    foreach ($binding in @(
            @{ Name = 'workload client ID'; Recorded = $RecordedClientId; Expected = $ExpectedClientId },
            @{ Name = 'workload principal ID'; Recorded = $RecordedPrincipalId; Expected = $ExpectedPrincipalId },
            @{ Name = 'Exchange administrator UPN'; Recorded = $RecordedAdminUpn; Expected = $ExpectedAdminUpn },
            @{ Name = 'Exchange tenant ID'; Recorded = $RecordedTenantId; Expected = $ExpectedTenantId },
            @{ Name = 'Exchange sender mailbox'; Recorded = $RecordedSenderMailbox; Expected = $ExpectedSenderMailbox }
        )) {
        if ($RequireRecorded -and -not $binding.Recorded) {
            throw "Recorded $($binding.Name) is missing. Refusing incomplete Exchange ownership state."
        }
        if ($binding.Recorded -and -not (Test-OrdinalIgnoreCaseEqual $binding.Recorded $binding.Expected)) {
            throw "Recorded $($binding.Name) '$($binding.Recorded)' does not match '$($binding.Expected)'. Refusing to retarget Exchange ownership state."
        }
    }
}

function Resolve-ExchangeObjectOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $Exists,
        [AllowEmptyString()][string] $RecordedOwnership,
        [switch] $AdoptExisting,
        [Parameter(Mandatory)][string] $ObjectDescription
    )

    $valid = @('', 'create-pending', 'created', 'adopted')
    if ($RecordedOwnership -notin $valid) {
        throw "Recorded ownership '$RecordedOwnership' for $ObjectDescription is invalid."
    }
    if ($Exists) {
        if ($RecordedOwnership -in @('create-pending', 'created')) { return 'created' }
        if ($RecordedOwnership -eq 'adopted') { return 'adopted' }
        if ($AdoptExisting) { return 'adopted' }
        throw "Existing $ObjectDescription requires explicit -AdoptExisting approval."
    }
    if ($RecordedOwnership -eq 'adopted') {
        throw "The adopted $ObjectDescription is missing. Refusing to replace it as a solution-owned object."
    }
    return 'create-pending'
}

function Test-ExchangeOwnershipRemovable {
    [CmdletBinding()]
    param([AllowEmptyString()][string] $Ownership)

    if ($Ownership -notin @('', 'create-pending', 'created', 'adopted')) {
        throw "Recorded Exchange ownership '$Ownership' is invalid."
    }
    return $Ownership -in @('create-pending', 'created')
}

function Assert-ExchangeServicePrincipalExact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $ServicePrincipal,
        [Parameter(Mandatory)][string] $ExpectedClientId,
        [Parameter(Mandatory)][string] $ExpectedPrincipalId
    )

    if (-not (Test-OrdinalIgnoreCaseEqual ([string]$ServicePrincipal.AppId) $ExpectedClientId) -or
        -not (Test-OrdinalIgnoreCaseEqual ([string]$ServicePrincipal.ObjectId) $ExpectedPrincipalId)) {
        throw 'The Exchange service-principal pointer does not match the exact workload client and principal IDs.'
    }
}

function Assert-ExchangeScopeExact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Scope,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $ScopedRecipients,
        [Parameter(Mandatory)][string] $ExpectedScopeName,
        [Parameter(Mandatory)][string] $ExpectedSenderMailbox
    )

    if (-not (Test-OrdinalIgnoreCaseEqual ([string]$Scope.Name) $ExpectedScopeName) -or
        $ScopedRecipients.Count -ne 1 -or
        -not (Test-OrdinalIgnoreCaseEqual ([string]$ScopedRecipients[0].PrimarySmtpAddress) $ExpectedSenderMailbox) -or
        [string]$ScopedRecipients[0].RecipientTypeDetails -ne 'SharedMailbox') {
        throw "Exchange management scope '$ExpectedScopeName' must resolve exclusively to shared mailbox '$ExpectedSenderMailbox'."
    }
}

function Assert-ExchangeAssignmentExact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Assignment,
        [Parameter(Mandatory)][string] $ExpectedAssignmentName,
        [Parameter(Mandatory)][string] $ExpectedScopeName,
        [Parameter(Mandatory)][string] $ExpectedPrincipalId
    )

    if (-not (Test-OrdinalIgnoreCaseEqual ([string]$Assignment.Name) $ExpectedAssignmentName) -or
        [string]$Assignment.Role -ne 'Application Mail.Send' -or
        -not (Test-OrdinalIgnoreCaseEqual ([string]$Assignment.CustomResourceScope) $ExpectedScopeName) -or
        -not (Test-OrdinalIgnoreCaseEqual ([string]$Assignment.App) $ExpectedPrincipalId)) {
        throw "Exchange role assignment '$ExpectedAssignmentName' does not match the exact app, role, and scope."
    }
}

function Wait-ExchangeObjectAbsent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $Lookup,
        [Parameter(Mandatory)][string] $ObjectDescription,
        [ValidateRange(1, 20)][int] $Attempts = 6,
        [ValidateRange(0, 30)][int] $DelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if (@(& $Lookup).Count -eq 0) { return }
        if ($attempt -lt $Attempts -and $DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
    }
    throw "$ObjectDescription still exists after deletion. Ownership receipts were retained."
}

Export-ModuleMember -Function Assert-ExactExchangeConnection, Connect-AzdExchangeOnline, Assert-RecordedExchangeBinding,
    Resolve-ExchangeObjectOwnership, Test-ExchangeOwnershipRemovable, Assert-ExchangeServicePrincipalExact,
    Assert-ExchangeScopeExact, Assert-ExchangeAssignmentExact, Wait-ExchangeObjectAbsent
