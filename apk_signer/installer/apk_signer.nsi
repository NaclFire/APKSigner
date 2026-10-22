Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"

!ifndef PRODUCT_VERSION
  !define PRODUCT_VERSION "1.0.0"
!endif

!define PRODUCT_NAME "APK Signer"
!define PRODUCT_EXE "apk_signer.exe"
!define PRODUCT_ID "APKSigner"
!define INSTALL_ROOT "E:\apsig\build\windows\x64\runner\Release"

Name "${PRODUCT_NAME}"
Caption "APK 签名工具安装程序"
OutFile "E:\apsig\dist\APKSigner-Setup-${PRODUCT_VERSION}.exe"
InstallDir "$LOCALAPPDATA\Programs\${PRODUCT_ID}"
InstallDirRegKey HKCU "Software\${PRODUCT_ID}" "InstallDir"
RequestExecutionLevel user
BrandingText "APK 签名工具"
ShowInstDetails show
ShowUninstDetails show
SetCompressor /SOLID lzma
SetCompressorDictSize 64

VIProductVersion "${PRODUCT_VERSION}.0"
VIAddVersionKey /LANG=1033 "ProductName" "${PRODUCT_NAME}"
VIAddVersionKey /LANG=1033 "ProductVersion" "${PRODUCT_VERSION}"
VIAddVersionKey /LANG=1033 "FileDescription" "APK signing tool"
VIAddVersionKey /LANG=1033 "CompanyName" "APK Signer"

Icon "E:\apsig\windows\runner\resources\app_icon.ico"
UninstallIcon "E:\apsig\windows\runner\resources\app_icon.ico"

!define MUI_ABORTWARNING
!define MUI_ICON "E:\apsig\windows\runner\resources\app_icon.ico"
!define MUI_UNICON "E:\apsig\windows\runner\resources\app_icon.ico"
!define MUI_WELCOMEPAGE_TITLE "APK 签名工具安装向导"
!define MUI_WELCOMEPAGE_TEXT "此向导将帮助您在计算机上安装 APK 签名工具。"
!define MUI_FINISHPAGE_RUN "$INSTDIR\${PRODUCT_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "运行 APK 签名工具"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "打开安装目录"
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "${PRODUCT_NAME}" MainSection
  SectionIn RO
  SetOutPath "$INSTDIR"
  File /r "${INSTALL_ROOT}\*"

  WriteRegStr HKCU "Software\${PRODUCT_ID}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "DisplayName" "${PRODUCT_NAME}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "DisplayVersion" "${PRODUCT_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "Publisher" "${PRODUCT_NAME}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "UninstallString" "$INSTDIR\Uninstall.exe"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "NoRepair" 1

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\${PRODUCT_NAME}"
  CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_EXE}" "" "$INSTDIR\${PRODUCT_EXE}" 0
  CreateShortCut "$DESKTOP\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_EXE}" "" "$INSTDIR\${PRODUCT_EXE}" 0
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\${PRODUCT_NAME}.lnk"
  Delete "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk"
  RMDir "$SMPROGRAMS\${PRODUCT_NAME}"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}"
  DeleteRegKey HKCU "Software\${PRODUCT_ID}"
  RMDir /r "$INSTDIR"
SectionEnd
