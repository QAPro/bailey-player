# Bailey Player - install or update.
#
# Run in PowerShell (no admin needed):
#   irm https://raw.githubusercontent.com/QAPro/bailey-player/main/setup.ps1 | iex
#
# What it does:
#   1. Finds mpv (installs it with winget if missing).
#   2. Puts Bailey Player's settings, scripts and fonts in %LOCALAPPDATA%\BaileyPlayer\config.
#      Your recent list, remembered VR settings and resume points are kept on update.
#   3. Downloads uosc (on-screen controls) and thumbfast (seek-bar thumbnails), checksum-checked.
#   4. Makes sure yt-dlp and ffmpeg are there (for playing and downloading links).
#   5. Adds "Bailey Player" to the Start menu and Desktop, and to "Open with" for video files.
# Plain mpv is left exactly as it was.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # makes downloads much faster in Windows PowerShell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo         = 'QAPro/bailey-player'
$Branch       = 'main'
$UoscVersion  = '5.13.0'
$UoscSha256   = '4BE9DA3289285300FA374496C3F1BFD7BB20AC08E890D25BD5A06B28EEBE4882'
$ThumbfastRef = '0f711de3138c9bd6718209d819ac54022c23ded2'
$ThumbfastSha = 'A3D08E71EAE8B892F6CD39F9593EA219768E709312D176BCA883841B156448BF'

$AppDir    = Join-Path $env:LOCALAPPDATA 'BaileyPlayer'
$ConfigDir = Join-Path $AppDir 'config'
$Temp      = Join-Path $env:TEMP ('bailey-player-' + [guid]::NewGuid().ToString('N'))
$Utf8      = New-Object System.Text.UTF8Encoding $false

function Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Green }

function Get-File([string]$Url, [string]$OutFile, [string]$Sha256) {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile
    if ($Sha256) {
        $hash = (Get-FileHash -Algorithm SHA256 -Path $OutFile).Hash
        if ($hash -ne $Sha256) { throw "Checksum mismatch for $Url (got $hash). Nothing was installed from it." }
    }
}

# Create a registry key only if it is missing. (New-Item -Force on an EXISTING key
# empties it, which would wipe other apps' entries - never do that on shared keys.)
function Confirm-Key([string]$Path) {
    if (Test-Path $Path) { return }
    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path $parent)) { Confirm-Key $parent }
    New-Item -Path $Path | Out-Null
}

