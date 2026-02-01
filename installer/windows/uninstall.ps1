# SecureGuard VPN Service Uninstaller for Windows
# This script removes the daemon service and cleans up

param(
    [switch]$All,
    [switch]$Data,
    [switch]$Logs,
    [switch]$Help
)

# Configuration
$ServiceName = "SecureGuardVPN"
$InstallDir = "$env:ProgramFiles\SecureGuard"
$DataDir = "$env:ProgramData\SecureGuard"
$LogDir = "$env:ProgramData\SecureGuard\logs"

# Show help
if ($Help) {
    Write-Host ""
    Write-Host "MinnowVPN Uninstaller for Windows"
    Write-Host ""
    Write-Host "Usage: .\uninstall.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -All     Remove everything including data and logs"
    Write-Host "  -Data    Remove data directory"
    Write-Host "  -Logs    Remove log files"
    Write-Host "  -Help    Show this help message"
    Write-Host ""
    exit 0
}

# Check for administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] This script must be run as Administrator" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator'"
    exit 1
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  MinnowVPN Uninstaller"
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# Enable all removal if -All specified
if ($All) {
    $Data = $true
    $Logs = $true
}

# Stop Flutter desktop app if running
function Stop-SecureGuardApp {
    Write-Host "[INFO] Checking for running MinnowVPN app..." -ForegroundColor Green

    # Try various possible process names for the Flutter app
    $processNames = @("SecureGuard", "secureguard_client", "secureguard")

    foreach ($procName in $processNames) {
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Host "[INFO] Stopping $procName..." -ForegroundColor Green
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }
}

# Stop and remove service
function Remove-SecureGuardService {
    Write-Host "[INFO] Checking for service..." -ForegroundColor Green

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -eq 'Running') {
            Write-Host "[INFO] Stopping service..." -ForegroundColor Green
            Stop-Service -Name $ServiceName -Force
            Start-Sleep -Seconds 2
        }

        Write-Host "[INFO] Removing service..." -ForegroundColor Green
        sc.exe delete $ServiceName | Out-Null
    } else {
        Write-Host "[INFO] Service not installed" -ForegroundColor Yellow
    }
}

# Remove installation directory
function Remove-InstallDirectory {
    if (Test-Path $InstallDir) {
        Write-Host "[INFO] Removing installation directory..." -ForegroundColor Green
        Remove-Item -Path $InstallDir -Recurse -Force
    }
}

# Remove data directory (optional)
function Remove-DataDirectory {
    if ($Data -and (Test-Path $DataDir)) {
        Write-Host "[INFO] Removing data directory..." -ForegroundColor Green
        Remove-Item -Path $DataDir -Recurse -Force
    }
}

# Remove logs (optional)
function Remove-LogFiles {
    if ($Logs -and (Test-Path $LogDir)) {
        Write-Host "[INFO] Removing log files..." -ForegroundColor Green
        Remove-Item -Path $LogDir -Recurse -Force
    }
}

# Remove Start Menu shortcut
function Remove-StartMenuShortcut {
    $shortcutPath = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\MinnowVPN.lnk"
    if (Test-Path $shortcutPath) {
        Write-Host "[INFO] Removing Start Menu shortcut..." -ForegroundColor Green
        Remove-Item -Path $shortcutPath -Force
    }
}

# Remove Desktop shortcuts (for all users and current user)
function Remove-DesktopShortcuts {
    $shortcuts = @(
        "$env:PUBLIC\Desktop\MinnowVPN.lnk",
        "$env:USERPROFILE\Desktop\MinnowVPN.lnk"
    )

    foreach ($shortcut in $shortcuts) {
        if (Test-Path $shortcut) {
            Write-Host "[INFO] Removing desktop shortcut: $shortcut" -ForegroundColor Green
            Remove-Item -Path $shortcut -Force
        }
    }
}

# Remove URL scheme registration
function Remove-UrlScheme {
    $regPath = "HKCR:\secureguard"
    if (Test-Path $regPath) {
        Write-Host "[INFO] Removing URL scheme registration..." -ForegroundColor Green
        Remove-Item -Path $regPath -Recurse -Force
    }
}

# Print completion message
function Show-CompletionMessage {
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "  Uninstallation Complete!" -ForegroundColor Green
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host ""

    if (-not $Data -and (Test-Path $DataDir)) {
        Write-Host "Note: Data directory preserved at $DataDir" -ForegroundColor Yellow
        Write-Host "      To remove: Remove-Item -Path '$DataDir' -Recurse -Force"
        Write-Host ""
    }

    Write-Host "To completely remove all traces, run:"
    Write-Host "  .\uninstall.ps1 -All"
    Write-Host ""
}

# Main uninstallation flow
try {
    Stop-SecureGuardApp
    Remove-SecureGuardService
    Remove-StartMenuShortcut
    Remove-DesktopShortcuts
    Remove-UrlScheme
    Remove-InstallDirectory
    Remove-DataDirectory
    Remove-LogFiles
    Show-CompletionMessage
    exit 0
} catch {
    Write-Host "[ERROR] Uninstallation failed: $_" -ForegroundColor Red
    exit 1
}
