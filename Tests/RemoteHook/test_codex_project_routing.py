import json
import os
from pathlib import Path
from socketserver import StreamRequestHandler, UnixStreamServer
import subprocess
import sys
import tempfile
from threading import Thread
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'Sources/CodeIsland/Resources/codeisland-remote-hook.py'


class RoutingTest(unittest.TestCase):
    def test_only_linked_approvals_send_tool_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "linked"
            nested = root / "src"
            nested.mkdir(parents=True)
            elsewhere = Path(tmp) / "remote-only"
            elsewhere.mkdir()
            link = root / "link-out"
            link.symlink_to(elsewhere)
            endpoint = str(Path(tmp) / "socket")
            messages = []

            class Receiver(StreamRequestHandler):
                def handle(self):
                    request = json.load(self.rfile)
                    messages.append(request)
                    if "_codeisland_query" in request:
                        reply = {"root": str(root)} if request["cwd"].startswith(str(root)) else {}
                    else:
                        reply = {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                                        "decision": {"behavior": "deny"}}}
                    self.wfile.write(json.dumps(reply).encode())

            env = dict(os.environ, HOME=tmp, CODEISLAND_SOCKET_PATH=endpoint,
                       CODEISLAND_REMOTE_HOST_ID="host", CODEISLAND_SOURCE="codex")
            def run(cwd):
                request = dict(cwd=str(cwd), hook_event_name="PermissionRequest",
                               session_id="sample", tool_name="Bash", tool_input={"command": "test-only"})
                return subprocess.run([sys.executable, str(SCRIPT)], input=json.dumps(request),
                                      env=env, text=True, timeout=5, capture_output=True, check=True).stdout

            with UnixStreamServer(endpoint, Receiver) as server:
                thread = Thread(target=server.serve_forever)
                thread.start()
                try:
                    for cwd in (elsewhere, link):
                        messages.clear()
                        self.assertEqual(run(cwd), "")
                        self.assertEqual(messages, [{"_codeisland_query": "linkedCodexRoot",
                                                    "_remote_host_id": "host", "cwd": str(cwd)}])
                    messages.clear()
                    self.assertEqual(json.loads(run(nested))["hookSpecificOutput"]["decision"]["behavior"], "deny")
                    self.assertEqual(len(messages), 2)
                    self.assertEqual(messages[1]["tool_input"], {"command": "test-only"})
                finally:
                    server.shutdown()
                    thread.join()
            self.assertEqual(run(nested), "")


if __name__ == "__main__":
    unittest.main()
