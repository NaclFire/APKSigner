Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

!ifndef PRODUCT_VERSION
  !define PRODUCT_VERSION "1.0.0"
!endif

!define PRODUCT_NAME "APK签名工具"
!define PRODUCT_EXE "apk_signer.exe"
!define PRODUCT_ID "APKSigner"
; 用脚本自身位置推导工程根目录，避免把绝对路径写死（工程目录改过名）。
!define PROJECT_ROOT "${__FILEDIR__}\.."
!define INSTALL_ROOT "${PROJECT_ROOT}\build\windows\x64\runner\Release"
!define APP_ICON "${PROJECT_ROOT}\windows\runner\resources\app_icon.ico"

Name "${PRODUCT_NAME}"
Caption "APK签名工具安装程序"
OutFile "${PROJECT_ROOT}\dist\APKSigner-Setup-${PRODUCT_VERSION}.exe"
InstallDir "$LOCALAPPDATA\Programs\${PRODUCT_ID}"
InstallDirRegKey HKCU "Software\${PRODUCT_ID}" "InstallDir"
RequestExecutionLevel user
BrandingText "APK签名工具"
ShowInstDetails show
ShowUninstDetails show
SetCompressor /SOLID lzma
SetCompressorDictSize 64

VIProductVersion "${PRODUCT_VERSION}.0"
VIAddVersionKey /LANG=1033 "ProductName" "${PRODUCT_NAME}"
VIAddVersionKey /LANG=1033 "ProductVersion" "${PRODUCT_VERSION}"
VIAddVersionKey /LANG=1033 "FileDescription" "APK signing tool"
VIAddVersionKey /LANG=1033 "CompanyName" "APK签名工具"

Icon "${APP_ICON}"
UninstallIcon "${APP_ICON}"

!define MUI_ABORTWARNING
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
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

; ---------------------------------------------------------------------------
; 覆盖安装时沿用上一次的安装目录。
; 1) 先读卸载信息 / 安装记录里记下的路径（本版本安装时写入）；
; 2) 老版本可能根本没写注册表，再看几个常见位置；
; 3) 最后扫描所有本地磁盘的 Program Files（老版本装在别的盘也不会丢）。
; ---------------------------------------------------------------------------
Function .onInit
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "InstallLocation"
  ${If} $0 == ""
    ReadRegStr $0 HKCU "Software\${PRODUCT_ID}" "InstallDir"
  ${EndIf}
  ${If} $0 == ""
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "InstallLocation"
  ${EndIf}
  ${If} $0 == ""
    ReadRegStr $0 HKLM "Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "InstallLocation"
  ${EndIf}
  ${If} $0 != ""
  ${AndIf} ${FileExists} "$0\${PRODUCT_EXE}"
    StrCpy $INSTDIR $0
    Return
  ${EndIf}

  StrCpy $1 "$LOCALAPPDATA\Programs\${PRODUCT_ID}"
  ${If} ${FileExists} "$1\${PRODUCT_EXE}"
    StrCpy $INSTDIR $1
    Return
  ${EndIf}
  StrCpy $1 "$PROGRAMFILES64\${PRODUCT_ID}"
  ${If} ${FileExists} "$1\${PRODUCT_EXE}"
    StrCpy $INSTDIR $1
    Return
  ${EndIf}
  StrCpy $1 "$PROGRAMFILES32\${PRODUCT_ID}"
  ${If} ${FileExists} "$1\${PRODUCT_EXE}"
    StrCpy $INSTDIR $1
    Return
  ${EndIf}

  ${GetDrives} "HDD" "DetectExistingInstall"
FunctionEnd

Function DetectExistingInstall
  ; $9 = 盘符根目录（例如 "D:\"）。FindDrives 约定：
  ; 回调里把 $9 设为 StopGetDrives 可结束枚举，返回前必须把 $9 压栈。
  ${If} ${FileExists} "$9Program Files\${PRODUCT_ID}\${PRODUCT_EXE}"
    StrCpy $INSTDIR "$9Program Files\${PRODUCT_ID}"
    StrCpy $9 "StopGetDrives"
  ${ElseIf} ${FileExists} "$9Program Files (x86)\${PRODUCT_ID}\${PRODUCT_EXE}"
    StrCpy $INSTDIR "$9Program Files (x86)\${PRODUCT_ID}"
    StrCpy $9 "StopGetDrives"
  ${EndIf}
  Push $9
FunctionEnd

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
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "DisplayIcon" "$INSTDIR\${PRODUCT_EXE}"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_ID}" "EstimatedSize" $0

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
