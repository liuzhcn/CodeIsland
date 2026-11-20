#!/usr/bin/env python3
"""Check process ownership of known rollouts; never read conversation contents."""
import base64
import json
import os
import sys


def live_transcripts(paths, proc_root='/proc'):
    """None means unavailable/incomplete, never a successful empty observation."""
    wanted = {os.path.realpath(path): path for path in paths}
    live = set()
    try:
        entries = os.listdir(proc_root)
        for pid in entries:
            if not pid.isdigit():
                continue
            process = os.path.join(proc_root, pid)
            try:
                if os.stat(process).st_uid != os.geteuid():
                    continue
                try:
                    executable = os.readlink(os.path.join(process, 'exe'))
                except PermissionError:
                    # setuid sshd/sd-pam can belong to this UID while denying
                    # exe/fd access. Do not let those unrelated processes
                    # disable the check; an inaccessible Codex stays unknown.
                    with open(os.path.join(process, 'comm')) as stream:
                        if stream.read().strip() != 'codex':
                            continue
                    raise
                if os.path.basename(executable).removesuffix(' (deleted)') != 'codex':
                    continue
                fd_root = os.path.join(process, 'fd')
                for fd in os.listdir(fd_root):
                    try:
                        target = os.readlink(os.path.join(fd_root, fd))
                    except FileNotFoundError:
                        continue  # Descriptor closed while being enumerated.
                    if target.startswith('/'):
                        path = wanted.get(os.path.realpath(target.removesuffix(' (deleted)')))
                        if path is not None:
                            live.add(path)
            except (FileNotFoundError, ProcessLookupError):
                continue  # Process exited during the check.
        return sorted(live)
    except OSError:
        return None  # Unsupported host or incomplete process visibility.


if __name__ == '__main__':
    paths = json.loads(base64.b64decode(sys.argv[1]))
    print(json.dumps(live_transcripts(paths)))
