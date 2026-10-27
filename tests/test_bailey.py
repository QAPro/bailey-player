"""Tests for bailey.lua (and our mpv360 additions), run outside mpv.

Uses LuaJIT 2.1 through `lupa` — the same Lua engine mpv uses on Windows.
Run:  PYTHONPATH=<folder with lupa> python3 -m unittest discover -s tests
"""

import json
import math
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


    def test_link_in_finds_the_last_link(self):
        f = self.M.link_in
        self.assertEqual(f('https://youtu.be/oldhttps://youtu.be/new'), 'https://youtu.be/new')
        self.assertEqual(f('  watch HTTPS://x.com/v  '), 'HTTPS://x.com/v')
        self.assertIsNone(f('roller coaster'))
        self.assertIsNone(f(''))

    def test_is_url(self):
        self.assertEqual(self.M.is_url('  https://youtu.be/abc  '), 'https://youtu.be/abc')
        self.assertEqual(self.M.is_url('http://example.com/v.mp4'), 'http://example.com/v.mp4')
        for bad in ['hello', 'C:\\Videos\\a.mp4', 'ftp://x/y', 'https://a b', '', None]:
            self.assertIsNone(self.M.is_url(bad), bad)

    def test_ytdlp_args(self):
        lua = self.lua
        args = to_py(lua, self.M.ytdlp_args('C:\\yt-dlp.exe', 'https://x/y', 'D:\\Vids', 'C:\\ffmpeg.exe'))
        self.assertEqual(args[0], 'C:\\yt-dlp.exe')
        self.assertEqual(args[-2:], ['--', 'https://x/y'])
        self.assertEqual(args[args.index('-P') + 1], 'D:\\Vids')
        self.assertEqual(args[args.index('--ffmpeg-location') + 1], 'C:\\ffmpeg.exe')
        self.assertIn('after_move:filepath', args)
        no_ff = to_py(lua, self.M.ytdlp_args('yt-dlp', 'https://x/y', 'D:\\Vids', ''))
        self.assertNotIn('--ffmpeg-location', no_ff)

    def test_format_size_and_last_line(self):
        self.assertEqual(self.M.format_size(300 * 1024 * 1024), '300 MB')
        self.assertEqual(self.M.format_size(int(2.5 * 1024 ** 3)), '2.5 GB')
        self.assertEqual(self.M.last_line('a\r\nC:\\v\\b.webm\r\n\r\n'), 'C:\\v\\b.webm')
        self.assertIsNone(self.M.last_line(''))


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

    def osd(self):
        return list(to_py(self.lua, self.fake.osd) or [])

    def cmds(self):
        return [to_py(self.lua, c) for c in self.fake.commands.values()]

    def test_link_box_opens_empty(self):
        self.fake.props['clipboard/text'] = 'https://youtu.be/old'
        self.message('bailey', 'open-link')
        menu = self.last_menu()
        self.assertEqual(menu['type'], 'bailey-link')
        self.assertIsNone(menu.get('search_suggestion'))
        self.assertIn('Paste a link', menu['items'][0]['title'])

    def test_ctrl_v_opens_link_box_with_the_copied_link(self):
        self.fake.props['clipboard/text'] = ' https://youtu.be/abc '
        self.message('bailey', 'paste-link')
        menu = self.last_menu()
        self.assertEqual(menu['search_suggestion'], 'https://youtu.be/abc')
        self.assertEqual(menu['items'][0]['value'], 'link-play:https://youtu.be/abc')
        self.assertEqual(menu['items'][1]['value'], 'link-download:https://youtu.be/abc')

    def test_options_follow_what_is_typed(self):
        self.fake.props['clipboard/text'] = 'https://youtu.be/old'
        self.message('bailey', 'paste-link')
        self.message('bailey', 'link-typed', 'https://youtu.be/new')
        menu = self.last_menu('update-menu')
        self.assertIsNone(menu.get('search_suggestion'), 'an update must not reset the box')
        self.assertEqual(menu['items'][0]['value'], 'link-play:https://youtu.be/new')
        self.assertEqual(menu['items'][1]['value'], 'link-download:https://youtu.be/new')

    def test_enter_plays_what_is_in_the_box(self):
        self.message('bailey', 'open-link')
        self.message('bailey', 'link-typed', 'https://youtu.be/abc')
        self.message('bailey', 'menu-event', json.dumps({'type': 'key', 'id': 'enter', 'key': 'enter'}))
        self.assertIn(['loadfile', 'https://youtu.be/abc', 'replace'], self.cmds())

    def test_enter_does_nothing_once_the_box_is_closed(self):
        self.message('bailey', 'open-link')
        self.message('bailey', 'link-typed', 'https://youtu.be/abc')
        self.message('bailey', 'menu-closed', 'bailey-link')
        self.message('bailey', 'menu-event', json.dumps({'type': 'key', 'id': 'enter', 'key': 'enter'}))
        self.assertNotIn(['loadfile', 'https://youtu.be/abc', 'replace'], self.cmds())

    def test_text_that_is_not_a_link_is_explained(self):
        self.message('bailey', 'open-link')
        self.message('bailey', 'link-typed', 'roller coaster')
        menu = self.last_menu('update-menu')
        self.assertIn('not a link', menu['items'][0]['title'])
        self.message('bailey', 'menu-event', json.dumps({'type': 'key', 'id': 'enter', 'key': 'enter'}))
        self.assertFalse([c for c in self.cmds() if c[:1] == ['loadfile']])

    def test_paste_on_start_menu_opens_link_box(self):
        self.fake.set('idle-active', True)
        self.fake.run_timers()
        self.assertEqual(self.last_menu()['on_paste'], ['script-message-to', 'bailey', 'link-pasted'])
        self.message('bailey', 'link-pasted', 'https://youtu.be/abc')
        self.assertEqual(self.last_menu()['search_suggestion'], 'https://youtu.be/abc')

    def test_main_menu_has_no_comment_lines(self):
        with open(os.path.join(ROOT, 'config', 'input.conf'), encoding='utf-8') as fh:
            for line in fh:
                if line.startswith('#') and '#!' in line:
                    self.assertRegex(line, r'^#\s+\S+.*#!', 'a comment would show up in the ☰ menu: ' + line)
                    self.assertNotIn('`', line, 'a comment would show up in the ☰ menu: ' + line)

    def start_download(self):
        self.menu_event('link-download:https://youtu.be/abc')
        jobs = list(self.fake['async'].values())
        self.assertTrue(jobs, 'no background job started')
        job = jobs[-1]
        args = to_py(self.lua, job.cmd.args)
        self.assertEqual(args[-1], 'https://youtu.be/abc')
        return job

    def test_download_then_play(self):
        self.fake.props['idle-active'] = True
        job = self.start_download()
        self.fake.dir_files = self.lua.table_from(['Coaster [abc].f401.mp4.part'])
        self.fake.run_timers()
        path = 'C:\\Users\\p\\Videos\\Bailey Player\\Coaster VR180 [abc].webm'
        job.cb(True, self.lua.table_from({'status': 0, 'stdout': path + '\r\n'}))
        self.assertIn(['loadfile', path, 'replace'], self.cmds())

    def test_download_while_watching_goes_to_recent(self):
        self.fake.props['idle-active'] = False
        job = self.start_download()
        path = 'C:\\Videos\\Bailey Player\\Coaster [abc].webm'
        job.cb(True, self.lua.table_from({'status': 0, 'stdout': path}))
        self.assertNotIn(['loadfile', path, 'replace'], self.cmds())
        with open(os.path.join(self.tmp.name, 'bailey-data.json')) as f:
            data = json.load(f)
        self.assertEqual(data['recent'][0]['path'], path)

    def test_download_failure_is_shown(self):
        job = self.start_download()
        job.cb(True, self.lua.table_from({'status': 1, 'stderr': 'ERROR: Unsupported URL: https://youtu.be/abc\n'}))
        self.assertTrue(any('Download failed: ERROR: Unsupported URL' in m for m in self.osd()))

    def test_only_one_download_at_a_time(self):
        self.start_download()
        before = len(self.fake['async'])
        self.menu_event('link-download:https://youtu.be/xyz')
        self.assertEqual(len(self.fake['async']), before)

    def test_streamed_link_detected_from_its_title(self):
        self.fake.emit('end-file')
        self.fake.props['path'] = 'https://www.youtube.com/watch?v=abc'
        self.fake.props['media-title'] = 'Alps 360 walk'
        self.fake.emit('start-file')
        self.fake.set('video-params', self.lua.table_from({'w': 3840, 'h': 1920}))
        self.fake.run_timers()
        self.assertEqual(self.state()['input_projection'], 0)
        with open(os.path.join(self.tmp.name, 'bailey-data.json')) as f:
            data = json.load(f)
        self.assertEqual(data['recent'][0]['path'], 'https://www.youtube.com/watch?v=abc')

    def test_broken_link_says_so(self):
        self.fake.props['path'] = 'https://example.com/nothing'
        self.fake.emit('start-file')
        self.fake.emit('end-file', self.lua.table_from({'reason': 'error'}))
        self.assertTrue(any('Could not play that link' in m for m in self.osd()))

    def test_v_on_a_normal_video_gives_the_curved_screen(self):
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.menu_event('vr-toggle')
        st = self.state()
        self.assertTrue(st['enabled'])
        self.assertEqual(st['input_projection'], 8)
        self.assertAlmostEqual(st['curve_arc'], math.radians(150), places=4)
        self.assertAlmostEqual(st['fov'], 1.7, places=4)
        opts = ' '.join(str(c) for c in self.cmds())
        self.assertIn('mpv360/input_projection=8', opts)
        self.assertIn('mpv360/curve_arc=2.61', opts)

    def test_curved_screen_width_changes_and_is_remembered(self):
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.menu_event('vr-toggle')
        self.menu_event('curve:+', keep_open=True)
        self.assertAlmostEqual(self.state()['curve_arc'], math.radians(165), places=4)
        self.open('C:\\Videos\\other.mp4', 1920, 1080)
        self.assertFalse(self.state()['enabled'])
        self.menu_event('vr-toggle')   # other video: fresh curved screen at 150°
        self.assertAlmostEqual(self.state()['curve_arc'], math.radians(150), places=4)
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        st = self.state()
        self.assertTrue(st['enabled'])
        self.assertEqual(st['input_projection'], 8)
        self.assertAlmostEqual(st['curve_arc'], math.radians(165), places=4)

    def test_curved_screen_width_has_limits(self):
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.menu_event('vr-toggle')
        for _ in range(30):
            self.menu_event('curve:-', keep_open=True)
        self.assertAlmostEqual(self.state()['curve_arc'], math.radians(60), places=4)

    def test_quick_settings_show_screen_width_on_curved(self):
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.menu_event('vr-toggle')
        self.message('bailey', 'quick-settings')
        titles = [i['title'] for i in self.last_menu()['items']]
        self.assertIn('VR mode (curved screen)', titles)
        self.assertIn('Screen width', titles)

    def test_reset_view_on_curved_screen_fills_window(self):
        self.open('C:\\Videos\\holiday.mp4', 1920, 1080)
        self.menu_event('vr-toggle')
        self.menu_event('vr-zoom:+', keep_open=True)
        self.message('mpv360', 'reset-view')
        self.assertAlmostEqual(self.state()['fov'], 1.7, places=4)

    def test_v_on_a_vr_video_keeps_its_format(self):
        self.open('C:\\Videos\\Coaster VR180.webm', 5760, 2880)
        self.menu_event('vr-toggle')
        self.menu_event('vr-toggle')
        self.assertEqual(self.state()['input_projection'], 2)

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
    def test_skip_keys_and_buttons(self):
        with open(os.path.join(ROOT, 'config', 'input.conf'), encoding='utf-8') as f:
            binds = {}
            for line in f:
                parts = line.split(None, 1)
                if parts and not line.startswith('#'):
                    binds[parts[0]] = parts[1].split('#!')[0].strip()
        for key, secs in [('j', -10), ('l', 10), ('J', -30), ('L', 30), ('LEFT', -10), ('RIGHT', 10),
                          ('Shift+LEFT', -30), ('Shift+RIGHT', 30)]:
            self.assertTrue(binds.get(key, '').startswith(f'seek {secs};'), key)
        with open(os.path.join(ROOT, 'config', 'script-opts', 'mpv360.conf'), encoding='utf-8') as f:
            vr_keys = {l.split('=', 1)[1].strip().lower() for l in f if '=' in l and not l.startswith('#')}
        self.assertFalse({'j', 'l', 'shift+j', 'shift+l'} & vr_keys, 'J/L must stay free in VR mode')
        with open(os.path.join(ROOT, 'config', 'script-opts', 'uosc.conf'), encoding='utf-8') as f:
            controls = [l for l in f if l.startswith('controls=')][0]
        for icon in ['replay_30', 'replay_10', 'forward_10', 'forward_30']:
            self.assertIn(f'command:{icon}:seek', controls)

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
