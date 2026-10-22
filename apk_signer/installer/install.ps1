$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$defaultPath = Join-Path $env:LOCALAPPDATA 'Programs\APKSigner'

$form = New-Object System.Windows.Forms.Form
$form.Text = 'APK Signer Setup'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(560, 210)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(24, 20)
$title.AutoSize = $true
$title.Text = 'Choose an installation folder for APK Signer:'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$form.Controls.Add($title)

$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.Location = New-Object System.Drawing.Point(24, 58)
$pathBox.Size = New-Object System.Drawing.Size(390, 28)
$pathBox.Text = $defaultPath
$form.Controls.Add($pathBox)

$browse = New-Object System.Windows.Forms.Button
$browse.Location = New-Object System.Drawing.Point(424, 56)
$browse.Size = New-Object System.Drawing.Size(95, 30)
$browse.Text = 'Browse...'
$browse.Add_Click({
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = 'Choose an installation folder'
  $dialog.SelectedPath = $pathBox.Text
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $pathBox.Text = $dialog.SelectedPath
  }
})
$form.Controls.Add($browse)

$hint = New-Object System.Windows.Forms.Label
$hint.Location = New-Object System.Drawing.Point(24, 95)
$hint.AutoSize = $true
$hint.Text = 'Shortcuts will be created on the desktop and in the Start menu.'
$hint.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($hint)

$install = New-Object System.Windows.Forms.Button
$install.Location = New-Object System.Drawing.Point(328, 132)
$install.Size = New-Object System.Drawing.Size(92, 32)
$install.Text = 'Install'
$install.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.Controls.Add($install)
$form.AcceptButton = $install

$cancel = New-Object System.Windows.Forms.Button
$cancel.Location = New-Object System.Drawing.Point(427, 132)
$cancel.Size = New-Object System.Drawing.Size(92, 32)
$cancel.Text = 'Cancel'
$cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($cancel)
$form.CancelButton = $cancel

if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
  exit 0
}

$target = $pathBox.Text.Trim()
if ([string]::IsNullOrWhiteSpace($target)) {
  [System.Windows.Forms.MessageBox]::Show('Please choose a valid installation folder.', 'Installation failed', 'OK', 'Error') | Out-Null
  exit 1
}

try {
  if (Test-Path $target) {
    $existingExe = Join-Path $target 'apk_signer.exe'
    if (Test-Path $existingExe) {
      $answer = [System.Windows.Forms.MessageBox]::Show(
        'The selected folder already exists. Overwrite the existing files?',
        'Confirm installation',
        'YesNo',
        'Question')
      if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        exit 0
      }
    }
  } else {
    New-Item -ItemType Directory -Path $target -Force | Out-Null
  }

  $extractPath = Join-Path ([System.IO.Path]::GetTempPath()) ('APKSigner-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
  try {
    Expand-Archive -LiteralPath (Join-Path $PSScriptRoot 'payload.zip') -DestinationPath $extractPath -Force
    Copy-Item -Path (Join-Path $extractPath '*') -Destination $target -Recurse -Force
  } finally {
    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
  }

  $exePath = Join-Path $target 'apk_signer.exe'
  $shell = New-Object -ComObject WScript.Shell
  $desktop = [Environment]::GetFolderPath('Desktop')
  $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\APK Signer'
  New-Item -ItemType Directory -Path $startMenu -Force | Out-Null

  foreach ($shortcutPath in @(
    (Join-Path $desktop 'APK Signer.lnk'),
    (Join-Path $startMenu 'APK Signer.lnk')
  )) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $exePath
    $shortcut.WorkingDirectory = $target
    $shortcut.IconLocation = "$exePath,0"
    $shortcut.Description = 'APK Signer'
    $shortcut.Save()
  }

  [System.Windows.Forms.MessageBox]::Show(
    "Installation completed.`n`nInstall folder: $target",
    'APK Signer',
    'OK',
    'Information') | Out-Null
} catch {
  [System.Windows.Forms.MessageBox]::Show(
    "Installation failed: $($_.Exception.Message)",
    'Installation failed',
    'OK',
    'Error') | Out-Null
  exit 1
}
