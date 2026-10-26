# Bailey Player - uninstall.
# Run:  powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\BaileyPlayer\uninstall.ps1"
# Removes Bailey Player's shortcuts, "Open with" entries and its folder
# (including the recent list and remembered VR settings). mpv itself is left installed.

$ErrorActionPreference = 'Continue'
$AppDir = Join-Path $env:LOCALAPPDATA 'BaileyPlayer'

$answer = Read-Host 'Remove Bailey Player and its saved settings? (y/n)'
if ($answer -notmatch '^[yY]') { Write-Host 'Nothing removed.'; return }

foreach ($place in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $place 'Bailey Player.lnk')
}

$classes = 'HKCU:\Software\Classes'
$progId = 'BaileyPlayer.Video'
$exts = @('.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v', '.wmv', '.ts', '.m2ts', '.mts', '.flv', '.mpg', '.mpeg', '.ogv', '.3gp')
foreach ($ext in $exts) {
    Remove-ItemProperty -Path "$classes\$ext\OpenWithProgids" -Name $progId -ErrorAction SilentlyContinue
}
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$classes\$progId"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 'HKCU:\Software\BaileyPlayer'
Remove-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' -Name 'Bailey Player' -ErrorAction SilentlyContinue

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $AppDir
Write-Host 'Bailey Player removed. mpv is still installed.'
