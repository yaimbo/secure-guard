#Requires -RunAsAdministrator
<#
.SYNOPSIS
    SecureGuard VPN Service Installer for Windows

.DESCRIPTION
    This script installs the SecureGuard VPN daemon as a Windows Service
    with proper security configuration.

.PARAMETER BinaryPath
    Path to the secureguard-service.exe binary. If not specified,
    searches common locations.

.PARAMETER DataDir
    Directory for service data. Defaults to C:\ProgramData\SecureGuard

.PARAMETER Uninstall
    Uninstall the service instead of installing.

.EXAMPLE
    .\install.ps1
    Installs the service using auto-detected binary location.

.EXAMPLE
    .\install.ps1 -BinaryPath "C:\path\to\secureguard-service.exe"
    Installs the service using the specified binary.

.EXAMPLE
    .\install.ps1 -Uninstall
    Uninstalls the service.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$BinaryPath,

    [Parameter(Mandatory=$false)]
    [string]$DataDir = "C:\ProgramData\SecureGuard",

    [Parameter(Mandatory=$false)]
    [switch]$Uninstall
)

# Configuration
$ServiceName = "SecureGuardVPN"
$ServiceDisplayName = "SecureGuard VPN Service"
$ServiceDescription = "WireGuard-compatible VPN daemon for SecureGuard"
$InstallDir = "C:\Program Files\SecureGuard"
$TokenDir = "$DataDir"
$TokenFile = "$TokenDir\auth-token"
$HttpPort = 51820
$LogDir = "$DataDir\logs"

# Colors and logging
function Write-Info { Write-Host "[INFO] $args" -ForegroundColor Green }
function Write-Warn { Write-Host "[WARN] $args" -ForegroundColor Yellow }
function Write-Err { Write-Host "[ERROR] $args" -ForegroundColor Red }

# Print banner
Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       SecureGuard VPN Service Installer for Windows       ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Check if running as administrator
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Err "This script must be run as Administrator"
    Write-Host "Right-click PowerShell and select 'Run as Administrator'"
    exit 1
}

# Find binary
function Find-Binary {
    $locations = @(
        $BinaryPath,
        "$PSScriptRoot\secureguard-service.exe",
        "$PSScriptRoot\..\..\target\release\secureguard-poc.exe",
        "$env:TEMP\secureguard-service.exe"
    )

    foreach ($path in $locations) {
        if ($path -and (Test-Path $path)) {
            return (Resolve-Path $path).Path
        }
    }

    return $null
}

# Verify binary
function Test-Binary {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $false
    }

    # Check if it's a valid Windows executable
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) {  # MZ header
            return $true
        }
    } catch {
        return $false
    }

    return $false
}

# Calculate file hash
function Get-FileHashValue {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

# Stop existing service
function Stop-ExistingService {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if ($service) {
        if ($service.Status -eq 'Running') {
            Write-Info "Stopping existing service..."
            Stop-Service -Name $ServiceName -Force
            Start-Sleep -Seconds 2
        }
    }
}

# Remove existing service
function Remove-ExistingService {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if ($service) {
        Write-Info "Removing existing service..."
        sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 1
    }
}

# Create directories
function New-Directories {
    Write-Info "Creating directories..."

    $dirs = @($InstallDir, $DataDir, $LogDir)

    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # Set permissions on data directory:
    # - SYSTEM and Administrators: Full Control
    # - Users: Read (for token access)
    Write-Info "Setting directory permissions..."
    $acl = Get-Acl $DataDir
    $acl.SetAccessRuleProtection($true, $false)  # Disable inheritance

    # Allow SYSTEM full control
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    # Allow Administrators full control
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    # Allow Users read access (for token file)
    $usersRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Users", "Read,ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
    )

    $acl.AddAccessRule($systemRule)
    $acl.AddAccessRule($adminRule)
    $acl.AddAccessRule($usersRule)
    Set-Acl -Path $DataDir -AclObject $acl
}

# Install binary
function Install-Binary {
    param([string]$SourcePath)

    $destPath = "$InstallDir\secureguard-service.exe"

    Write-Info "Installing binary..."

    Copy-Item -Path $SourcePath -Destination $destPath -Force

    # Verify copy
    $srcHash = Get-FileHashValue -Path $SourcePath
    $destHash = Get-FileHashValue -Path $destPath

    if ($srcHash -ne $destHash) {
        Write-Err "Binary verification failed!"
        exit 1
    }

    Write-Info "Binary installed and verified (SHA256: $($destHash.Substring(0, 16))...)"

    return $destPath
}

# Install uninstall script (for in-app uninstall feature)
function Install-UninstallScript {
    $scriptSource = Join-Path $PSScriptRoot "uninstall.ps1"
    $scriptDest = "$InstallDir\uninstall.ps1"

    if (Test-Path $scriptSource) {
        Write-Info "Installing uninstall script..."
        Copy-Item -Path $scriptSource -Destination $scriptDest -Force
        Write-Info "Uninstall script installed to $scriptDest"
    } else {
        Write-Warn "Uninstall script not found at $scriptSource"
    }
}

