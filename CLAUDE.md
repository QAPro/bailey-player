# Bailey Player — notes for Claude

Phil's personal Windows video player for flat and VR video (public repo `QAPro/bailey-player`).
A personal tool, not a venture. Project context and history: `~/ExecAssist/context/vr-viewer/README.md`.

## Shape

- **Engine:** mpv (shinchiro winget build on Phil's PC, BEH-5080tow1, RTX 5080). Not bundled.
- **UI:** uosc 5.13.0, downloaded by `setup.ps1` (pinned + SHA-256). Theme in `config/script-opts/uosc.conf`.
- **VR:** `config/scripts/mpv360.lua` + `config/shaders/mpv360.glsl` — a copy of kasper93/mpv360 at
  `cc5d9dd`, with additions marked `[Bailey Player]`: publishes state to `user-data/mpv360`, accepts
  `script-message-to mpv360 enable|disable|set <key> <n>|reset-view|toggle-mouse-look`, quieter messages.
- **Glue:** `config/scripts/bailey.lua`. Pure helpers (detection etc.) at the top, testable without mpv.
- **Install:** `setup.ps1` (one-liner `irm … | iex`) → `%LOCALAPPDATA%\BaileyPlayer\config`, mpv run
  with `--config-dir`. Shortcuts + HKCU "Open with" ProgID `BaileyPlayer.Video`.

## Design (agreed 2026-10-26)

"Forest Night": deep green-black `#0E1612`/`#0F1A14`, forest green `#6CC08F`, text `#E6EFE8`,
muted `#9DB3A5`, font Inter. **Purple `#B39BF7` means VR** and appears only on VR things (the badge).
Mockups: https://claude.ai/artifact/VtFYmeXuZKLJf1DGP3btkN (direction A + C's purple-for-VR).

## Rules

- **Tests:** `PYTHONPATH=<dir with lupa> python3 -m unittest discover -s tests`. LuaJIT 2.1 via `lupa`
  (`pip install --target <dir> lupa`), with `tests/fake_mp.lua` faking mpv. Run before every push.
- **Never `New-Item -Force` on a registry key we don't own** — it empties the key. Use `Confirm-Key`.
- **Keep `setup.ps1` ASCII-only** (Windows PowerShell 5.1 reads BOM-less files as ANSI).
- **Real-mpv behaviour is only checked on Phil's PC.** Say so when reporting; don't claim it works there.
- Feedback from Phil → GitHub issues in this repo.
- Commit author: phil.bailey001@gmail.com.
