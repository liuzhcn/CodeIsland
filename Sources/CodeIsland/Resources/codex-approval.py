"""Persist one explicit Always Allow on the Codex host that raised the request."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile


def save_prefix(home, prefix):
    if not isinstance(prefix, list) or not prefix or not all(isinstance(arg, str) and arg for arg in prefix):
        raise ValueError("invalid prefix")
    directory = home / "rules"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = (directory / "codeisland.rules").resolve()
    block = ('prefix_rule(pattern = ' + json.dumps(prefix, ensure_ascii=False) +
             ', decision = "allow", justification = "Allowed from CodeIsland Always Allow")\n')
    with (directory / ".codeisland.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        existing = path.read_bytes() if path.exists() else b""
        if block.rstrip().encode() in existing.splitlines():
            return
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as tmp:
            try:
                if path.exists():
                    os.fchmod(tmp.fileno(), path.stat().st_mode & 0o777)
                tmp.write(existing)
                if existing and not existing.endswith(b"\n"):
                    tmp.write(b"\n")
                tmp.write(block.encode())
                tmp.flush()
                os.fsync(tmp.fileno())
                os.replace(tmp.name, path)
            finally:
                if os.path.exists(tmp.name):
                    os.unlink(tmp.name)


def config_client(home):
    control = home / "app-server-control/app-server-control.sock"
    if control.is_socket():
        return [sys.executable, str(Path(__file__).with_name("codex-event-transport.py"))]
    cli = shutil.which("codex") or str(Path.home() / ".local/bin/codex")
    return [cli, "app-server", "--listen", "stdio://"]


def save_mcp(home, cwd, namespace, tool):
    with subprocess.Popen(config_client(home), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, env=dict(os.environ, CODEX_HOME=str(home))) as client:
        def rpc(number, method, params):
            client.stdin.write(json.dumps(dict(id=number, method=method, params=params)).encode() + b"\n")
            client.stdin.flush()
            for line in client.stdout:
                message = json.loads(line)
                if message.get("id") == number:
                    if "error" in message:
                        raise ValueError("Codex rejected " + method)
                    return message["result"]
            raise EOFError("Codex connection ended")

        try:
            rpc(1, "initialize", {"clientInfo": {"name": "CodeIsland-rules", "version": "1"}})
            client.stdin.write(b'{"method":"initialized"}\n')
            read = {"cwd": cwd, "includeLayers": True}
            state = rpc(2, "config/read", read)
            config = (home / "config.toml").resolve()
            layer = next((l for l in state["layers"] if l["name"].get("type") == "user"
                          and Path(l["name"]["file"]).resolve() == config and not l.get("disabledReason")), None)
            if not layer:
                raise ValueError("no matching user configuration")
            servers = layer["config"].get("mcp_servers", {})
            ids = [k for k, v in servers.items() if v.get("command") or v.get("url")]
            matches = [k for k in ids if "".join(c if c.isalnum() else "_" for c in k) == namespace]
            server = namespace if namespace in ids else matches[0] if len(matches) == 1 else None
            if not server:
                raise ValueError("MCP server is not declared unambiguously")
            # A nested value keeps dots in names literal. The version prevents
            # a simultaneous edit from being silently overwritten.
            edit = {"keyPath": "mcp_servers", "mergeStrategy": "upsert",
                    "value": {server: {"tools": {tool: {"approval_mode": "approve"}}}}}
            result = rpc(3, "config/batchWrite", {"edits": [edit], "filePath": str(home / "config.toml"),
                         "expectedVersion": layer["version"], "reloadUserConfig": True})
            state = rpc(4, "config/read", read)
            effective = state["config"].get("mcp_servers", {}).get(server, {}).get("tools", {}).get(tool, {})
            if Path(result["filePath"]).resolve() != config or effective.get("approval_mode") != "approve":
                raise ValueError("approval did not become effective")
        finally:
            client.kill()


def main():
    request = json.load(sys.stdin)
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").resolve(strict=True)
    if request["tool"].startswith("mcp__"):
        _, server, tool = request["tool"].split("__", 2)
        if not server or not tool:
            raise ValueError("incomplete MCP name")
        save_mcp(home, request["cwd"], server, tool)
    elif request["tool"] == "Bash":
        save_prefix(home, request["prefix"])
    else:
        raise ValueError("unsupported rule")


if __name__ == "__main__":
    def timeout(*_):
        raise TimeoutError("Codex configuration timed out")
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(12)
    try:
        main()
    except (KeyError, TypeError, EOFError, OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
