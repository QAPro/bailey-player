"""Tests for bailey.lua (and our mpv360 additions), run outside mpv.

Uses LuaJIT 2.1 through `lupa` — the same Lua engine mpv uses on Windows.
Run:  PYTHONPATH=<folder with lupa> python3 -m unittest discover -s tests
"""

import json
import os
import tempfile
import unittest

from lupa import luajit21 as lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BAILEY = os.path.join(ROOT, 'config', 'scripts', 'bailey.lua')
MPV360 = os.path.join(ROOT, 'config', 'scripts', 'mpv360.lua')
FAKE = os.path.join(ROOT, 'tests', 'fake_mp.lua')


def to_py(lua, value):
    """Lua table → Python list/dict (arrays become lists)."""
    if lupa.lua_type(value) != 'table':
        return value
    keys = list(value.keys())
    if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
        return [to_py(lua, value[k]) for k in sorted(keys)]
    return {k: to_py(lua, value[k]) for k in keys}


def to_lua(lua, value):
    if isinstance(value, dict):
        return lua.table_from({k: to_lua(lua, v) for k, v in value.items()})
    if isinstance(value, list):
        return lua.table_from([to_lua(lua, v) for v in value])
    return value


class Detect(unittest.TestCase):
    """The pure helpers, loaded as a library (no mpv)."""

    @classmethod
    def setUpClass(cls):
        cls.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        cls.lua.execute("package.loaded['mp'] = {}; package.loaded['mp.utils'] = {}; package.loaded['mp.msg'] = {}")
        cls.M = cls.lua.eval(f"dofile({json.dumps(BAILEY)})")

    def detect(self, name, w, h):
        r = self.M.detect(name, w, h)
        return None if r is None else r['input_projection']

    def test_youtube_vr180_download_is_vr180(self):
        name = '3D Epic VR Roller Coaster - Fenix 3D Front Row POV - Wing Coaster Toverland VR180 #rollercoaster [U3uGNp3aU2w].webm'
        self.assertEqual(self.detect(name, 5760, 2880), 2)

    def test_plain_flat_video_is_flat(self):
        self.assertIsNone(self.detect('Holiday 2025.mp4', 1920, 1080))
        self.assertIsNone(self.detect('Holiday 2025.mp4', 3840, 2160))

    def test_big_two_to_one_without_hints_is_vr180(self):
        self.assertEqual(self.detect('clip.mp4', 7680, 3840), 2)

    def test_small_two_to_one_without_hints_is_flat(self):
        # e.g. a 2:1 "univisium" film at normal resolution
        self.assertIsNone(self.detect('movie.mkv', 1920, 960))

    def test_sbs_tag(self):
        self.assertEqual(self.detect('scene_LR_180.mp4', 5760, 2880), 2)
        self.assertEqual(self.detect('scene SBS.mp4', 3840, 1920), 2)

    def test_lr_inside_a_word_does_not_count(self):
        self.assertIsNone(self.detect('world tour.mp4', 1920, 1080))

    def test_mono_360(self):
        self.assertEqual(self.detect('Alps 360.mp4', 3840, 1920), 0)

    def test_top_bottom_360(self):
        self.assertEqual(self.detect('Alps 360 TB.mp4', 4096, 4096), 4)

    def test_fisheye(self):
        self.assertEqual(self.detect('trip_FISHEYE190.mp4', 8000, 4000), 1)

    def test_bad_sizes(self):
        self.assertIsNone(self.detect('x VR180.mp4', 0, 0))

    def test_upscale_factor(self):
        self.assertEqual(self.M.upscale_factor(1080, 2160), 2)
        self.assertEqual(self.M.upscale_factor(720, 2160), 3)
        self.assertEqual(self.M.upscale_factor(480, 2160), 4)  # capped
        self.assertEqual(self.M.upscale_factor(2160, 2160), 1)
        self.assertEqual(self.M.upscale_factor(2000, 2160), 1)  # close enough: skip

    def test_max_pan(self):
        self.assertEqual(self.M.max_pan(0), 0)
        self.assertAlmostEqual(self.M.max_pan(1), 0.25)

    def test_push_recent_dedupes_and_caps(self):
        lua = self.lua
        lst = lua.table_from([lua.table_from({'path': f'C:\\v\\{i}.mp4'}) for i in range(8)])
        out = self.M.push_recent(lst, lua.table_from({'path': 'c:/v/3.mp4'}), 8)
        paths = [out[i]['path'] for i in range(1, len(out) + 1)]
        self.assertEqual(len(paths), 8)
        self.assertEqual(paths[0], 'c:/v/3.mp4')
        self.assertNotIn('C:\\v\\3.mp4', paths)

    def test_ps_quote(self):
        self.assertEqual(self.M.ps_quote("C:\\Phil's videos"), "'C:\\Phil''s videos'")

    def test_ass_color(self):
        self.assertEqual(self.M.ass_color('#B39BF7'), '&HF79BB3&')


