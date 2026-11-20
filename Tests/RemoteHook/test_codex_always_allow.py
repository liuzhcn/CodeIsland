import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

resources = Path(__file__).resolve().parents[2] / "Sources/CodeIsland/Resources"
spec = importlib.util.spec_from_file_location("remote_hook", resources / "codeisland-remote-hook.py")
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


class RemoteAlwaysAllowTest(unittest.TestCase):
    def run_request(self, home, tool, responses):
        event = {"session_id": "fixture", "hook_event_name": "PermissionRequest",
                 "tool_name": tool, "cwd": str(home)}
        sent = []
        def receive(payload, blocking):
            sent.append(dict(payload))
            return json.dumps(responses[len(sent) - 1])
        stdout = io.StringIO()
        with patch.dict(os.environ, {"CODEX_HOME": str(home)}), patch.object(hook, "SOURCE", "codex"), \
             patch.object(hook, "_read_stdin_json", return_value=event), \
             patch.object(hook, "_linked_codex_project", return_value=True), \
             patch.object(hook, "_send_event", side_effect=receive), contextlib.redirect_stdout(stdout):
            self.assertEqual(hook.main(), 0)
        return json.loads(stdout.getvalue()), sent

    def test_saved_prefix_is_idempotent_and_limited_to_the_origin_home(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            for _ in range(2):
                response, sent = self.run_request(home, "Bash", [{"_codeisland_save_rule": ["example", "status"]}])
                self.assertEqual(response["hookSpecificOutput"]["decision"], {"behavior": "allow"})
                self.assertTrue(sent[0]["_codeisland_can_save_rule"])
            rules = (home / "rules/codeisland.rules").read_text()
            self.assertEqual(rules.count("prefix_rule("), 1)
            self.assertIn('["example", "status"]', rules)

    def test_failed_save_reports_failure_and_respects_subsequent_denial(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            deny = {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "deny"}}}
            reply, sent = self.run_request(home, "Bash", [{"_codeisland_save_rule": []}, deny])
            self.assertEqual(reply, deny)
            self.assertTrue(sent[1]["_codeisland_save_failed"])
            self.assertFalse((home / "rules").exists())
