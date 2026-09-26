#!/usr/bin/env python3
"""JSON-lines to the existing Codex control socket; no rollout/state DB reads."""
import base64
import hashlib
import json
import os
import selectors
import socket
import struct
import sys

MAX_FRAME = 16 * 1024 * 1024


def read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        chunk = stream.recv(count - len(result))
        if not chunk:
            raise EOFError('Codex event connection closed')
        result.extend(chunk)
    return bytes(result)


def send_frame(stream, data, opcode=1):
    mask = os.urandom(4)
    size = len(data)
    if size > MAX_FRAME:
        raise ValueError('Codex frame exceeds size limit')
    header = bytes([0x80 | opcode])
    if size < 126:
        header += bytes([0x80 | size])
    elif size < 65536:
        header += b'\xfe' + struct.pack('!H', size)
    else:
        header += b'\xff' + struct.pack('!Q', size)
    stream.sendall(header + mask + bytes(value ^ mask[i % 4] for i, value in enumerate(data)))


def main():
    home = os.environ.get('CODEX_HOME') or os.path.expanduser('~/.codex')
    with socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(10)
        stream.connect(os.path.join(home, 'app-server-control', 'app-server-control.sock'))
        key = base64.b64encode(os.urandom(16)).decode()
        stream.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                        'Connection: Upgrade\r\nSec-WebSocket-Key: ' + key +
                        '\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        headers = bytearray()
        while not headers.endswith(b'\r\n\r\n'):
            if len(headers) >= 16384:
                raise ValueError('Oversized websocket handshake')
            headers.extend(read_exact(stream, 1))
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        if not headers.startswith(b'HTTP/1.1 101 ') or accept not in headers:
            raise ValueError('Codex websocket handshake rejected')
        pending = bytearray()
        fragmented = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(stream, selectors.EVENT_READ)
            selector.register(sys.stdin.buffer, selectors.EVENT_READ)
            while True:
                for selected, _ in selector.select():
                    if selected.fileobj is not stream:
                        chunk = os.read(sys.stdin.fileno(), 65536)
                        if not chunk:
                            return
                        pending.extend(chunk)
                        if len(pending) > MAX_FRAME:
                            raise ValueError('Oversized JSON request')
                        while b'\n' in pending:
                            line, _, rest = pending.partition(b'\n')
                            pending = bytearray(rest)
                            if line:
                                send_frame(stream, line)
                        continue
                    first, second = read_exact(stream, 2)
                    opcode, size = first & 15, second & 127
                    if second & 128 or first & 0x70:
                        raise ValueError('Unexpected websocket frame flags')
                    if size == 126:
                        size = struct.unpack('!H', read_exact(stream, 2))[0]
                    elif size == 127:
                        size = struct.unpack('!Q', read_exact(stream, 8))[0]
                    if size > MAX_FRAME or len(fragmented) + size > MAX_FRAME:
                        raise ValueError('Oversized websocket message')
                    data = read_exact(stream, size)
                    if opcode == 8:
                        return
                    if opcode == 9:
                        send_frame(stream, data, opcode=10)
                        continue
                    if opcode == 10:
                        continue
                    if opcode not in (0, 1):
                        raise ValueError('Expected a text websocket message')
                    fragmented.extend(data)
                    if first & 128:
                        message = json.loads(fragmented)
                        print(json.dumps(message, separators=(',', ':')), flush=True)
                        fragmented.clear()


if __name__ == '__main__':
    try:
        main()
    except (OSError, EOFError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
