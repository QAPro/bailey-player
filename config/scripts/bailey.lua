--[[
Bailey Player — the glue between mpv, uosc (on-screen UI) and mpv360 (VR viewer).

What it does:
  * Start screen when nothing is playing: wordmark + Open file / Open folder / Recent.
  * Open file / Open folder with the normal Windows dialogs.
  * Detects VR videos (shape, size and name) and turns VR mode on; flat videos play flat.
  * Remembers VR settings (format, eye, view) per video.
  * Quick settings menu (right-click): VR, picture, playback.
  * Zoom & pan for flat videos (Z): wheel zooms, drag pans, arrows pan, 0 resets.
  * NVIDIA RTX Video Super Resolution and HDR for flat videos; smooth motion.
  * Purple "VR" badge whenever VR mode is on (purple = VR, green = everything else).
]]

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

-------------------------------------------------------------------------------
-- Pure helpers (no mpv calls) — covered by tests/test_bailey.py
-------------------------------------------------------------------------------

local M = {}

M.PROJECTIONS = {
    [0] = {name = 'Equirectangular (360°)', short = '360°', dual = false},
    [1] = {name = 'Dual fisheye', short = 'Fisheye', dual = true},
    [2] = {name = 'Dual half-equirect (VR180)', short = 'VR180', dual = true},
    [3] = {name = 'Half-equirect (mono 180°)', short = '180° mono', dual = false},
    [4] = {name = 'Top-bottom 360° (3D)', short = '360° 3D', dual = true},
    [5] = {name = 'Cylindrical', short = 'Cylindrical', dual = false},
    [6] = {name = 'Cubemap (YouTube 360°)', short = 'Cubemap', dual = false},
    [7] = {name = 'Dual cubemap', short = 'Dual cubemap', dual = true},
}
M.EYES = {[0] = 'Left eye', [1] = 'Right eye', [2] = 'Both eyes (side by side)'}