class Player(unittest.TestCase):
    """Runs mpv360.lua + bailey.lua together against a fake mpv."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        lua = self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        self.fake = lua.eval(f"dofile({json.dumps(FAKE)})")
        self.fake.data_dir = self.tmp.name
        jsonlib = lua.table_from({
            'parse': lambda s: to_lua(lua, json.loads(s)) if s else None,
            'format': lambda t: json.dumps(to_py(lua, t)),
        })
        self.fake.load_script('mpv360', MPV360, jsonlib)
        self.fake.load_script('bailey', BAILEY, jsonlib)
        self.fake.run_timers()

    def tearDown(self):
        self.tmp.cleanup()

    # helpers
    def open(self, path, w, h):
        self.fake.emit('end-file')
        self.fake.props['path'] = path
        self.fake.props['media-title'] = os.path.basename(path.replace('\\', '/'))
        self.fake.emit('start-file')
        self.fake.set('video-params', self.lua.table_from({'w': w, 'h': h}))
        self.fake.emit('file-loaded')
        self.fake.run_timers()

    def state(self):
        return to_py(self.lua, self.fake.props['user-data/mpv360'])

    def shaders(self):
        return to_py(self.lua, self.fake.props['glsl-shaders']) or []

    def vf(self):
        return to_py(self.lua, self.fake.props['vf']) or []

    def message(self, script, name, *args):
        self.fake.messages[f'{script}/{name}'](*args)
        self.fake.run_timers()

    def last_menu(self, command='open-menu'):
        for cmd in reversed(list(self.fake.commands.values())):
            c = to_py(self.lua, cmd)
            if c[:3] == ['script-message-to', 'uosc', command]:
                return json.loads(c[3])
        return None

    def menu_event(self, value, keep_open=False):
        self.message('bailey', 'menu-event', json.dumps({'type': 'activate', 'value': value, 'keep_open': keep_open}))

    # tests
    def test_vr_video_turns_vr_on_with_vr180_format(self):
        self.open('C:\\Videos\\Coaster VR180.webm', 5760, 2880)
        st = self.state()
        self.assertTrue(st['enabled'])
        self.assertEqual(st['input_projection'], 2)
        self.assertTrue(any('mpv360.glsl' in s for s in self.shaders()))
        self.assertEqual(self.vf(), [], 'no upscaling on VR videos')

    def test_flat_video_stays_flat_and_gets_super_resolution(self):
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.assertFalse(self.state()['enabled'])
        vf = self.vf()
        self.assertEqual(len(vf), 1)
        self.assertIn('scaling-mode=nvidia', vf[0]['name'])
        self.assertIn('scale=2', vf[0]['name'])

    def test_switching_from_vr_to_flat_turns_vr_off(self):
        self.open('C:\\Videos\\Coaster VR180.webm', 5760, 2880)
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.assertFalse(self.state()['enabled'])
        self.assertFalse(any('mpv360.glsl' in s for s in self.shaders()))

    def test_vr_settings_are_remembered_per_video(self):
        self.open('C:\\Videos\\Coaster VR180.webm', 5760, 2880)
        self.menu_event('proj:0', keep_open=True)
        self.menu_event('eye:1', keep_open=True)
        self.assertEqual(self.state()['input_projection'], 0)
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.open('C:\\Videos\\Coaster VR180.webm', 5760, 2880)
        st = self.state()
        self.assertTrue(st['enabled'])
        self.assertEqual(st['input_projection'], 0)
        self.assertEqual(st['eye'], 1)

    def test_turning_vr_off_on_a_vr_video_is_remembered(self):
        self.open('C:\\Videos\\Coaster VR180.webm', 5760, 2880)
        self.message('bailey', 'vr-toggle')
        self.assertFalse(self.state()['enabled'])
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.open('C:\\Videos\\Coaster VR180.webm', 5760, 2880)
        self.assertFalse(self.state()['enabled'])

    def test_data_file_is_written_and_reloaded(self):
        self.open('C:\\Videos\\Coaster VR180.webm', 5760, 2880)
        self.fake.emit('shutdown')
        with open(os.path.join(self.tmp.name, 'bailey-data.json')) as f:
            saved = json.load(f)
        self.assertEqual(saved['recent'][0]['tag'], 'VR')
        self.assertIn('c:/videos/coaster vr180.webm', saved['memory'])

    def test_data_file_without_vr_memory_is_valid(self):
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.fake.emit('shutdown')
        with open(os.path.join(self.tmp.name, 'bailey-data.json')) as f:
            saved = json.load(f)
        self.assertIsInstance(saved['memory'], dict)

    def test_quick_settings_menu_shows_vr_items_in_vr(self):
        self.open('C:\\Videos\\Coaster VR180.webm', 5760, 2880)
        self.message('bailey', 'quick-settings')
        menu = self.last_menu()
        titles = [i['title'] for i in menu['items']]
        for t in ['VR mode', 'Format', 'Eye', 'Look around', 'Reset view', 'Picture', 'Speed', 'Open file…', 'Recent']:
            self.assertIn(t, titles)
        self.assertNotIn('Zoom & pan', titles)
        self.assertEqual(menu['callback'], ['bailey', 'menu-event'])

    def test_quick_settings_menu_flat(self):
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.message('bailey', 'quick-settings')
        titles = [i['title'] for i in self.last_menu()['items']]
        self.assertIn('Zoom & pan', titles)
        self.assertNotIn('Format', titles)

    def test_toggle_in_menu_refreshes_menu(self):
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.message('bailey', 'quick-settings')
        self.menu_event('toggle-smooth', keep_open=True)
        self.assertFalse(self.fake.props['interpolation'])
        menu = self.last_menu('update-menu')
        picture = next(i for i in menu['items'] if i['title'] == 'Picture')
        smooth = next(i for i in picture['items'] if i['title'] == 'Smooth motion')
        self.assertEqual(smooth['hint'], 'Off')

    def test_super_resolution_toggle_removes_filter(self):
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.menu_event('toggle-super-res', keep_open=True)
        cmds = [to_py(self.lua, c) for c in self.fake.commands.values()]
        self.assertIn('no-osd vf remove @bailey', [c[0] for c in cmds if len(c) == 1])

    def test_zoom_and_pan(self):
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.message('bailey', 'zoom-pan')
        self.assertGreater(self.fake.props['video-zoom'], 0)
        self.fake.bindings['zp-in']()
        self.fake.bindings['zp-left']()
        self.assertGreater(self.fake.props['video-pan-x'], 0)
        self.fake.bindings['zp-esc']()
        self.assertEqual(self.fake.props['video-zoom'], 0)
        self.assertIsNone(self.fake.bindings['zp-in'])

    def last_uosc(self, command):
        for cmd in reversed(list(self.fake.commands.values())):
            c = to_py(self.lua, cmd)
            if c[:3] == ['script-message-to', 'uosc', command]:
                return c[3:]
        return None

    def test_controls_hide_while_looking_around(self):
        self.open('C:\\Videos\\Coaster VR180.webm', 5760, 2880)
        self.message('mpv360', 'toggle-mouse-look')
        self.assertEqual(self.last_uosc('disable-elements'), ['bailey', 'timeline,controls,volume,top_bar'])
        self.message('mpv360', 'toggle-mouse-look')
        self.assertEqual(self.last_uosc('disable-elements'), ['bailey', ''])

    def test_zoom_and_pan_refused_in_vr(self):
        self.open('C:\\Videos\\Coaster VR180.webm', 5760, 2880)
        self.message('bailey', 'zoom-pan')
        self.assertIsNone(self.fake.bindings['zp-in'])

    def test_idle_shows_start_menu(self):
        self.fake.set('idle-active', True)
        self.fake.run_timers()
        menu = self.last_menu()
        self.assertEqual(menu['type'], 'bailey-start')
        self.assertEqual(menu['items'][0]['value'], 'open-file')

    def test_open_file_runs_powershell_dialog(self):
        self.message('bailey', 'open-file')
        cmds = [to_py(self.lua, c) for c in self.fake.commands.values()]
        self.assertIn(['async', 'subprocess'], cmds)

    def test_audio_only_file_does_not_crash(self):
        self.fake.props['vid'] = False
        self.fake.props['path'] = 'C:\\Music\\song.mp3'
        self.fake.emit('start-file')
        self.fake.emit('file-loaded')
        self.fake.run_timers()
        self.assertFalse(self.state()['enabled'])



class Installer(unittest.TestCase):
    def test_powershell_scripts_are_ascii(self):
        # Windows PowerShell 5.1 reads BOM-less files as ANSI; keep them plain ASCII.
        for name in ('setup.ps1', 'uninstall.ps1'):
            with open(os.path.join(ROOT, name), 'rb') as f:
                data = f.read()
            self.assertTrue(all(b < 128 for b in data), name)

    def test_setup_never_force_creates_shared_registry_keys(self):
        with open(os.path.join(ROOT, 'setup.ps1')) as f:
            text = f.read()
        for line in text.splitlines():
            if 'New-Item' in line and '-Force' in line and 'HK' in line:
                self.fail('New-Item -Force on a registry key: ' + line.strip())


if __name__ == '__main__':
    unittest.main()
