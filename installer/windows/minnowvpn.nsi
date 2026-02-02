; MinnowVPN VPN Service NSIS Installer
; Build with: makensis minnowvpn.nsi
;
; Prerequisites:
; - NSIS 3.0+ installed
; - minnowvpn-service.exe in this directory
; - Optional: minnowvpn.ico (app icon)
; - Optional: welcome.bmp (installer sidebar image, 164x314 pixels)
; - A LICENSE file in the repo root (or comment out the license page)

;--------------------------------
; Includes

!include "MUI2.nsh"
!include "nsDialogs.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"
!include "x64.nsh"

;--------------------------------
; General Configuration

!define PRODUCT_NAME "MinnowVPN"
!define PRODUCT_VERSION "1.0.0"
!define PRODUCT_PUBLISHER "MinnowVPN"
!define PRODUCT_WEB_SITE "https://minnowvpn.com"
!define SERVICE_NAME "MinnowVPN"

Name "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "MinnowVPN-${PRODUCT_VERSION}-Setup.exe"
InstallDir "$PROGRAMFILES64\MinnowVPN"
InstallDirRegKey HKLM "Software\MinnowVPN" "InstallDir"
RequestExecutionLevel admin
ShowInstDetails show
ShowUnInstDetails show

; Version information
VIProductVersion "${PRODUCT_VERSION}.0"
VIAddVersionKey "ProductName" "${PRODUCT_NAME}"
VIAddVersionKey "CompanyName" "${PRODUCT_PUBLISHER}"
VIAddVersionKey "FileDescription" "${PRODUCT_NAME} Installer"
VIAddVersionKey "FileVersion" "${PRODUCT_VERSION}"
VIAddVersionKey "ProductVersion" "${PRODUCT_VERSION}"

;--------------------------------
; Interface Settings

!define MUI_ABORTWARNING
; Uncomment these lines when icon/bitmap assets are available:
; !define MUI_ICON "minnowvpn.ico"
; !define MUI_UNICON "minnowvpn.ico"
; !define MUI_WELCOMEFINISHPAGE_BITMAP "welcome.bmp"

;--------------------------------
; Pages

!insertmacro MUI_PAGE_WELCOME
; Uncomment when LICENSE file exists in repo root:
; !insertmacro MUI_PAGE_LICENSE "..\..\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

;--------------------------------
; Languages

!insertmacro MUI_LANGUAGE "English"

;--------------------------------
; Functions

Function .onInit
    ; Check Windows version (requires Windows 10+)
    ${IfNot} ${AtLeastWin10}
        MessageBox MB_OK|MB_ICONSTOP "MinnowVPN requires Windows 10 or later."
        Abort
    ${EndIf}

    ; Check for 64-bit
    ${IfNot} ${RunningX64}
        MessageBox MB_OK|MB_ICONSTOP "MinnowVPN requires a 64-bit version of Windows."
        Abort
    ${EndIf}

    ; Check for existing installation
    ReadRegStr $0 HKLM "Software\MinnowVPN" "InstallDir"
    ${If} $0 != ""
        MessageBox MB_YESNO|MB_ICONQUESTION "MinnowVPN is already installed. Do you want to upgrade?" IDYES +2
        Abort
    ${EndIf}
FunctionEnd

;--------------------------------
; Install Section

