$ErrorActionPreference = 'Stop'

$project = Split-Path -Parent $PSScriptRoot
$release = Join-Path $project 'build\windows\x64\runner\Release'
$staging = 'E:\apsig\installer-staging'
$dist = Join-Path $project 'dist'
$payload = Join-Path $staging 'payload'

if (-not (Test-Path (Join-Path $release 'apk_signer.exe'))) {
  throw "Release build not found: $release"
}

Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $payload, $dist -Force | Out-Null

Copy-Item -Path (Join-Path $release '*') -Destination $payload -Recurse -Force
Remove-Item -Path @(
  (Join-Path $payload '*.log'),
  (Join-Path $payload '*stdout*'),
  (Join-Path $payload '*stderr*'),
  (Join-Path $payload 'st_v*.txt'),
  (Join-Path $payload 'se_*.txt')
) -Force -ErrorAction SilentlyContinue

Copy-Item (Join-Path $PSScriptRoot 'install.ps1') $staging -Force
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath (Join-Path $staging 'payload.zip') -CompressionLevel Optimal -Force

$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=1
HidePrompt=1
UseLongFileName=1
InsideCompressed=1
TargetName=E:\apsig\dist\APKSigner-Setup.exe
FriendlyName=APK Signer Setup
AppLaunched=powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles
[Strings]
FILE0=install.ps1
FILE1=payload.zip
[SourceFiles]
SourceFiles0=E:\apsig\installer-staging
[SourceFiles0]
%FILE0%=
%FILE1%=
"@

$sedPath = Join-Path $staging 'APKSigner-Setup.sed'
Set-Content -Path $sedPath -Value $sed -Encoding ASCII

& "$env:WINDIR\System32\iexpress.exe" /N $sedPath
$output = 'E:\apsig\dist\APKSigner-Setup.exe'
$deadline = (Get-Date).AddSeconds(30)
while (-not (Test-Path $output) -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 250
}
if (-not (Test-Path $output)) {
  throw "IExpress did not create $output"
}

Get-Item $output | Select-Object FullName, Length, LastWriteTime
