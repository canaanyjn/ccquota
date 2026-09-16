import contextlib, io, json, pathlib, runpy, tempfile, unittest
from unittest.mock import patch
ROOT = pathlib.Path(__file__).resolve().parent
class IntegrationTests(unittest.TestCase):
    def test_connect_preserves_settings_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp, patch('pathlib.Path.home', return_value=pathlib.Path(tmp)), contextlib.redirect_stdout(io.StringIO()):
            home = pathlib.Path(tmp)
            settings = home / '.claude/settings.json'
            settings.parent.mkdir()
            old = {'type':'command','command':'printf original'}
            settings.write_text(json.dumps({'statusLine':old,'model':'keep-this'}))
            runpy.run_path(str(ROOT / 'connect.py'))
            first = settings.read_text()
            runpy.run_path(str(ROOT / 'connect.py'))
            self.assertEqual(first, settings.read_text())
            self.assertEqual(json.loads(first)['model'],'keep-this')
            state = home / 'Library/Application Support/UsageBar'
            self.assertEqual(json.loads((state/'previous-statusline.json').read_text()),old)
            with patch('sys.stdin',io.StringIO(json.dumps({'rate_limits':{'five_hour':{'used_percentage':37,'resets_at':2000000000}}}))), patch('subprocess.run') as original:
                runpy.run_path(str(ROOT/'claude-hook.py'))
                original.assert_called_once()
            cache = json.loads((state/'claude.json').read_text())
            self.assertEqual(cache['windows'][0]['used'],37)
            with patch('sys.stdin', io.StringIO('{}')), patch('subprocess.run'):
                runpy.run_path(str(ROOT/'claude-hook.py'))
            self.assertEqual(json.loads((state/'claude.json').read_text()),cache)
    def test_malformed_settings_not_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp, patch('pathlib.Path.home', return_value=pathlib.Path(tmp)), contextlib.redirect_stdout(io.StringIO()):
            settings = pathlib.Path(tmp)/'.claude/settings.json'
            settings.parent.mkdir(); settings.write_text('{broken')
            runpy.run_path(str(ROOT/'connect.py'))
            self.assertEqual(settings.read_text(),'{broken')
if __name__ == '__main__': unittest.main()
