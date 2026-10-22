$ErrorActionPreference = 'Stop'

$project = Split-Path -Parent $PSScriptRoot
$release = Join-Path $project 'build\windows\x64\runner\Release'
$dist = Join-Path $project 'dist'
$staging = 'E:\apsig\native-installer-staging'
$payload = Join-Path $staging 'payload'
$output = Join-Path $dist 'APKSigner-Setup.exe'
$template = Join-Path $staging 'APKSigner-Setup.template.exe'
$zipPath = Join-Path $staging 'payload.zip'

if (-not (Test-Path (Join-Path $release 'apk_signer.exe'))) {
  throw "Release build not found: $release"
}

Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $payload, $dist -Force | Out-Null

Copy-Item -Path (Join-Path $release '*') -Destination $payload -Recurse -Force
Remove-Item -Path @(
  (Join-Path $payload '*.log'),
  (Join-Path $payload '*stdout*'),
  (Join-Path $payload '*stderr*'),
  (Join-Path $payload 'st_v*.txt'),
  (Join-Path $payload 'se_*.txt')
) -Force -ErrorAction SilentlyContinue

Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force

$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
  $csc = 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path $csc)) {
  throw 'C# compiler was not found.'
}

$source = Join-Path $PSScriptRoot 'NativeInstaller.cs'
& $csc /nologo /target:winexe /optimize+ /out:$template `
  /reference:System.dll `
  /reference:System.Drawing.dll `
  /reference:System.IO.Compression.dll `
  /reference:System.IO.Compression.FileSystem.dll `
  /reference:System.Windows.Forms.dll `
  /reference:Microsoft.CSharp.dll `
  $source
if ($LASTEXITCODE -ne 0) {
  throw "C# compiler failed with exit code $LASTEXITCODE"
}

Remove-Item $output -Force -ErrorAction SilentlyContinue
Copy-Item $template $output -Force

$magic = [Text.Encoding]::ASCII.GetBytes('APKSIEXE')
$zipLength = (Get-Item $zipPath).Length
$lengthBytes = [BitConverter]::GetBytes([Int64]$zipLength)
$outStream = [System.IO.File]::Open($output, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
try {
  $outStream.Write($magic, 0, $magic.Length)
  $outStream.Write($lengthBytes, 0, $lengthBytes.Length)
  $inStream = [System.IO.File]::OpenRead($zipPath)
  try {
    $inStream.CopyTo($outStream)
  } finally {
    $inStream.Dispose()
  }
} finally {
  $outStream.Dispose()
}

# The native installer reads the footer from the end, so put the length footer
# after the payload as the final 16 bytes.
$bytes = [System.IO.File]::ReadAllBytes($output)
$payloadStart = $bytes.Length - $zipLength - 16
$footer = New-Object byte[] 16
[Array]::Copy($bytes, $payloadStart, $footer, 0, 8)
[Array]::Copy($bytes, $payloadStart + 8, $footer, 8, 8)
$zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
$baseLength = $bytes.Length - $zipLength - 16
$fixed = New-Object byte[] ($baseLength + $zipLength + 16)
[Array]::Copy($bytes, 0, $fixed, 0, $baseLength)
[Array]::Copy($zipBytes, 0, $fixed, $baseLength, $zipLength)
[Array]::Copy($footer, 0, $fixed, $baseLength + $zipLength, 16)
[System.IO.File]::WriteAllBytes($output, $fixed)

Get-Item $output | Select-Object FullName, Length, LastWriteTime
