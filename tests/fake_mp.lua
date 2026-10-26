-- A small fake of mpv's Lua API, enough to run bailey.lua and mpv360.lua outside mpv.
-- It records commands so tests can check what the scripts asked mpv to do.

local fake = {
    props = {
        ['platform'] = 'windows',
        ['idle-active'] = false,
        ['vf'] = {},
        ['speed'] = 1,
        ['display-height'] = 2160,
        ['video-zoom'] = 0,
        ['video-pan-x'] = 0,
        ['video-pan-y'] = 0,
        ['vid'] = 1,
        ['glsl-shaders'] = {},
        ['keepaspect'] = true,
        ['mouse-pos'] = {x = 0, y = 0, hover = true},
    },
    commands = {},
    events = {},
    observers = {},
    messages = {},
    bindings = {},
    timers = {},
    osd = {},
}

local function record(...)
    local args = {...}
    fake.commands[#fake.commands + 1] = args
    -- Emulate the bits of mpv the scripts rely on.
    if args[1] == 'script-message-to' then
        local handler = fake.messages[args[2] .. '/' .. args[3]]
        if handler then
            local rest = {}
            for i = 4, #args do rest[#rest + 1] = args[i] end
            handler(unpack(rest))
        end
    end
    if args[1] == 'no-osd' and args[2] == 'change-list' and args[3] == 'glsl-shaders' then
        local list = fake.props['glsl-shaders']
        if args[4] == 'append' then list[#list + 1] = args[5] end
        if args[4] == 'remove' then
            for i = #list, 1, -1 do if list[i] == args[5] then table.remove(list, i) end end
        end
    end
    if args[1] == 'no-osd' and args[2] == 'vf' and args[3] == 'add' then
        local spec = args[4]
        fake.props['vf'] = {{label = spec:match('^@([^:]+)'), name = spec}}
    end
    return true
end

local current_script = 'test'

local mp = {}
function mp.get_property(name, def) local v = fake.props[name]; if v == nil then return def end; return tostring(v) end
function mp.get_property_native(name, def) local v = fake.props[name]; if v == nil then return def end; return v end
function mp.get_property_number(name, def) local v = tonumber(fake.props[name]); if v == nil then return def end; return v end
function mp.get_property_bool(name, def) local v = fake.props[name]; if v == nil then return def end; return v and true or false end
local function set(name, value)
    fake.props[name] = value
    for _, o in ipairs(fake.observers) do
        if o.name == name then o.fn(name, value) end
    end
    return true
end
mp.set_property = set
mp.set_property_native = set
mp.set_property_number = set
mp.set_property_bool = set
function mp.commandv(...) return record(...) end
function mp.command(s) return record(s) end
function mp.command_native(t)
    if t[1] == 'expand-path' then return fake.data_dir .. '/' .. t[2]:gsub('^~~/', '') end
    return nil
end
function mp.command_native_async(t, cb) record('async', t.name) end
function mp.register_event(name, fn) fake.events[name] = fake.events[name] or {}; table.insert(fake.events[name], fn) end
function mp.observe_property(name, kind, fn) table.insert(fake.observers, {name = name, fn = fn}) end
function mp.unobserve_property(fn)
    for i = #fake.observers, 1, -1 do if fake.observers[i].fn == fn then table.remove(fake.observers, i) end end
end
function mp.register_script_message(name, fn) fake.messages[current_script .. '/' .. name] = fn end
function mp.add_key_binding(key, name, fn) fake.bindings[name or key] = fn end
mp.add_forced_key_binding = mp.add_key_binding
function mp.remove_key_binding(name) fake.bindings[name] = nil end
function mp.add_timeout(sec, fn)
    local t = {fn = fn, enabled = true}
    function t:kill() self.enabled = false end
    function t:is_enabled() return self.enabled end
    table.insert(fake.timers, t)
    return t
end
function mp.add_periodic_timer(sec, fn) return mp.add_timeout(sec, fn) end
function mp.get_osd_size() return 1920, 1080 end
function mp.osd_message(text) fake.osd[#fake.osd + 1] = text end
function mp.create_osd_overlay(kind)
    local o = {data = '', visible = false}
    function o:update() self.visible = true end
    function o:remove() self.visible = false end
    return o
end
function mp.get_script_name() return current_script end
function mp.get_script_directory() return '.' end

local utils = {}
function utils.split_path(p)
    local dir, name = p:match('^(.*[/\\])([^/\\]*)$')
    if not dir then return '.', p end
    return dir, name
end
function utils.file_info(p) return {is_file = true} end

local msg = {warn = function() end, error = function() end, info = function() end, debug = function() end, verbose = function() end}

local options = {}
function options.read_options(t, name, on_update) end

function fake.run_timers()
    local pending = fake.timers
    fake.timers = {}
    for _, t in ipairs(pending) do if t.enabled then t.enabled = false; t.fn() end end
end

function fake.emit(event)
    for _, fn in ipairs(fake.events[event] or {}) do fn({event = event}) end
end

function fake.set(name, value) return set(name, value) end

function fake.load_script(name, path, json)
    current_script = name
    package.loaded['mp'] = mp
    package.loaded['mp.utils'] = utils
    package.loaded['mp.msg'] = msg
    package.loaded['mp.options'] = options
    utils.parse_json = json.parse
    utils.format_json = json.format
    local chunk = assert(loadfile(path))
    return chunk()
end

fake.mp = mp
return fake