Section "MinnowVPN Service" SecMain
    SectionIn RO

    SetOutPath "$INSTDIR"

    ; Stop existing service if running
    DetailPrint "Checking for existing service..."
    nsExec::ExecToLog 'sc stop ${SERVICE_NAME}'
    Sleep 2000
    nsExec::ExecToLog 'sc delete ${SERVICE_NAME}'
    Sleep 1000

    ; Install files
    DetailPrint "Installing files..."
    File "minnowvpn-service.exe"

    ; Create data directory
    CreateDirectory "$COMMONPROGRAMDATA\MinnowVPN"
    CreateDirectory "$COMMONPROGRAMDATA\MinnowVPN\logs"

    ; Set permissions on data directory
    ; - SYSTEM and Administrators: Full Control (for daemon and admin management)
    ; - Users: Read access (for Flutter client to read auth token)
    DetailPrint "Setting directory permissions..."
    nsExec::ExecToLog 'icacls "$COMMONPROGRAMDATA\MinnowVPN" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" /grant:r "Administrators:(OI)(CI)F" /grant:r "Users:(OI)(CI)R"'

    ; Create the Windows Service
    DetailPrint "Creating Windows Service..."
    nsExec::ExecToLog 'sc create ${SERVICE_NAME} binPath= "\"$INSTDIR\minnowvpn-service.exe\" --daemon --socket \\.\pipe\minnowvpn" start= auto DisplayName= "${PRODUCT_NAME} Service" obj= "LocalSystem"'

    ; Set service description
    nsExec::ExecToLog 'sc description ${SERVICE_NAME} "WireGuard-compatible VPN daemon for MinnowVPN"'

    ; Set recovery options (restart on failure)
    nsExec::ExecToLog 'sc failure ${SERVICE_NAME} reset= 86400 actions= restart/5000/restart/10000/restart/30000'

    ; Set delayed auto-start
    nsExec::ExecToLog 'sc config ${SERVICE_NAME} start= delayed-auto'

    ; Configure firewall
    DetailPrint "Configuring firewall..."
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="MinnowVPN (UDP Out)"'
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="MinnowVPN (UDP Out)" dir=out action=allow protocol=udp remoteport=51820'

    ; Start the service
    DetailPrint "Starting service..."
    nsExec::ExecToLog 'sc start ${SERVICE_NAME}'

    ; Write registry keys
    WriteRegStr HKLM "Software\MinnowVPN" "InstallDir" "$INSTDIR"
    WriteRegStr HKLM "Software\MinnowVPN" "Version" "${PRODUCT_VERSION}"

    ; Write uninstall information
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MinnowVPN" "DisplayName" "${PRODUCT_NAME}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MinnowVPN" "UninstallString" '"$INSTDIR\uninstall.exe"'
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MinnowVPN" "DisplayIcon" "$INSTDIR\minnowvpn-service.exe"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MinnowVPN" "Publisher" "${PRODUCT_PUBLISHER}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MinnowVPN" "URLInfoAbout" "${PRODUCT_WEB_SITE}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MinnowVPN" "DisplayVersion" "${PRODUCT_VERSION}"
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MinnowVPN" "NoModify" 1
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MinnowVPN" "NoRepair" 1

    ; Create uninstaller
    WriteUninstaller "$INSTDIR\uninstall.exe"

SectionEnd

;--------------------------------
; Uninstall Section

Section "Uninstall"

    ; Stop and remove service
    DetailPrint "Stopping service..."
    nsExec::ExecToLog 'sc stop ${SERVICE_NAME}'
    Sleep 2000
    DetailPrint "Removing service..."
    nsExec::ExecToLog 'sc delete ${SERVICE_NAME}'
    Sleep 1000

    ; Remove firewall rules
    DetailPrint "Removing firewall rules..."
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="MinnowVPN (UDP Out)"'

    ; Remove files
    Delete "$INSTDIR\minnowvpn-service.exe"
    Delete "$INSTDIR\uninstall.exe"
    RMDir "$INSTDIR"

    ; Remove registry keys
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MinnowVPN"
    DeleteRegKey HKLM "Software\MinnowVPN"

    ; Note: We preserve the data directory for user data protection
    DetailPrint "Data directory preserved at: $COMMONPROGRAMDATA\MinnowVPN"
    DetailPrint "To remove manually: rmdir /s /q $COMMONPROGRAMDATA\MinnowVPN"

SectionEnd

;--------------------------------
; Section Descriptions

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
    !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} "Install the MinnowVPN service daemon."
!insertmacro MUI_FUNCTION_DESCRIPTION_END
