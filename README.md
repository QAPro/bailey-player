# Bailey Player

A video player for Windows that plays normal videos **and** VR videos (VR180, 360°) on an ordinary
screen. You look around a VR video with the mouse. It's [mpv](https://mpv.io) underneath, with a
dark forest-green skin, a quick-settings menu and automatic VR detection.

<img src="assets/bailey-player.png" width="96" alt="Bailey Player icon">

## Install or update

Open **PowerShell** and paste:

```powershell
irm https://raw.githubusercontent.com/QAPro/bailey-player/main/setup.ps1 | iex
```

Then start **Bailey Player** from the Start menu or the Desktop. Running the same line again updates
it and keeps your recent list, remembered VR settings and resume points.

Optional:
- **Make it the default for videos:** Settings → Apps → Default apps → Bailey Player.
  Or right-click a video → Open with → Bailey Player → "Always".
- **Super Resolution / HDR:** in the NVIDIA App, System → Video, switch on RTX Video Enhancement.

## Using it

| To | Do this |
|---|---|
| Open a video | **O**, or the folder button, or drop a file on the window |
| Open a whole folder | **Shift+O** |
| Play a web link (YouTube etc.) | Copy the link, then **Ctrl+V** and Enter. Or pick **Download best quality** to keep a copy in Videos › Bailey Player |
| Quick settings | **Right-click** anywhere |
| Pause | **Space**, or click the picture |
| Full screen | Double-click, or the button at the bottom right |
| Keyboard shortcuts | **?** |

**VR videos** switch into VR mode by themselves (purple **VR** badge, top left).

| In VR mode | |
|---|---|
| Look around | Click once, then move the mouse (click or Esc to stop), or use the arrow keys |
| Zoom | Mouse wheel |
| Reset the view | **R** |
| Switch eye | **E** |
| VR mode on / off | **V** |
| Wrong format? | Right-click → Format. Your choice is remembered for that video. |

**Normal videos:** press **Z** for zoom & pan (wheel zooms, drag or arrows move, 0 resets, Z or Esc ends).

**Quick settings → Picture:** Super Resolution (sharpens low-resolution video on an RTX card),
HDR (RTX Video HDR, needs an HDR monitor) and Smooth motion. Settings are remembered.

Seek-bar thumbnails, resume-where-you-left-off and per-video VR settings are automatic.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\BaileyPlayer\uninstall.ps1"
```

mpv itself stays installed.

## What's inside

| Part | What it does | Licence |
|---|---|---|
| [mpv](https://mpv.io) | The player engine (installed separately, untouched) | GPL/LGPL |
| [uosc](https://github.com/tomasklaen/uosc) 5.13.0 | On-screen controls and menus (downloaded by setup) | LGPL-2.1 |
| [mpv360](https://github.com/kasper93/mpv360) | VR viewing; copy in `config/scripts/mpv360.lua` with small changes marked `[Bailey Player]` | MIT |
| [thumbfast](https://github.com/po5/thumbfast) | Seek-bar thumbnails (downloaded by setup) | MPL-2.0 |
| [Inter](https://rsms.me/inter/) | Font | OFL-1.1 |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) + [ffmpeg](https://ffmpeg.org) | Playing and downloading links (installed by setup with winget if missing) | Unlicense / GPL |
| `config/scripts/bailey.lua` | The glue: start screen, VR detection, quick settings, zoom & pan, RTX features | MIT |

Settings live in `%LOCALAPPDATA%\BaileyPlayer\config` and mpv runs with `--config-dir` pointing
there, so a plain mpv install on the same PC keeps its own settings.
