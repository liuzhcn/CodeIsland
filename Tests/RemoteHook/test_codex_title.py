"""Run with python3 Tests/RemoteHook/test_codex_title.py."""
import importlib.util
import pathlib
import sqlite3
import tempfile

script = pathlib.Path(__file__).resolve().parents[2] / 'Sources/CodeIsland/Resources/codeisland-remote-hook.py'
spec = importlib.util.spec_from_file_location('remote_hook', script)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
with tempfile.TemporaryDirectory() as directory:
    assert hook._codex_title('test', directory) is None
    with sqlite3.connect(str(pathlib.Path(directory) / 'state_5.sqlite')) as connection:
        connection.execute('CREATE TABLE threads(id TEXT, name TEXT, title TEXT)')
        connection.execute('INSERT INTO threads VALUES(?, ?, ?)', ('test', 'Example session', 'Original prompt'))
    assert hook._codex_title('test', directory) == 'Example session'
    assert hook._codex_title('missing', directory) is None
print('Remote Codex title checks passed')
