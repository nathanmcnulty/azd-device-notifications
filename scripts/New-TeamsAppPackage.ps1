[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'teams-app/device-notifications.zip')
)

$ErrorActionPreference = 'Stop'
foreach ($name in @('AZURE_WORKLOAD_CLIENT_ID', 'AZURE_FUNCTION_APP_URL')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required." }
}

function Get-Crc32([byte[]] $Bytes) {
    [uint64]$crc = 4294967295
    foreach ($byte in $Bytes) {
        $crc = ($crc -bxor [uint64]$byte) -band 4294967295
        for ($index = 0; $index -lt 8; $index++) {
            $crc = if ($crc -band 1) { (($crc -shr 1) -bxor 3988292384) -band 4294967295 } else { $crc -shr 1 }
        }
    }
    return [uint32](($crc -bxor 4294967295) -band 4294967295)
}

function Get-BigEndianBytes([uint32] $Value) {
    return [byte[]]@(
        [byte](($Value -shr 24) -band 0xff)
        [byte](($Value -shr 16) -band 0xff)
        [byte](($Value -shr 8) -band 0xff)
        [byte]($Value -band 0xff)
    )
}

function New-Png([string] $Path, [int] $Width, [int] $Height, [byte[]] $Color) {
    $raw = [System.Collections.Generic.List[byte]]::new()
    for ($y = 0; $y -lt $Height; $y++) {
        $raw.Add(0)
        for ($x = 0; $x -lt $Width; $x++) { $raw.AddRange($Color) }
    }
    $compressedStream = [System.IO.MemoryStream]::new()
    $zlib = [System.IO.Compression.ZLibStream]::new($compressedStream, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    $zlib.Write($raw.ToArray(), 0, $raw.Count)
    $zlib.Dispose()

    $output = [System.IO.MemoryStream]::new()
    $signature = [byte[]](137,80,78,71,13,10,26,10)
    $output.Write($signature, 0, $signature.Length)
    $headerData = [byte[]]((Get-BigEndianBytes $Width) + (Get-BigEndianBytes $Height) + [byte[]](8,6,0,0,0))
    foreach ($chunk in @(
        @{ Type = 'IHDR'; Data = $headerData },
        @{ Type = 'IDAT'; Data = $compressedStream.ToArray() },
        @{ Type = 'IEND'; Data = [byte[]]@() }
    )) {
        $type = [Text.Encoding]::ASCII.GetBytes($chunk.Type)
        $data = [byte[]]$chunk.Data
        $length = $data.Length
        $lengthBytes = [byte[]](Get-BigEndianBytes $length)
        $output.Write($lengthBytes, 0, $lengthBytes.Length)
        $output.Write($type, 0, $type.Length)
        $output.Write($data, 0, $data.Length)
        $crcInput = [byte[]]::new($type.Length + $data.Length)
        [Array]::Copy($type, 0, $crcInput, 0, $type.Length)
        [Array]::Copy($data, 0, $crcInput, $type.Length, $data.Length)
        $crc = Get-Crc32 $crcInput
        $crcBytes = [byte[]](Get-BigEndianBytes $crc)
        $output.Write($crcBytes, 0, $crcBytes.Length)
    }
    [IO.File]::WriteAllBytes($Path, $output.ToArray())
}

$outputDirectory = Split-Path $OutputPath -Parent
$staging = Join-Path ([IO.Path]::GetTempPath()) "device-notifications-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $staging -Force | Out-Null
try {
    $hostName = ([uri]$env:AZURE_FUNCTION_APP_URL).Host
    $manifest = @{
        '$schema' = 'https://developer.microsoft.com/json-schemas/teams/v1.17/MicrosoftTeams.schema.json'
        manifestVersion = '1.17'
        version = '1.0.0'
        id = $env:AZURE_WORKLOAD_CLIENT_ID
        packageName = 'com.nathanmcnulty.devicenotifications'
        developer = @{ name = 'Device Notifications'; websiteUrl = 'https://github.com/nathanmcnulty/azd-device-notifications'; privacyUrl = 'https://github.com/nathanmcnulty/azd-device-notifications/blob/main/docs/privacy.md'; termsOfUseUrl = 'https://github.com/nathanmcnulty/azd-device-notifications/blob/main/docs/privacy.md' }
        name = @{ short = 'Device notifications'; full = 'Entra and Intune device lifecycle notifications' }
        description = @{ short = 'Device lifecycle and compliance notifications.'; full = 'Delivers registration, enrollment, and compliance notifications to device owners.' }
        icons = @{ outline = 'outline.png'; color = 'color.png' }
        accentColor = '#005A9E'
        bots = @(@{ botId = $env:AZURE_WORKLOAD_CLIENT_ID; scopes = @('personal'); supportsFiles = $false; isNotificationOnly = $true })
        permissions = @('identity')
        validDomains = @($hostName)
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $staging 'manifest.json') -Encoding utf8NoBOM
    New-Png -Path (Join-Path $staging 'color.png') -Width 192 -Height 192 -Color ([byte[]](0,90,158,255))
    New-Png -Path (Join-Path $staging 'outline.png') -Width 32 -Height 32 -Color ([byte[]](0,0,0,255))
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutputPath -Force
    Write-Host "Teams app package created: $OutputPath"
}
finally { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