# Create Windows Service
function New-VpnService {
    param([string]$BinaryPath)

    Write-Info "Creating Windows Service..."

    # Service command line (uses HTTP API on localhost)
    $binPathArg = "`"$BinaryPath`" --daemon --port $HttpPort"

    # Create the service
    $result = sc.exe create $ServiceName `
        binPath= $binPathArg `
        start= auto `
        DisplayName= $ServiceDisplayName `
        obj= "LocalSystem"

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to create service"
        exit 1
    }

    # Set description
    sc.exe description $ServiceName $ServiceDescription | Out-Null

    # Set recovery options (restart on failure)
    sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

    # Set delayed auto-start for better boot performance
    sc.exe config $ServiceName start= delayed-auto | Out-Null

    Write-Info "Service created successfully"
}

# Start service
function Start-VpnService {
    Write-Info "Starting service..."

    Start-Service -Name $ServiceName

    # Wait for service to start
    $timeout = 30
    $elapsed = 0
    while ($elapsed -lt $timeout) {
        $service = Get-Service -Name $ServiceName
        if ($service.Status -eq 'Running') {
            Write-Info "Service started successfully"
            return $true
        }
        Start-Sleep -Seconds 1
        $elapsed++
    }

    Write-Warn "Service may not have started correctly"
    return $false
}

# Configure Windows Firewall
function Set-FirewallRules {
    Write-Info "Configuring firewall rules..."

    # Remove existing rules
    Get-NetFirewallRule -DisplayName "SecureGuard*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue

    # Allow outbound UDP (WireGuard default port)
    New-NetFirewallRule -DisplayName "SecureGuard VPN (UDP Out)" `
        -Direction Outbound -Protocol UDP -LocalPort Any -RemotePort 51820 `
        -Action Allow -Profile Any | Out-Null

    # Allow inbound for TUN adapter (will be enabled when VPN is active)
    # Note: Actual rules depend on VPN configuration

    Write-Info "Firewall rules configured"
}

# Print success
function Write-Success {
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║            Installation Complete Successfully!            ║" -ForegroundColor Green
    Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "Service Details:"
    Write-Host "  Name:    $ServiceName"
    Write-Host "  Binary:  $InstallDir\secureguard-service.exe"
    Write-Host "  API:     http://127.0.0.1:$HttpPort/api/v1"
    Write-Host "  Token:   $TokenFile"
    Write-Host "  Data:    $DataDir"
    Write-Host ""
    Write-Host "Authentication:"
    Write-Host "  All local users can access the daemon API via the token file."
    Write-Host ""
    Write-Host "Management Commands (PowerShell as Admin):"
    Write-Host "  Status:  Get-Service $ServiceName"
    Write-Host "  Stop:    Stop-Service $ServiceName"
    Write-Host "  Start:   Start-Service $ServiceName"
    Write-Host "  Logs:    Get-EventLog -LogName Application -Source $ServiceName"
    Write-Host ""
}

# Uninstall function
function Uninstall-Service {
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║      SecureGuard VPN Service Uninstaller for Windows      ║" -ForegroundColor Yellow
    Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""

    Stop-ExistingService
    Remove-ExistingService

    # Remove firewall rules
    Write-Info "Removing firewall rules..."
    Get-NetFirewallRule -DisplayName "SecureGuard*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue

    # Remove binary
    if (Test-Path "$InstallDir\secureguard-service.exe") {
        Write-Info "Removing binary..."
        Remove-Item -Path "$InstallDir\secureguard-service.exe" -Force
    }

    # Optionally remove install directory if empty
    if ((Test-Path $InstallDir) -and ((Get-ChildItem $InstallDir | Measure-Object).Count -eq 0)) {
        Remove-Item -Path $InstallDir -Force
    }

    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║           Uninstallation Complete Successfully!           ║" -ForegroundColor Green
    Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "Note: Data directory preserved at $DataDir"
    Write-Host "      To remove: Remove-Item -Recurse -Force '$DataDir'"
    Write-Host ""
}

# Main
function Main {
    if ($Uninstall) {
        Uninstall-Service
        return
    }

    # Find and verify binary
    $binary = Find-Binary
    if (-not $binary) {
        Write-Err "Could not find secureguard binary"
        Write-Host ""
        Write-Host "Please either:"
        Write-Host "  1. Build with: cargo build --release"
        Write-Host "  2. Specify path: .\install.ps1 -BinaryPath 'C:\path\to\secureguard-service.exe'"
        exit 1
    }

    Write-Info "Found binary: $binary"

    if (-not (Test-Binary -Path $binary)) {
        Write-Err "Binary is not a valid Windows executable"
        exit 1
    }

    # Install
    Stop-ExistingService
    Remove-ExistingService
    New-Directories

    $installedBinary = Install-Binary -SourcePath $binary
    Install-UninstallScript
    New-VpnService -BinaryPath $installedBinary
    Set-FirewallRules

    if (Start-VpnService) {
        Write-Success
    } else {
        Write-Err "Installation completed but service may have issues"
        Write-Host "Check Event Viewer > Windows Logs > Application for errors"
        exit 1
    }
}

Main
