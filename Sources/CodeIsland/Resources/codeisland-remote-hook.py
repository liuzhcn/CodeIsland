#!/usr/bin/env python3
import json
import fcntl
import time
import uuid
import os
import socket
import sqlite3
from pathlib import Path
import subprocess
import sys

VERSION = "0.1.6"
# Per-user socket path (#193): CodeIsland injects CODEISLAND_SOCKET_PATH via the hook
# command, but fall back to a uid-scoped path so multiple users on a shared host never
# collide on a single /tmp/codeisland.sock.
SOCKET_PATH = os.environ.get("CODEISLAND_SOCKET_PATH") or f"/tmp/codeisland-{os.getuid()}.sock"
REMOTE_HOST_ID = os.environ.get("CODEISLAND_REMOTE_HOST_ID", "")
REMOTE_HOST_NAME = os.environ.get("CODEISLAND_REMOTE_HOST_NAME", "")
SOURCE = os.environ.get("CODEISLAND_SOURCE", "")
TIMEOUT_SECONDS = 300
# A blocking approval waits on a human, so it must not be capped at the
# fire-and-forget budget: the hook is registered with an 86400s timeout on the
# agent side, and a socket timeout of 5 minutes would silently drop the decision
# of anyone who stepped away (#306).
BLOCKING_TIMEOUT_SECONDS = 86400


def _normalize_event(name):
    """Best-effort normalization matching CodeIslandCore.EventNormalizer."""
    if not isinstance(name, str):
        return ""
    # Cursor (camelCase)
    if name == "beforeSubmitPrompt":
        return "UserPromptSubmit"
    if name == "beforeShellExecution":
        return "PreToolUse"
    if name == "afterShellExecution":
        return "PostToolUse"
    if name == "beforeReadFile":
        return "PreToolUse"
    if name == "afterFileEdit":
        return "PostToolUse"
    if name == "beforeMCPExecution":
        return "PreToolUse"
    if name == "afterMCPExecution":
        return "PostToolUse"
    if name == "afterAgentThought":
        return "Notification"
    if name == "afterAgentResponse":
        return "AfterAgentResponse"
    if name == "stop":
        return "Stop"
    # Gemini
    if name == "BeforeTool":
        return "PermissionRequest"
    if name == "AfterTool":
        return "PostToolUse"
    if name == "BeforeAgent":
        return "SubagentStart"
    if name == "AfterAgent":
        return "SubagentStop"
    # GitHub Copilot CLI
    if name == "sessionStart":
        return "SessionStart"
    if name == "sessionEnd":
        return "SessionEnd"
    if name == "userPromptSubmitted":
        return "UserPromptSubmit"
    if name == "preToolUse":
        return "PreToolUse"
    if name == "postToolUse":
        return "PostToolUse"
    if name == "errorOccurred":
        return "Notification"
    # TraeCli (snake_case)
    if name == "session_start":
        return "SessionStart"
    if name == "session_end":
        return "SessionEnd"
    if name == "user_prompt_submit":
        return "UserPromptSubmit"
    if name == "pre_tool_use":
        return "PreToolUse"
    if name == "post_tool_use":
        return "PostToolUse"
    if name == "post_tool_use_failure":
        return "PostToolUseFailure"
    if name == "permission_request":
        return "PermissionRequest"
    if name == "subagent_start":
        return "SubagentStart"
    if name == "subagent_stop":
        return "SubagentStop"
    if name == "pre_compact":
        return "PreCompact"
    if name == "post_compact":
        return "PostCompact"
    if name == "notification":
        return "Notification"
    # Hermes (Nous Research) — snake_case, diverged from Claude/Gemini (#226).
    # `subagent_stop` is already handled above.
    if name == "pre_tool_call":
        return "PreToolUse"
    if name == "post_tool_call":
        return "PostToolUse"
    if name == "pre_llm_call":
        return "UserPromptSubmit"
    if name == "on_session_start":
        return "SessionStart"
    if name == "on_session_end":
        return "SessionEnd"
    if name == "on_session_reset":
        return "SessionEnd"
    return name


