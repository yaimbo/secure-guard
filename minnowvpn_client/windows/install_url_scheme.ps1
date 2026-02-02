#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers the minnowvpn:// URL scheme for MinnowVPN VPN Client

.DESCRIPTION
    This script registers the minnowvpn:// custom URL scheme in the Windows Registry,
    allowing deep links to open the MinnowVPN VPN client application.

.PARAMETER ExePath
    Path to the minnowvpn_client.exe. If not specified, searches common locations.

.PARAMETER Uninstall
    Removes the URL scheme registration.

.EXAMPLE
    .\install_url_scheme.ps1
    Registers the URL scheme using auto-detected executable location.

.EXAMPLE
    .\install_url_scheme.ps1 -ExePath "C:\Program Files\MinnowVPN\minnowvpn_client.exe"
    Registers using the specified executable path.

.EXAMPLE
    .\install_url_scheme.ps1 -Uninstall
    Removes the URL scheme registration.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ExePath,

    [Parameter(Mandatory=$false)]
    [switch]$Uninstall
)

$UrlScheme = "minnowvpn"
$RegistryPath = "HKCR:\$UrlScheme"

function Write-Info { Write-Host "[INFO] $args" -ForegroundColor Green }
function Write-Err { Write-Host "[ERROR] $args" -ForegroundColor Red }

# Map HKCR to HKEY_CLASSES_ROOT
if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null
}

function Find-Executable {
    $locations = @(
        $ExePath,
        "$PSScriptRoot\..\build\windows\x64\runner\Release\minnowvpn_client.exe",
        "$PSScriptRoot\minnowvpn_client.exe",
        "C:\Program Files\MinnowVPN\minnowvpn_client.exe",
        "$env:LOCALAPPDATA\MinnowVPN\minnowvpn_client.exe"
    )

    foreach ($path in $locations) {
        if ($path -and (Test-Path $path)) {
            return (Resolve-Path $path).Path
        }
    }

    return $null
}

function Register-UrlScheme {
    param([string]$ExecutablePath)

    Write-Info "Registering minnowvpn:// URL scheme..."

    # Create root key
    if (-not (Test-Path $RegistryPath)) {
        New-Item -Path $RegistryPath -Force | Out-Null
    }

    # Set default value and URL Protocol
    Set-ItemProperty -Path $RegistryPath -Name "(Default)" -Value "URL:MinnowVPN VPN Protocol"
    Set-ItemProperty -Path $RegistryPath -Name "URL Protocol" -Value ""

    # Create shell\open\command keys
    $commandPath = "$RegistryPath\shell\open\command"
    if (-not (Test-Path $commandPath)) {
        New-Item -Path $commandPath -Force | Out-Null
    }

    # Set command to run the executable with URL as argument
    $command = "`"$ExecutablePath`" `"%1`""
    Set-ItemProperty -Path $commandPath -Name "(Default)" -Value $command

    Write-Info "URL scheme registered successfully"
    Write-Host ""
    Write-Host "Registry entries created:"
    Write-Host "  HKEY_CLASSES_ROOT\minnowvpn"
    Write-Host "  Command: $command"
    Write-Host ""
    Write-Host "Test with: start minnowvpn://enroll?server=test&code=TEST1234"
}

function Unregister-UrlScheme {
    Write-Info "Removing minnowvpn:// URL scheme registration..."

    if (Test-Path $RegistryPath) {
        Remove-Item -Path $RegistryPath -Recurse -Force
        Write-Info "URL scheme removed successfully"
    } else {
        Write-Info "URL scheme was not registered"
    }
}

# Main
if ($Uninstall) {
    Unregister-UrlScheme
    exit 0
}

$exePath = Find-Executable
if (-not $exePath) {
    Write-Err "Could not find minnowvpn_client.exe"
    Write-Host ""
    Write-Host "Please either:"
    Write-Host "  1. Build the Flutter app: flutter build windows"
    Write-Host "  2. Specify path: .\install_url_scheme.ps1 -ExePath 'C:\path\to\minnowvpn_client.exe'"
    exit 1
}

Write-Info "Found executable: $exePath"
Register-UrlScheme -ExecutablePath $exePath
