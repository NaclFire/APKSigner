$ErrorActionPreference = 'Stop'

$project = Split-Path -Parent $PSScriptRoot
$release = Join-Path $project 'build\windows\x64\runner\Release'
$dist = Join-Path $project 'dist'
$nsi = Join-Path $PSScriptRoot 'apk_signer.nsi'
$makensis = 'C:\Users\Fire\AppData\Local\electron-builder\Cache\nsis-3.0.4.1\nsis-3.0.4.1-1mx3n\Bin\makensis.exe'
$output = Join-Path $dist 'APKSigner-Setup-1.0.0.exe'

if (-not (Test-Path (Join-Path $release 'apk_signer.exe'))) {
  throw "Release build not found: $release"
}
if (-not (Test-Path $makensis)) {
  throw "NSIS compiler not found: $makensis"
}

New-Item -ItemType Directory -Path $dist -Force | Out-Null
Remove-Item $output -Force -ErrorAction SilentlyContinue

& $makensis /V3 /DPRODUCT_VERSION=1.0.0 $nsi
if ($LASTEXITCODE -ne 0) {
  throw "NSIS compilation failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path $output)) {
  throw "NSIS did not create $output"
}

Get-Item $output | Select-Object FullName, Length, LastWriteTime
