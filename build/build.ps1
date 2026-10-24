#Requires -Version 5.1
[CmdletBinding()]
param(
    # Optional release version, normally taken from the Git tag (for example: V1.2).
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredPs2ExeVersion = [version]'1.0.18'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Zipper can only be packaged on Windows.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceFile = Join-Path $repoRoot 'Zipper.ps1'
$outputDir = Join-Path $repoRoot 'dist'
$outputExe = Join-Path $outputDir 'Zipper.exe'
$checksumFile = Join-Path $outputDir 'Zipper.exe.sha256'

if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
    throw "Source script not found: $sourceFile"
}

$sourceText = [System.IO.File]::ReadAllText($sourceFile, [System.Text.Encoding]::UTF8)
$versionMatch = [regex]::Match(
    $sourceText,
    '(?m)^\s*\$script:Version\s*=\s*[''"](?<version>\d+(?:\.\d+){1,3})[''"]'
)

if (-not $versionMatch.Success) {
    throw "Could not read the application version from Zipper.ps1."
}

function ConvertTo-FourPartVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $normalized = $Text.Trim() -replace '^[vV]', ''
    if ($normalized -notmatch '^\d+(?:\.\d+){1,3}$') {
        throw "Invalid version '$Text'. Use a numeric version such as 1.2 or V1.2.0."
    }

    $parts = @($normalized.Split('.'))
    while ($parts.Count -lt 4) {
        $parts += '0'
    }

    return [System.Version]::Parse(($parts -join '.'))
}

$sourceVersion = ConvertTo-FourPartVersion -Text $versionMatch.Groups['version'].Value
if ([string]::IsNullOrWhiteSpace($Version)) {
    $buildVersion = $sourceVersion
} else {
    $buildVersion = ConvertTo-FourPartVersion -Text $Version
    if ($buildVersion -ne $sourceVersion) {
        throw ("Release tag version {0} does not match Zipper.ps1 version {1}. Update the source version before creating the release tag." -f $buildVersion.ToString(4), $sourceVersion.ToString(4))
    }
}

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Remove only this build's previous outputs, so a failed compile cannot leave a stale EXE.
foreach ($oldOutput in @($outputExe, $checksumFile)) {
    if (Test-Path -LiteralPath $oldOutput -PathType Leaf) {
        Remove-Item -LiteralPath $oldOutput -Force
    }
}

$installedModule = Get-Module -ListAvailable -Name PS2EXE |
    Where-Object { $_.Version -eq $requiredPs2ExeVersion } |
    Select-Object -First 1

if (-not $installedModule) {
    Write-Host "Installing pinned PS2EXE version $requiredPs2ExeVersion from PowerShell Gallery..." -ForegroundColor Cyan
    $installArguments = @{
        Name            = 'PS2EXE'
        RequiredVersion = $requiredPs2ExeVersion.ToString()
        Scope           = 'CurrentUser'
        Repository      = 'PSGallery'
        Force           = $true
        AllowClobber    = $true
        ErrorAction     = 'Stop'
    }
    Install-Module @installArguments
}

Import-Module -Name PS2EXE -RequiredVersion $requiredPs2ExeVersion.ToString() -Force -ErrorAction Stop
if (-not (Get-Command -Name Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    throw 'PS2EXE was installed, but Invoke-ps2exe could not be found.'
}

$compileArguments = @{
    inputFile    = $sourceFile
    outputFile   = $outputExe
    noConsole    = $true
    STA          = $true
    requireAdmin = $true
    noConfigFile = $true
    DPIAware     = $true
    title        = 'Zipper'
    description  = 'Windows Compact OS Tool'
    company      = 'MAKAKAIglitch'
    product      = 'Zipper'
    copyright    = 'Copyright (c) MAKAKAIglitch'
    version      = $buildVersion.ToString(4)
}

# If an icon is added later, it will be picked up automatically.
$iconFile = Join-Path $repoRoot 'assets\Zipper.ico'
if (Test-Path -LiteralPath $iconFile -PathType Leaf) {
    $compileArguments['iconFile'] = $iconFile
}

Write-Host ''
Write-Host "Building Zipper $($buildVersion.ToString(4))..." -ForegroundColor Cyan
Write-Host "Source: $sourceFile"
Write-Host "Output: $outputExe"
Write-Host 'Options: GUI-only, STA, UAC elevation, no sidecar config'
Write-Host ''

Invoke-ps2exe @compileArguments

if (-not (Test-Path -LiteralPath $outputExe -PathType Leaf)) {
    throw 'PS2EXE finished without producing dist\Zipper.exe.'
}

$exeInfo = Get-Item -LiteralPath $outputExe
if ($exeInfo.Length -lt 1024) {
    throw "The generated EXE looks unexpectedly small ($($exeInfo.Length) bytes)."
}

$sha256 = (Get-FileHash -LiteralPath $outputExe -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumText = '{0}  Zipper.exe{1}' -f $sha256, [Environment]::NewLine
[System.IO.File]::WriteAllText($checksumFile, $checksumText, [System.Text.Encoding]::ASCII)

Write-Host ''
Write-Host 'Build completed.' -ForegroundColor Green
Write-Host ('EXE size: {0:N0} bytes' -f $exeInfo.Length)
Write-Host "SHA-256: $sha256"
Write-Host "Checksum: $checksumFile"
Write-Host ''