function Find-Mpv {
    $cmd = Get-Command mpv.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $roots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages')
    )
    foreach ($root in $roots) {
        if ($root -and (Test-Path $root)) {
            $hit = Get-ChildItem -Path $root -Recurse -Filter mpv.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

# yt-dlp / ffmpeg: on PATH, in winget's Links folder, or in winget's package store.
function Find-Tool([string]$Exe) {
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $link = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\$Exe"
    if (Test-Path $link) { return $link }
    $store = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $store) {
        $hit = Get-ChildItem -Path $store -Recurse -Filter $Exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Confirm-Tool([string]$Exe, [string]$WingetId, [string]$Why) {
    $path = Find-Tool $Exe
    if (-not $path) {
        Write-Host "$Exe not found - installing it with winget ($Why)..."
        winget install --id $WingetId --exact --accept-package-agreements --accept-source-agreements | Out-Host
        $path = Find-Tool $Exe
    }
    if ($path) { Write-Host "Using $path" }
    else { Write-Host "Could not install $Exe. $Why will not work until it is installed (winget install $WingetId)." -ForegroundColor Yellow }
    return $path
}

New-Item -ItemType Directory -Force -Path $Temp | Out-Null
try {
    # ---- 1. mpv -------------------------------------------------------------
    Step 'Finding mpv'
    $Mpv = Find-Mpv
    if (-not $Mpv) {
        Write-Host 'mpv not found - installing it with winget...'
        winget install --id shinchiro.mpv --exact --accept-package-agreements --accept-source-agreements
        $Mpv = Find-Mpv
    }
    if (-not $Mpv) { throw 'Could not find mpv.exe. Install it with: winget install shinchiro.mpv' }
    Write-Host "Using $Mpv"

    # ---- 2. Bailey Player files ----------------------------------------------
    Step 'Downloading Bailey Player'
    $zip = Join-Path $Temp 'bailey.zip'
    Get-File "https://github.com/$Repo/archive/refs/heads/$Branch.zip" $zip $null
    Expand-Archive -Path $zip -DestinationPath (Join-Path $Temp 'bailey') -Force
    $src = Get-ChildItem -Path (Join-Path $Temp 'bailey') -Directory | Select-Object -First 1
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    Copy-Item -Path (Join-Path $src.FullName 'config\*') -Destination $ConfigDir -Recurse -Force
    Copy-Item -Path (Join-Path $src.FullName 'assets\bailey-player.ico') -Destination $AppDir -Force
    Copy-Item -Path (Join-Path $src.FullName 'uninstall.ps1') -Destination $AppDir -Force

    # ---- 3. uosc and thumbfast -------------------------------------------------
    Step "Downloading uosc $UoscVersion (on-screen controls)"
    $uoscZip = Join-Path $Temp 'uosc.zip'
    Get-File "https://github.com/tomasklaen/uosc/releases/download/$UoscVersion/uosc.zip" $uoscZip $UoscSha256
    $oldUosc = Join-Path $ConfigDir 'scripts\uosc'
    if (Test-Path $oldUosc) { Remove-Item -Recurse -Force $oldUosc }
    Expand-Archive -Path $uoscZip -DestinationPath $ConfigDir -Force

    Step 'Downloading thumbfast (seek-bar thumbnails)'
    Get-File "https://raw.githubusercontent.com/po5/thumbfast/$ThumbfastRef/thumbfast.lua" (Join-Path $ConfigDir 'scripts\thumbfast.lua') $ThumbfastSha
    $tfConf = Join-Path $ConfigDir 'script-opts\thumbfast.conf'
    $text = [IO.File]::ReadAllText($tfConf) -replace '(?m)^mpv_path=.*$', ('mpv_path=' + $Mpv)
    [IO.File]::WriteAllText($tfConf, $text, $Utf8)

    # ---- 4. Links: yt-dlp (fetches web videos) and ffmpeg (joins video + sound) --
    Step 'Checking yt-dlp and ffmpeg (for playing and downloading links)'
    $YtDlp  = Confirm-Tool 'yt-dlp.exe' 'yt-dlp.yt-dlp' 'Playing and downloading links'
    $FFmpeg = Confirm-Tool 'ffmpeg.exe' 'Gyan.FFmpeg' 'Downloading in best quality'
    $conf = "# Written by setup.ps1 - where Bailey Player finds its helpers.`r`n"
    if ($YtDlp) { $conf += "ytdlp=$YtDlp`r`n" } else { $conf += "ytdlp=yt-dlp`r`n" }
    if ($FFmpeg) { $conf += "ffmpeg=$FFmpeg`r`n" } else { $conf += "ffmpeg=`r`n" }
    $conf += "download_dir=`r`n"
    [IO.File]::WriteAllText((Join-Path $ConfigDir 'script-opts\bailey.conf'), $conf, $Utf8)
    if ($YtDlp) {
        # mpv's own link player uses the same yt-dlp
        [IO.File]::WriteAllText((Join-Path $ConfigDir 'script-opts\ytdl_hook.conf'), "ytdl_path=$YtDlp`r`n", $Utf8)
    }

    # ---- 5. Shortcuts and "Open with" -------------------------------------------
    Step 'Adding shortcuts'
    $icon = Join-Path $AppDir 'bailey-player.ico'
    $configArg = '--config-dir="' + $ConfigDir + '"'
    $shell = New-Object -ComObject WScript.Shell
    $places = @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))
    foreach ($place in $places) {
        $lnk = $shell.CreateShortcut((Join-Path $place 'Bailey Player.lnk'))
        $lnk.TargetPath = $Mpv
        $lnk.Arguments = $configArg
        $lnk.IconLocation = "$icon,0"
        $lnk.Description = 'Bailey Player - flat and VR video'
        $lnk.WorkingDirectory = $AppDir
        $lnk.Save()
    }

    Step 'Adding Bailey Player to "Open with" for videos'
    $progId = 'BaileyPlayer.Video'
    $command = '"' + $Mpv + '" ' + $configArg + ' -- "%1"'
    $classes = 'HKCU:\Software\Classes'
    $exts = @('.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v', '.wmv', '.ts', '.m2ts', '.mts', '.flv', '.mpg', '.mpeg', '.ogv', '.3gp')

    # Our own keys: start clean each time, then fill in.
    if (Test-Path "$classes\$progId") { Remove-Item -Recurse -Force "$classes\$progId" }
    Confirm-Key "$classes\$progId\DefaultIcon"
    Confirm-Key "$classes\$progId\Application"
    Confirm-Key "$classes\$progId\shell\open\command"
    Set-Item -Path "$classes\$progId" -Value 'Video (Bailey Player)'
    Set-Item -Path "$classes\$progId\DefaultIcon" -Value "$icon,0"
    Set-ItemProperty -Path "$classes\$progId\Application" -Name 'ApplicationName' -Value 'Bailey Player'
    Set-ItemProperty -Path "$classes\$progId\Application" -Name 'ApplicationIcon' -Value "$icon,0"
    Set-ItemProperty -Path "$classes\$progId\shell\open" -Name 'FriendlyAppName' -Value 'Bailey Player'
    Set-Item -Path "$classes\$progId\shell\open\command" -Value $command

    $caps = 'HKCU:\Software\BaileyPlayer\Capabilities'
    Confirm-Key "$caps\FileAssociations"
    Set-ItemProperty -Path $caps -Name 'ApplicationName' -Value 'Bailey Player'
    Set-ItemProperty -Path $caps -Name 'ApplicationDescription' -Value 'Flat and VR video player'
    Set-ItemProperty -Path $caps -Name 'ApplicationIcon' -Value "$icon,0"
    foreach ($ext in $exts) {
        Set-ItemProperty -Path "$caps\FileAssociations" -Name $ext -Value $progId
        Confirm-Key "$classes\$ext\OpenWithProgids"
        New-ItemProperty -Force -Path "$classes\$ext\OpenWithProgids" -Name $progId -PropertyType String -Value '' | Out-Null
    }
    Confirm-Key 'HKCU:\Software\RegisteredApplications'
    Set-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' -Name 'Bailey Player' -Value 'Software\BaileyPlayer\Capabilities'

    # Tell Explorer that file associations changed.
    try {
        if (-not ('BaileyPlayer.Shell' -as [type])) {
            Add-Type -Namespace BaileyPlayer -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, IntPtr a, IntPtr b);'
        }
        [BaileyPlayer.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch { Write-Host '(Explorer will pick up the change after a sign-out.)' }

    Step 'Done'
    Write-Host 'Bailey Player is installed. Open it from the Start menu or the Desktop shortcut.'
    Write-Host ''
    Write-Host 'Two optional steps:'
    Write-Host '  * Make it the default for videos: Settings > Apps > Default apps > Bailey Player.'
    Write-Host '  * Super Resolution / HDR: in the NVIDIA App, System > Video, turn on RTX Video Enhancement.'
}
finally {
    Remove-Item -Recurse -Force $Temp -ErrorAction SilentlyContinue
}
