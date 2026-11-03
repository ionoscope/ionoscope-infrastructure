param([switch]$Disable)
$ErrorActionPreference = 'Stop'
$startupDirectory = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDirectory 'Ionoscope.lnk'
if ($Disable) {
    if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath }
    Write-Host 'Ionoscope automatic startup disabled. Data and containers are preserved.'
    return
}
$scriptPath = Join-Path $PSScriptRoot 'autostart.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) { throw 'autostart.ps1 is missing.' }
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shortcut.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.WindowStyle = 7
$shortcut.Description = 'Start Ionoscope services and resume live model comparison after Windows sign-in.'
$shortcut.Save()
Write-Host ('Automatic startup enabled for the current Windows user: ' + $shortcutPath)
Write-Host 'Docker Desktop and all implemented Ionoscope services start after sign-in. No rebuild or image download.'
