"""Run with python3 Tests/RemoteHook/test_codex_approvals_reviewer.py."""
import importlib.util
import json
import pathlib
import tempfile

script = pathlib.Path(__file__).resolve().parents[2] / 'Sources/CodeIsland/Resources/codeisland-remote-hook.py'
spec = importlib.util.spec_from_file_location('remote_hook', script)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / 'rollout.jsonl'
    auto = {'type': 'turn_context', 'payload': {'approvals_reviewer': 'auto_review'}}
    path.write_text(json.dumps(auto) + '\n' + json.dumps({'output': 'x' * 300000}) + '\n')
    assert hook._codex_approvals_reviewer(str(path)) == 'auto_review'
    for context, expected in [({'approvals_reviewer': 'user'}, 'user'), ({}, None), (None, None)]:
        path.write_text(json.dumps(auto) + '\n' + json.dumps({'type': 'turn_context', 'payload': context}) + '\n')
        assert hook._codex_approvals_reviewer(str(path)) == expected
    path.write_text('[]\n{broken\n' + json.dumps(auto) + '\n')
    assert hook._codex_approvals_reviewer(str(path)) == 'auto_review'
    assert hook._codex_approvals_reviewer(str(path) + '.missing') is None
    assert hook._codex_approvals_reviewer(None) is None

    # Exercise main without opening a socket or executing the displayed command.
    path.write_text(json.dumps(auto) + '\n')
    hook.SOURCE = 'codex'
    hook._get_tty = lambda: None
    hook._codex_title = lambda _: None
    sent = []
    hook._send_event = lambda payload, blocking: sent.append((payload, blocking))
    event = {'hook_event_name': 'PermissionRequest', 'session_id': 'test',
             'tool_name': 'Bash', 'transcript_path': str(path)}
    hook._read_stdin_json = lambda: event
    assert hook.main() == 0
    assert sent[-1][0]['_approvals_reviewer'] == 'auto_review'
    assert sent[-1][1] is True  # The Mac still decides whether to defer to Codex.
    for key in ('approvals_reviewer', 'approvalsReviewer', '_approvals_reviewer'):
        hook._read_stdin_json = lambda: dict(event, **{key: 'user'})
        hook.main()
        assert sent[-1][0][key] == 'user'
        assert sent[-1][0].get('_approvals_reviewer') != 'auto_review'
    hook._read_stdin_json = lambda: dict(event, hook_event_name='PreToolUse')
    hook.main()
    assert '_approvals_reviewer' not in sent[-1][0]

print('Remote Codex approval reviewer checks passed')