def _claude_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    home = os.path.expanduser("~")
    project_dir = cwd.replace("/", "-").replace(".", "-")
    path = os.path.join(home, ".claude", "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


def _codeisland_project_dir_encoded(cwd):
    return "".join("-" if ch == "/" or ch == " " or ord(ch) > 127 else ch for ch in cwd)


def _qoder_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    home = os.path.expanduser("~")
    project_dir = _codeisland_project_dir_encoded(cwd)
    path = os.path.join(home, ".qoder", "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


def _codebuddy_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    home = os.path.expanduser("~")
    project_dir = cwd.replace("/", "-").replace(".", "-")
    path = os.path.join(home, ".codebuddy", "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


def _scan_session_jsonl(path):
    if not path:
        return {}

    summary = None
    first_user = None
    last_user = None
    last_assistant = None

    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except Exception:
                    continue

                msg_type = payload.get("type")
                role = payload.get("role")
                content = payload.get("content")
                if not isinstance(content, str) or not content.strip():
                    continue

                if msg_type == "summary" and not summary:
                    summary = content
                if role == "user":
                    if not first_user:
                        first_user = content
                    last_user = content
                elif role == "assistant":
                    last_assistant = content
    except Exception:
        return {}

    return {
        "session_title": summary or first_user,
        "last_user_message": last_user,
        "last_assistant_message": last_assistant,
    }


def _scan_claude_jsonl(session_id, cwd):
    return _scan_session_jsonl(_claude_jsonl_path(session_id, cwd))


def _scan_qoder_jsonl(session_id, cwd):
    return _scan_session_jsonl(_qoder_jsonl_path(session_id, cwd))


def _scan_codebuddy_jsonl(session_id, cwd):
    return _scan_session_jsonl(_codebuddy_jsonl_path(session_id, cwd))


def _read_stdin_json():
    try:
        return json.load(sys.stdin)
    except Exception:
        return None


def _trace(payload, phase, error=None):
    # Bounded metadata only; never persist prompts, tool arguments or responses.
    row = {"time": time.time(), "trace": payload.get("_diagnostic_id"),
           "session": str(payload.get("session_id", ""))[:160],
           "event": str(payload.get("hook_event_name", ""))[:80], "phase": phase}
    if error is not None:
        row["error"] = type(error).__name__
        row["errno"] = getattr(error, "errno", None)
    try:
        directory = Path.home() / ".codeisland"
        directory.mkdir(mode=0o700, exist_ok=True)
        fd = os.open(directory / "hook-diagnostics.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            if os.fstat(stream.fileno()).st_size >= 1024 * 1024:
                stream.truncate(0)
            stream.write(json.dumps(row) + "\n")
    except OSError:
        pass  # Diagnostics must never prevent a hook from running.


def _send_event(payload, expects_response):
    payload["_diagnostic_id"] = uuid.uuid4().hex
    _trace(payload, "attempt")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(BLOCKING_TIMEOUT_SECONDS if expects_response else TIMEOUT_SECONDS)
    try:
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(payload).encode("utf-8"))
        sock.shutdown(socket.SHUT_WR)
        _trace(payload, "sent")
        if expects_response:
            response = sock.recv(65536)
            return response.decode("utf-8") if response else None
        return None
    except (OSError, socket.error) as error:
        _trace(payload, "failed", error)
        # Preserve the existing non-blocking failure behavior.
        return None
    finally:
        try:
            sock.close()
        except Exception:
            pass


def _get_tty():
    pid = os.getppid()
    for _ in range(20):
        if pid <= 1:
            break
        try:
            result = subprocess.run(
                ["ps", "-p", str(pid), "-o", "tty=,ppid="],
                capture_output=True,
                text=True,
                timeout=2,
            )
            parts = result.stdout.strip().split()
            if not parts:
                break
            tty = parts[0]
            if tty and tty not in {"??", "-"}:
                return tty if tty.startswith("/dev/") else f"/dev/{tty}"
            if len(parts) >= 2:
                pid = int(parts[1])
            else:
                break
        except Exception:
            break
    return None


def _codex_title(session_id, codex_home=None):
    home = Path(codex_home or os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    try:
        with sqlite3.connect((home / "state_5.sqlite").as_uri() + "?mode=ro", uri=True, timeout=0.2) as connection:
            row = connection.execute("SELECT name, title FROM threads WHERE id = ?", (session_id,)).fetchone()
            return next((value.strip() for value in (row or ()) if isinstance(value, str) and value.strip()), None)
    except (sqlite3.Error, ValueError, OSError):
        return None


def main():
    if "--version" in sys.argv:
        print(VERSION)
        return 0

    data = _read_stdin_json()
    if not data:
        return 1

    event_name = data.get("hook_event_name") or data.get("event")
    session_id = data.get("session_id")
    cwd = data.get("cwd") or os.getcwd()
    if not event_name or not session_id:
        return 1

    normalized_event = _normalize_event(event_name)

    payload = dict(data)
    payload["hook_event_name"] = event_name
    payload["session_id"] = session_id
    payload["cwd"] = cwd
    payload["_source"] = payload.get("_source") or SOURCE
    payload["_remote_host_id"] = payload.get("_remote_host_id") or REMOTE_HOST_ID
    payload["_remote_host_name"] = payload.get("_remote_host_name") or REMOTE_HOST_NAME
    payload["_tty"] = payload.get("_tty") or _get_tty()

    if SOURCE == "codex":
        title = _codex_title(session_id)
        if title:
            payload["session_title"] = title

    if SOURCE == "claude":
        extras = _scan_claude_jsonl(session_id, cwd)
        for key, value in extras.items():
            if value and not payload.get(key):
                payload[key] = value
        if normalized_event == "UserPromptSubmit" and not payload.get("prompt"):
            prompt = extras.get("last_user_message")
            if prompt:
                payload["prompt"] = prompt

    if SOURCE == "qoder":
        extras = _scan_qoder_jsonl(session_id, cwd)
        for key, value in extras.items():
            if value and not payload.get(key):
                payload[key] = value
        if normalized_event == "UserPromptSubmit" and not payload.get("prompt"):
            prompt = extras.get("last_user_message")
            if prompt:
                payload["prompt"] = prompt

    if SOURCE == "codebuddy":
        extras = _scan_codebuddy_jsonl(session_id, cwd)
        for key, value in extras.items():
            if value and not payload.get(key):
                payload[key] = value
        if normalized_event == "UserPromptSubmit" and not payload.get("prompt"):
            prompt = extras.get("last_user_message")
            if prompt:
                payload["prompt"] = prompt

    # Blocking events: permission prompts + question prompts
    expects_response = normalized_event == "PermissionRequest" or (
        normalized_event == "Notification" and payload.get("question")
    )
    response = _send_event(payload, expects_response)
    if response:
        if SOURCE == "google-antigravity" or SOURCE == "gemini":
            try:
                res_obj = json.loads(response)
                behavior = res_obj.get("hookSpecificOutput", {}).get("decision", {}).get("behavior")
                if behavior in ("allow", "always"):
                    print(json.dumps({"decision": "allow"}))
                else:
                    print(json.dumps({"decision": "deny"}))
            except Exception:
                if '"behavior":"allow"' in response or '"behavior":"always"' in response:
                    print(json.dumps({"decision": "allow"}))
                elif '"behavior":"deny"' in response:
                    print(json.dumps({"decision": "deny"}))
                else:
                    print(response)
        else:
            print(response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
