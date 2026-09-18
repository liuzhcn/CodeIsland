import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('hook', Path(__file__).parents[2] / 'Sources/CodeIsland/Resources/codeisland-remote-hook.py')
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

class DiagnosticsTest(unittest.TestCase):
    def test_metadata_only_failure_and_size_limit(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(hook.Path, 'home', return_value=Path(tmp)), patch.object(hook, 'SOCKET_PATH', tmp + '/missing'):
            payload = {'session_id': 'test', 'hook_event_name': 'Stop', 'prompt': 'PRIVATE', 'tool_input': 'PRIVATE'}
            hook._send_event(payload, False)
            path = Path(tmp) / '.codeisland/hook-diagnostics.jsonl'
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertEqual([r['phase'] for r in rows], ['attempt', 'failed'])
            self.assertEqual(rows[0]['trace'], rows[1]['trace'])
            self.assertNotIn('PRIVATE', path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            path.write_text('x' * (1024 * 1024))
            hook._trace(payload, 'sent')
            self.assertEqual(json.loads(path.read_text())['phase'], 'sent')

if __name__ == '__main__':
    unittest.main()