-- Decide whether a video is VR and which format it is.
-- Returns nil for a flat video, or {input_projection = n} for VR.
function M.detect(name, w, h)
    if not w or not h or w <= 0 or h <= 0 then return nil end
    local n = (name or ''):lower()
    local ratio = w / h
    local function has(pattern) return n:find(pattern) ~= nil end
    local function word(token)
        -- token on its own, separated by non-alphanumerics (so "lr" doesn't match "world")
        return (' ' .. n .. ' '):find('[^%w]' .. token .. '[^%w]') ~= nil
    end

    local wide = ratio > 1.9 and ratio < 2.1     -- 2:1 frames
    local square = ratio > 0.95 and ratio < 1.05  -- 1:1 frames
    local big = w >= 2880

    if has('fisheye') or word('fish') or has('fisheye190') then
        return {input_projection = 1}
    end
    local vr180 = has('vr180') or has('180°') or word('180') or has('_180') or has('180x180')
    local sbs = word('lr') or word('sbs') or has('_lr') or has('3dh') or has('side%-by%-side')
    local tb = word('tb') or word('ou') or has('_tb') or has('3dv') or has('top%-bottom') or has('over%-under')
    local three60 = has('360°') or word('360') or has('_360') or has('360vr') or has('vr360')
    local cubemap = has('eac') and three60

    if cubemap then return {input_projection = 6} end
    if vr180 or (sbs and wide) then
        if square and tb then return nil end -- VR180 top-bottom: not supported by mpv360
        return {input_projection = 2}
    end
    if three60 then
        if square or tb then return {input_projection = 4} end
        return {input_projection = 0}
    end
    if word('vr') or has('_vr') or has('%[vr%]') then
        if wide then return {input_projection = 2} end
        if square then return {input_projection = 4} end
    end
    -- No hint in the name: a big 2:1 frame is almost always VR180 side by side.
    if wide and big then return {input_projection = 2} end
    return nil
end

-- Super Resolution factor: how much to upscale so the video fills the display.
function M.upscale_factor(video_h, display_h)
    if not video_h or not display_h or video_h <= 0 or display_h <= 0 then return 1 end
    if video_h >= display_h * 0.9 then return 1 end
    local f = math.min(4, display_h / video_h)
    return math.floor(f * 100 + 0.5) / 100
end

-- Limits for zoom & pan: how far the picture can be moved at a given zoom (log2 scale).
function M.max_pan(zoom)
    local z = 2 ^ (zoom or 0)
    if z <= 1 then return 0 end
    return (z - 1) / (2 * z)
end

function M.clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Normalise a path into a key for the per-video memory.
function M.key(path)
    if not path or path == '' then return nil end
    return (path:gsub('\\', '/')):lower()
end

-- Add a path to the front of the recent list (no duplicates, at most `limit`).
function M.push_recent(list, entry, limit)
    local out = {entry}
    local k = M.key(entry.path)
    for _, e in ipairs(list or {}) do
        if M.key(e.path) ~= k and #out < (limit or 8) then out[#out + 1] = e end
    end
    return out
end

-- Escape a string for a single-quoted PowerShell literal.
function M.ps_quote(s) return "'" .. tostring(s or ''):gsub("'", "''") .. "'" end

-- Escape text for ASS (on-screen drawing).
function M.ass_escape(s)
    return (tostring(s or ''):gsub('\\', '\\\226\129\160'):gsub('{', '\\{'):gsub('}', '\\}'))
end

-- "#RRGGBB" → ASS "&HBBGGRR&"
function M.ass_color(hex)
    local r, g, b = hex:match('#?(%x%x)(%x%x)(%x%x)')
    return '&H' .. b .. g .. r .. '&'
end

-- A web link, trimmed, or nil. Only http(s) — that is what yt-dlp and mpv stream.
function M.is_url(s)
    if type(s) ~= 'string' then return nil end
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    if s:match('^[Hh][Tt][Tt][Pp][Ss]?://%S+$') then return s end
    return nil
end

-- yt-dlp command line for "download the best copy, tell me where it went".
function M.ytdlp_args(ytdlp, url, folder, ffmpeg)
    local args = {ytdlp or 'yt-dlp',
        '--no-playlist', '--no-mtime', '--encoding', 'utf-8',
        '-f', 'bv*+ba/b',
        '-P', folder,
        '-o', '%(title).150B [%(id)s].%(ext)s',
        '--print', 'after_move:filepath', '--no-simulate'}
    if ffmpeg and ffmpeg ~= '' then
        args[#args + 1] = '--ffmpeg-location'
        args[#args + 1] = ffmpeg
    end
    args[#args + 1] = '--'
    args[#args + 1] = url
    return args
end

function M.format_size(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 ^ 3 then return string.format('%.1f GB', bytes / 1024 ^ 3) end
    return string.format('%d MB', math.floor(bytes / 1024 ^ 2 + 0.5))
end

-- Last non-empty line of program output.
function M.last_line(s)
    local last
    for line in (s or ''):gmatch('[^\r\n]+') do
        if line:match('%S') then last = line end
    end
    return last and (last:gsub('^%s+', ''):gsub('%s+$', '')) or nil
end

-- When loaded as a library by the tests, stop here.
if not mp.get_property then return M end

-------------------------------------------------------------------------------
-- State and saved data
-------------------------------------------------------------------------------

local GREEN, PURPLE, TEXT, MUTED, PANEL =
    M.ass_color('#6CC08F'), M.ass_color('#B39BF7'), M.ass_color('#E6EFE8'), M.ass_color('#9DB3A5'), M.ass_color('#0F1A14')

local data_path = mp.command_native({'expand-path', '~~/bailey-data.json'})
local data = {recent = {}, memory = {}, prefs = {super_res = true, hdr = false, smooth = true}}

local function load_data()
    local f = io.open(data_path, 'r')
    if not f then return end
    local text = f:read('*a')
    f:close()
    local parsed = utils.parse_json(text or '')
    if type(parsed) == 'table' then
        data.recent = type(parsed.recent) == 'table' and parsed.recent or {}
        data.memory = type(parsed.memory) == 'table' and parsed.memory or {}
        if type(parsed.prefs) == 'table' then
            for k, v in pairs(parsed.prefs) do data.prefs[k] = v end
        end
    end
end

local function save_data()
    local f = io.open(data_path, 'w')
    if not f then
        msg.warn('Could not save ' .. data_path)
        return
    end
    -- an empty Lua table would be written as [] — keep memory an object
    local out = {recent = data.recent, memory = next(data.memory) and data.memory or {_ = false}, prefs = data.prefs}
    f:write(utils.format_json(out) or '{}')
    f:close()
end

load_data()
data.memory._ = nil

local file = {path = nil, key = nil, ready = false, has_video = false, w = nil, h = nil}
local vr = {enabled = false}         -- mirror of user-data/mpv360
local zoom_pan = false
local quick_open = false

local function vr_state() return vr end
local function is_dual(p) return M.PROJECTIONS[p] and M.PROJECTIONS[p].dual end

-------------------------------------------------------------------------------
-- Overlays: VR badge and start screen wordmark
-------------------------------------------------------------------------------

local badge = mp.create_osd_overlay('ass-events')
local start = mp.create_osd_overlay('ass-events')
local badge_timer

local function draw_badge()
    if not vr.enabled then
        badge:remove()
        return
    end
    local w, h = mp.get_osd_size()
    if not w or w == 0 then return end
    badge.res_x, badge.res_y = w, h
    local proj = M.PROJECTIONS[vr.input_projection or 2] or M.PROJECTIONS[2]
    local label = proj.short
    if proj.dual then label = label .. '  ·  ' .. (M.EYES[vr.eye or 0] or ''):gsub(' %(side by side%)', '') end
    local fs = 20
    local text_w = (#label + 4) * fs * 0.52
    local x, y, bh = 16, 52, 30
    local bw = text_w + 28
    local ass = {}
    -- panel with purple outline
    ass[#ass + 1] = string.format('{\\an7\\pos(%d,%d)\\bord1.5\\shad0\\1c%s\\1a&H30&\\3c%s\\p1}m 0 0 l %d 0 %d %d 0 %d{\\p0}',
        x, y, PANEL, PURPLE, bw, bw, bh, bh)
    ass[#ass + 1] = string.format('{\\an4\\pos(%d,%d)\\fnInter\\fs%d\\bord0\\shad0\\b1\\1c%s}VR{\\b0\\1c%s}   %s',
        x + 12, y + bh / 2, fs, PURPLE, TEXT, M.ass_escape(label))
    badge.data = table.concat(ass, '\n')
    badge:update()
end

local function flash_badge(seconds)
    draw_badge()
    if badge_timer then badge_timer:kill() end
    if vr.enabled then
        badge_timer = mp.add_timeout(seconds or 3, function()
            if not (vr.mouse_look or quick_open) then badge:remove() end
        end)
    end
end

local function draw_start()
    if not mp.get_property_native('idle-active') then
        start:remove()
        return
    end
    local w, h = mp.get_osd_size()
    if not w or w == 0 then return end
    start.res_x, start.res_y = w, h
    local cx, top = w / 2, math.max(70, h * 0.14)
    local ass = {
        string.format('{\\an5\\pos(%d,%d)\\fnInter\\fs52\\b1\\bord0\\shad0\\1c%s}●{\\1c%s}  Bailey Player', cx, top, GREEN, TEXT),
        string.format('{\\an5\\pos(%d,%d)\\fnInter\\fs22\\bord0\\shad0\\1c%s}Flat or VR — it works out which.', cx, top + 48, MUTED),
        string.format('{\\an2\\pos(%d,%d)\\fnInter\\fs20\\bord0\\shad0\\1c%s}Drop a video anywhere in this window  ·  O to open a file  ·  Ctrl+V for a link  ·  right-click for settings', cx, h - 28, MUTED),
    }
    start.data = table.concat(ass, '\n')
    start:update()
end

-------------------------------------------------------------------------------
-- uosc helpers
-------------------------------------------------------------------------------

-- Send a message to uosc. Right after start-up uosc may not be loaded yet, and
-- script-message-to then fails; retry a few times so nothing silently goes missing.
local function to_uosc(args, tries)
    tries = tries or 6
    if mp.commandv('script-message-to', 'uosc', unpack(args)) then return end
    if tries > 1 then mp.add_timeout(0.5, function() to_uosc(args, tries - 1) end) end
end

local function uosc_menu(command, menu)
    to_uosc({command, utils.format_json(menu)})
end

local function update_vr_button()
    to_uosc({'set-button', 'bailey-vr', utils.format_json({
        icon = 'vrpano',
        active = vr.enabled,
        tooltip = vr.enabled and 'VR mode is on (V)' or 'VR mode (V)',
        command = 'script-message-to bailey vr-toggle',
    })})
end

-------------------------------------------------------------------------------
-- Opening files
-------------------------------------------------------------------------------

local VIDEO_FILTER = 'Videos|*.mp4;*.mkv;*.webm;*.mov;*.avi;*.m4v;*.wmv;*.ts;*.m2ts;*.mts;*.flv;*.mpg;*.mpeg;*.ogv;*.3gp|All files|*.*'

local function initial_dir()
    local path = file.path or (data.recent[1] and data.recent[1].path)
    if not path then return nil end
    local dir = utils.split_path(path)
    return dir
end

local function run_dialog(script, on_result)
    if mp.get_property_native('platform') ~= 'windows' then
        mp.commandv('script-binding', 'uosc/open-file')
        return
    end
    local ps = '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8\n'
        .. 'Add-Type -AssemblyName System.Windows.Forms\n'
        .. '$owner = New-Object System.Windows.Forms.Form -Property @{TopMost = $true; ShowInTaskbar = $false}\n'
        .. script
    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {'powershell', '-NoProfile', '-NonInteractive', '-STA', '-WindowStyle', 'Hidden',
                '-ExecutionPolicy', 'Bypass', '-Command', ps},
    }, function(success, result)
        local out = success and result and result.stdout or ''
        out = out:gsub('^%s+', ''):gsub('%s+$', '')
        if out ~= '' then
            on_result(out)
        elseif success and result and result.status ~= 0 then
            msg.warn('Open dialog failed: ' .. tostring(result.stderr))
            mp.osd_message('Could not open the Windows file dialog — using the built-in browser.')
            mp.commandv('script-binding', 'uosc/open-file')
        end
    end)
end

local function open_file_dialog()
    local dir = initial_dir()
    run_dialog(
        '$d = New-Object System.Windows.Forms.OpenFileDialog\n'
        .. "$d.Title = 'Open a video'\n"
        .. '$d.Filter = ' .. M.ps_quote(VIDEO_FILTER) .. '\n'
        .. (dir and ('$d.InitialDirectory = ' .. M.ps_quote(dir) .. '\n') or '')
        .. 'if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Write($d.FileName) }\n',
        function(path) mp.commandv('loadfile', path, 'replace') end)
end

local function open_folder_dialog()
    local dir = initial_dir()
    run_dialog(
        '$d = New-Object System.Windows.Forms.FolderBrowserDialog\n'
        .. "$d.Description = 'Play every video in a folder'\n"
        .. (dir and ('$d.SelectedPath = ' .. M.ps_quote(dir) .. '\n') or '')
        .. 'if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Write($d.SelectedPath) }\n',
        function(path) mp.commandv('loadfile', path, 'replace') end)
end

local function recent_items()
    local items = {}
    for _, e in ipairs(data.recent) do
        if M.is_url(e.path) or utils.file_info(e.path) then
            local _, name = utils.split_path(e.path)
            items[#items + 1] = {title = e.title or name, hint = e.tag, value = 'load:' .. e.path}
        end
    end
    if #items == 0 then items[1] = {title = 'Nothing yet', muted = true, selectable = false} end
    return items
end

-------------------------------------------------------------------------------
-- VR control (mpv360 does the drawing; we tell it what to do)
-------------------------------------------------------------------------------

local function mpv360(...) mp.commandv('script-message-to', 'mpv360', ...) end

local function vr_apply(settings)
    for _, k in ipairs({'input_projection', 'eye', 'yaw', 'pitch', 'fov', 'fisheye_fov'}) do
        if settings[k] ~= nil then mpv360('set', k, tostring(settings[k])) end
    end
end

local function apply_enhancements() end -- defined below

local function vr_enable(settings)
    if zoom_pan then mp.commandv('script-message-to', 'bailey', 'zoom-pan-off') end
    if settings then vr_apply(settings) end
    mpv360('enable')
end

local function vr_disable() mpv360('disable') end

local function remember()
    if not (file.ready and file.key) then return end
    -- Flat videos are only remembered when they look like VR but were switched off.
    if not vr.enabled and not file.detected_vr then
        data.memory[file.key] = nil
        return
    end
    data.memory[file.key] = {
        vr = vr.enabled,
        input_projection = vr.input_projection,
        eye = vr.eye,
        yaw = vr.yaw,
        pitch = vr.pitch,
        fov = vr.fov,
        fisheye_fov = vr.fisheye_fov,
    }
end

-------------------------------------------------------------------------------
-- Picture: Super Resolution, HDR, smooth motion
-------------------------------------------------------------------------------

local function has_bailey_vf()
    for _, f in ipairs(mp.get_property_native('vf') or {}) do
        if f.label == 'bailey' then return true end
    end
    return false
end

apply_enhancements = function(announce)
    if has_bailey_vf() then mp.command('no-osd vf remove @bailey') end
    mp.set_property_native('target-colorspace-hint', data.prefs.hdr and 'yes' or 'auto')
    if vr.enabled or not file.has_video then return end
    local parts = {}
    if data.prefs.super_res then
        local factor = M.upscale_factor(file.h, mp.get_property_number('display-height', 1080))
        if factor > 1.05 then
            parts[#parts + 1] = 'scale=' .. factor
            parts[#parts + 1] = 'scaling-mode=nvidia'
        end
    end
    if data.prefs.hdr then parts[#parts + 1] = 'nvidia-true-hdr' end
    if #parts == 0 then return end
    local ok = mp.commandv('no-osd', 'vf', 'add', '@bailey:d3d11vpp=' .. table.concat(parts, ':'))
    if not ok then
        msg.warn('d3d11vpp filter failed')
        if announce then mp.osd_message('Super Resolution / HDR not available for this video') end
    elseif announce then
        mp.osd_message('Picture: ' .. table.concat(parts, ' '):gsub('scaling%-mode=nvidia', 'RTX'), 2)
    end
end

local function set_smooth(on)
    data.prefs.smooth = on
    mp.set_property_native('interpolation', on)
end

-------------------------------------------------------------------------------
-- Zoom & pan (flat videos)
-------------------------------------------------------------------------------

local drag = nil

local function clamp_pan()
    local limit = M.max_pan(mp.get_property_number('video-zoom', 0))
    mp.set_property_number('video-pan-x', M.clamp(mp.get_property_number('video-pan-x', 0), -limit, limit))
    mp.set_property_number('video-pan-y', M.clamp(mp.get_property_number('video-pan-y', 0), -limit, limit))
end

local function zoom_by(step)
    mp.set_property_number('video-zoom', M.clamp(mp.get_property_number('video-zoom', 0) + step, 0, 3))
    clamp_pan()
end

local function pan_by(dx, dy)
    mp.set_property_number('video-pan-x', mp.get_property_number('video-pan-x', 0) + dx)
    mp.set_property_number('video-pan-y', mp.get_property_number('video-pan-y', 0) + dy)
    clamp_pan()
end

local function on_drag_move(_, pos)
    if not drag or not pos then return end
    local w, h = mp.get_osd_size()
    local z = 2 ^ mp.get_property_number('video-zoom', 0)
    pan_by((pos.x - drag.x) / (w * z), (pos.y - drag.y) / (h * z))
    drag = {x = pos.x, y = pos.y}
end

local function zoom_pan_off(quiet)
    if not zoom_pan then return end
    zoom_pan = false
    for _, name in ipairs({'zp-in', 'zp-out', 'zp-left', 'zp-right', 'zp-up', 'zp-down', 'zp-reset', 'zp-drag', 'zp-esc'}) do
        mp.remove_key_binding(name)
    end
    mp.unobserve_property(on_drag_move)
    drag = nil
    mp.set_property_number('video-zoom', 0)
    mp.set_property_number('video-pan-x', 0)
    mp.set_property_number('video-pan-y', 0)
    if not quiet then mp.osd_message('Zoom & pan off', 1.5) end
end

local function zoom_pan_on()
    if vr.enabled then
        mp.osd_message('In VR mode, zoom with the mouse wheel and click to look around', 3)
        return
    end
    if zoom_pan then return end
    zoom_pan = true
    local opts = {repeatable = true}
    mp.add_forced_key_binding('WHEEL_UP', 'zp-in', function() zoom_by(0.1) end, opts)
    mp.add_forced_key_binding('WHEEL_DOWN', 'zp-out', function() zoom_by(-0.1) end, opts)
    mp.add_forced_key_binding('LEFT', 'zp-left', function() pan_by(0.02, 0) end, opts)
    mp.add_forced_key_binding('RIGHT', 'zp-right', function() pan_by(-0.02, 0) end, opts)
    mp.add_forced_key_binding('UP', 'zp-up', function() pan_by(0, 0.02) end, opts)
    mp.add_forced_key_binding('DOWN', 'zp-down', function() pan_by(0, -0.02) end, opts)
    mp.add_forced_key_binding('0', 'zp-reset', function()
        mp.set_property_number('video-zoom', 0)
        mp.set_property_number('video-pan-x', 0)
        mp.set_property_number('video-pan-y', 0)
    end)
    mp.add_forced_key_binding('ESC', 'zp-esc', function() zoom_pan_off() end)
    mp.add_forced_key_binding('MBTN_LEFT', 'zp-drag', function(e)
        if e.event == 'down' then
            drag = mp.get_property_native('mouse-pos')
            mp.observe_property('mouse-pos', 'native', on_drag_move)
        elseif e.event == 'up' then
            mp.unobserve_property(on_drag_move)
            drag = nil
        end
    end, {complex = true})
    zoom_by(0.5)
    mp.osd_message('Zoom & pan: wheel zooms, drag or arrows move, 0 resets, Z or Esc ends', 4)
end

-------------------------------------------------------------------------------
-- Quick settings menu (right-click)
-------------------------------------------------------------------------------

local function onoff(v) return v and 'On' or 'Off' end

local function build_quick()
    local items = {}
    local function add(item) items[#items + 1] = item end

    add({title = 'VR mode', hint = onoff(vr.enabled) .. '  ·  V', value = 'vr-toggle', active = vr.enabled, keep_open = true})
    if vr.enabled then
        local p = vr.input_projection or 2
        local formats = {}
        for i = 0, 7 do
            formats[#formats + 1] = {title = M.PROJECTIONS[i].name, value = 'proj:' .. i, active = i == p, keep_open = true}
        end
        add({title = 'Format', hint = M.PROJECTIONS[p].short, items = formats})
        if is_dual(p) then
            local eyes = {}
            for i = 0, 2 do eyes[#eyes + 1] = {title = M.EYES[i], value = 'eye:' .. i, active = i == (vr.eye or 0), keep_open = true} end
            add({title = 'Eye', hint = (M.EYES[vr.eye or 0] or ''):gsub(' %(side by side%)', ''), items = eyes})
        end
        if p == 1 then
            add({title = 'Fisheye angle', hint = string.format('%d°', math.floor(math.deg(vr.fisheye_fov or math.pi) + 0.5)), items = {
                {title = 'Wider', value = 'fisheye:+', keep_open = true},
                {title = 'Narrower', value = 'fisheye:-', keep_open = true},
            }})
        end
        add({title = 'Look around', hint = 'Click  ·  arrow keys', value = 'mouse-look'})
        add({title = 'Zoom in', hint = 'Wheel up', value = 'vr-zoom:-', keep_open = true})
        add({title = 'Zoom out', hint = 'Wheel down', value = 'vr-zoom:+', keep_open = true})
        add({title = 'Reset view', hint = 'R', value = 'reset-view', keep_open = true, separator = true})
    else
        add({title = 'Zoom & pan', hint = onoff(zoom_pan) .. '  ·  Z', value = 'zoom-pan', active = zoom_pan, separator = true})
    end

    add({title = 'Picture', items = {
        {title = 'Super Resolution (RTX)', hint = onoff(data.prefs.super_res), value = 'toggle-super-res', active = data.prefs.super_res, keep_open = true},
        {title = 'HDR (RTX Video HDR)', hint = onoff(data.prefs.hdr), value = 'toggle-hdr', active = data.prefs.hdr, keep_open = true},
        {title = 'Smooth motion', hint = onoff(data.prefs.smooth), value = 'toggle-smooth', active = data.prefs.smooth, keep_open = true},
    }})

    local speed = mp.get_property_number('speed', 1)
    local speeds = {}
    for _, s in ipairs({0.5, 0.75, 1, 1.25, 1.5, 2}) do
        speeds[#speeds + 1] = {title = (s == 1 and 'Normal' or (s .. '×')), value = 'speed:' .. s, active = math.abs(s - speed) < 0.01, keep_open = true}
    end
    add({title = 'Speed', hint = (math.abs(speed - 1) < 0.01) and 'Normal' or string.format('%g×', speed), items = speeds})
    add({title = 'Subtitles', value = 'uosc:subtitles'})
    add({title = 'Audio track', value = 'uosc:audio', separator = true})
    add({title = 'Open file…', hint = 'O', value = 'open-file'})
    add({title = 'Open folder…', hint = 'Shift+O', value = 'open-folder'})
    add({title = 'Recent', items = recent_items(), separator = true})
    add({title = 'Keyboard shortcuts', hint = '?', value = 'uosc:keybinds'})

    return {
        type = 'bailey-quick',
        title = 'Quick settings',
        items = items,
        callback = {'bailey', 'menu-event'},
        on_close = {'script-message-to', 'bailey', 'menu-closed', 'bailey-quick'},
    }
end

local function build_start()
    local items = {
        {title = 'Open file…', hint = 'O', value = 'open-file'},
        {title = 'Open folder…', hint = 'Shift+O', value = 'open-folder'},
        {title = 'Open a link…', hint = 'Ctrl+V', value = 'open-link', separator = true},
    }
    for _, it in ipairs(recent_items()) do items[#items + 1] = it end
    return {
        type = 'bailey-start',
        title = 'Open a video',
        items = items,
        on_paste = {'script-message-to', 'bailey', 'link-pasted'},
        callback = {'bailey', 'menu-event'},
        on_close = {'script-message-to', 'bailey', 'menu-closed', 'bailey-start'},
    }
end

local function refresh_quick()
    if quick_open then uosc_menu('update-menu', build_quick()) end
end

local function open_quick()
    if quick_open then
        mp.commandv('script-message-to', 'uosc', 'close-menu', 'bailey-quick')
        return
    end
    quick_open = true
    uosc_menu('open-menu', build_quick())
end

local function open_start()
    if mp.get_property_native('idle-active') then uosc_menu('open-menu', build_start()) end
end

local function close_menus()
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'bailey-quick')
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'bailey-start')
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'bailey-link')
end

-------------------------------------------------------------------------------
-- Links: play straight from the web, or download the best copy first
-------------------------------------------------------------------------------

local opts = {ytdlp = 'yt-dlp', ffmpeg = '', download_dir = ''}
require('mp.options').read_options(opts, 'bailey')

local function download_dir()
    if opts.download_dir ~= '' then return opts.download_dir end
    local home = os.getenv('USERPROFILE') or os.getenv('HOME') or '.'
    return utils.join_path(utils.join_path(home, 'Videos'), 'Bailey Player')
end

local function link_items(url)
    if not url then
        return {
            {title = 'Paste a link (Ctrl+V), then press Enter', muted = true, selectable = false},
            {title = 'YouTube and most video sites work', muted = true, selectable = false},
        }
    end
    return {
        {title = 'Play now', hint = 'Enter', value = 'link-play:' .. url},
        {title = 'Download best quality, then play', hint = 'Videos › Bailey Player', value = 'link-download:' .. url},
    }
end

local function build_link(url, note)
    local items = link_items(url)
    if note then table.insert(items, 1, {title = note, muted = true, selectable = false}) end
    return {
        type = 'bailey-link',
        title = 'Open a link',
        search_style = 'palette',
        search_debounce = 'submit',
        search_suggestion = url,
        on_search = {'script-message-to', 'bailey', 'link-entered'},
        footnote = 'Enter plays it now · Download keeps a copy for offline and full quality',
        items = items,
        callback = {'bailey', 'menu-event'},
        on_close = {'script-message-to', 'bailey', 'menu-closed', 'bailey-link'},
    }
end

local function open_link()
    local clip = M.is_url(mp.get_property('clipboard/text'))
    uosc_menu('open-menu', build_link(clip))
end

local link_loading = false -- don't bring the start menu back while a link opens

local function link_play(url)
    link_loading = true
    close_menus()
    mp.osd_message('Opening link…', 3)
    mp.commandv('loadfile', url, 'replace')
end

local download -- the running download, if any
local dl_osd = mp.create_osd_overlay('ass-events')

local function draw_download(text)
    if not text then
        dl_osd:remove()
        return
    end
    local w, h = mp.get_osd_size()
    if not w or w == 0 then return end
    dl_osd.res_x, dl_osd.res_y = w, h
    local fs, bh = 20, 30
    local bw = #text * fs * 0.5 + 28
    local x, y = w - 16 - bw, 52
    dl_osd.data = string.format('{\\an7\\pos(%d,%d)\\bord1.5\\shad0\\1c%s\\1a&H30&\\3c%s\\p1}m 0 0 l %d 0 %d %d 0 %d{\\p0}',
            x, y, PANEL, GREEN, bw, bw, bh, bh)
        .. '\n' .. string.format('{\\an4\\pos(%d,%d)\\fnInter\\fs%d\\bord0\\shad0\\1c%s}%s',
            x + 14, y + bh / 2, fs, TEXT, M.ass_escape(text))
    dl_osd:update()
end

local function partial_bytes(folder)
    local total = 0
    for _, name in ipairs(utils.readdir(folder, 'files') or {}) do
        if name:match('%.part$') then
            local info = utils.file_info(utils.join_path(folder, name))
            if info and info.size then total = total + info.size end
        end
    end
    return total
end

local function start_download(url)
    close_menus()
    if download then
        mp.osd_message('A download is already running — one at a time.', 3)
        return
    end
    local folder = download_dir()
    download = {url = url}
    draw_download('Downloading…')
    download.timer = mp.add_periodic_timer(1, function()
        local bytes = partial_bytes(folder)
        draw_download(bytes > 0 and ('Downloading…  ' .. M.format_size(bytes)) or 'Downloading…')
    end)
    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = M.ytdlp_args(opts.ytdlp, url, folder, opts.ffmpeg),
    }, function(success, result)
        if download and download.timer then download.timer:kill() end
        download = nil
        draw_download(nil)
        result = result or {}
        local path = success and result.status == 0 and M.last_line(result.stdout)
        if path then
            local _, name = utils.split_path(path)
            if mp.get_property_native('idle-active') then
                mp.commandv('loadfile', path, 'replace')
            else
                data.recent = M.push_recent(data.recent, {path = path, title = name}, 8)
                save_data()
                mp.osd_message('Downloaded: ' .. name .. '  — it is in Recent.', 5)
            end
        elseif result.error_string == 'init' or (result.status or 0) < 0 then
            mp.osd_message('Download needs yt-dlp. Run the Bailey Player installer again to add it.', 8)
        else
            msg.warn('yt-dlp failed: ' .. tostring(result.stderr))
            mp.osd_message('Download failed: ' .. (M.last_line(result.stderr) or 'unknown error'), 8)
        end
    end)
end

mp.register_script_message('link-pasted', function(text)
    uosc_menu('open-menu', build_link(M.is_url(text)))
end)

mp.register_script_message('link-entered', function(query)
    local url = M.is_url(query)
    if url then
        link_play(url)
    else
        uosc_menu('update-menu', build_link(nil, 'That is not a link — it should start with http'))
    end
end)

local actions -- defined below

mp.register_script_message('menu-event', function(json)
    local event = utils.parse_json(json)
    if type(event) ~= 'table' or event.type ~= 'activate' or type(event.value) ~= 'string' then return end
    local value = event.value
    local keep = event.keep_open
    if not keep then close_menus() end
    local name, arg = value:match('^([%w%-]+):(.*)$')
    if not name then name = value end
    local fn = actions[name]
    if fn then fn(arg) else msg.warn('Unknown menu action ' .. value) end
    if keep then mp.add_timeout(0.05, refresh_quick) end
end)

mp.register_script_message('menu-closed', function(menu_type)
    if menu_type == 'bailey-quick' then quick_open = false end
    if menu_type == 'bailey-link' then
        mp.add_timeout(0.2, function() if not link_loading then open_start() end end)
    end
end)

actions = {
    ['vr-toggle'] = function()
        if not file.has_video then
            mp.osd_message('Open a video first')
            return
        end
        if vr.enabled then vr_disable() else vr_enable() end
    end,
    ['proj'] = function(arg) mpv360('set', 'input_projection', arg) end,
    ['eye'] = function(arg) mpv360('set', 'eye', arg) end,
    ['fisheye'] = function(arg)
        local step = math.rad(10) * (arg == '+' and 1 or -1)
        mpv360('set', 'fisheye_fov', tostring((vr.fisheye_fov or math.pi) + step))
    end,
    ['vr-zoom'] = function(arg)
        local step = 0.1 * (arg == '+' and 1 or -1)
        mpv360('set', 'fov', tostring(M.clamp((vr.fov or 2.1) + step, 0.3, 3.0)))
    end,
    ['mouse-look'] = function() mpv360('toggle-mouse-look') end,
    ['reset-view'] = function() mpv360('reset-view') end,
    ['zoom-pan'] = function() if zoom_pan then zoom_pan_off() else zoom_pan_on() end end,
    ['toggle-super-res'] = function()
        data.prefs.super_res = not data.prefs.super_res
        save_data()
        apply_enhancements(true)
    end,
    ['toggle-hdr'] = function()
        data.prefs.hdr = not data.prefs.hdr
        save_data()
        apply_enhancements(true)
    end,
    ['toggle-smooth'] = function()
        set_smooth(not data.prefs.smooth)
        save_data()
        mp.osd_message('Smooth motion ' .. onoff(data.prefs.smooth):lower(), 1.5)
    end,
    ['speed'] = function(arg) mp.set_property_number('speed', tonumber(arg) or 1) end,
    ['uosc'] = function(arg) mp.commandv('script-binding', 'uosc/' .. arg) end,
    ['open-file'] = open_file_dialog,
    ['open-folder'] = open_folder_dialog,
    ['load'] = function(path) mp.commandv('loadfile', path, 'replace') end,
    ['open-link'] = open_link,
    ['link-play'] = link_play,
    ['link-download'] = start_download,
}

-------------------------------------------------------------------------------
-- File lifecycle
-------------------------------------------------------------------------------

local function decide_vr()
    if file.ready then return end
    file.ready = true
    local mem = file.key and data.memory[file.key]
    local _, name = utils.split_path(file.path or '')
    if M.is_url(file.path) then name = mp.get_property('media-title') or name end
    file.detected_vr = file.has_video and M.detect(name, file.w, file.h) ~= nil
    local tag = 'Flat'
    if not file.has_video then
        vr_disable()
    elseif mem then
        if mem.vr then
            vr_enable(mem)
            tag = 'VR'
        else
            vr_disable()
        end
    else
        local found = M.detect(name, file.w, file.h)
        if found then
            vr_enable({input_projection = found.input_projection, eye = 0, yaw = 0, pitch = 0, fov = 2.1})
            tag = 'VR'
        else
            vr_disable()
        end
    end
    if file.path and (M.is_url(file.path) or not file.path:find('^%a+://')) then
        data.recent = M.push_recent(data.recent, {path = file.path, title = mp.get_property('media-title'), tag = tag}, 8)
        save_data()
    end
    -- enhancements wait for VR state to settle (mpv360 answers asynchronously)
    mp.add_timeout(0.2, function() apply_enhancements(false) end)
end

mp.register_event('start-file', function()
    remember()
    link_loading = false
    file = {path = mp.get_property('path'), ready = false, has_video = false}
    file.key = M.key(file.path)
    zoom_pan_off(true)
    close_menus()
end)

mp.observe_property('video-params', 'native', function(_, p)
    if not p or not p.w or file.ready then return end
    file.has_video = true
    file.w, file.h = p.w, p.h
    decide_vr()
end)

mp.register_event('file-loaded', function()
    -- audio-only files never get video-params
    if not mp.get_property_native('vid') then
        file.has_video = false
        decide_vr()
    end
end)

mp.register_event('end-file', function()
    remember()
    save_data()
end)

mp.register_event('shutdown', function()
    remember()
    save_data()
end)

-- While looking around in VR the mouse never stops, so the controls would sit
-- over the picture. Hide them for that mode; they come back when it ends.
local ui_hidden = false
local function hide_controls(hide)
    if hide == ui_hidden then return end
    ui_hidden = hide
    to_uosc({'disable-elements', 'bailey', hide and 'timeline,controls,volume,top_bar' or ''})
end

mp.observe_property('user-data/mpv360', 'native', function(_, state)
    if type(state) ~= 'table' then return end
    local was = vr.enabled
    vr = state
    hide_controls(vr.enabled and vr.mouse_look or false)
    if was ~= vr.enabled then
        update_vr_button()
        flash_badge(4)
        if file.ready then apply_enhancements(false) end
    elseif vr.mouse_look then
        draw_badge()
    end
    if file.ready then remember() end
    refresh_quick()
end)

mp.observe_property('idle-active', 'bool', function(_, idle)
    draw_start()
    if idle then
        if vr.enabled then vr_disable() end
        mp.add_timeout(0.3, open_start)
    else
        start:remove()
    end
end)

mp.observe_property('osd-dimensions', 'native', function()
    draw_start()
    if vr.enabled and badge_timer and badge_timer:is_enabled() then draw_badge() end
end)

mp.observe_property('mouse-pos', 'native', function(_, pos)
    if vr.enabled and pos and pos.hover then flash_badge(2) end
end)

-------------------------------------------------------------------------------
-- Messages bound in input.conf
-------------------------------------------------------------------------------

mp.register_script_message('open-file', open_file_dialog)
mp.register_script_message('open-link', open_link)

mp.register_event('end-file', function(event)
    if event and event.reason == 'error' and M.is_url(file.path) then
        mp.osd_message('Could not play that link. Try "Download best quality" instead.', 6)
    end
end)
mp.register_script_message('open-folder', open_folder_dialog)
mp.register_script_message('quick-settings', open_quick)
mp.register_script_message('vr-toggle', actions['vr-toggle'])
mp.register_script_message('zoom-pan', actions['zoom-pan'])
mp.register_script_message('zoom-pan-off', function() zoom_pan_off(true) end)
mp.register_script_message('toggle-super-res', actions['toggle-super-res'])
mp.register_script_message('toggle-hdr', actions['toggle-hdr'])
mp.register_script_message('toggle-smooth', actions['toggle-smooth'])
mp.register_script_message('recent', function()
    uosc_menu('open-menu', {type = 'bailey-recent', title = 'Recent', items = recent_items(), callback = {'bailey', 'menu-event'}})
end)

-- Startup
set_smooth(data.prefs.smooth ~= false)
update_vr_button()

return M
