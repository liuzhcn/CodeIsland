import importlib.util
import pathlib
import socket
import struct
import threading

path = pathlib.Path(__file__).parents[2] / 'Sources/CodeIsland/Resources/codex-event-transport.py'
spec = importlib.util.spec_from_file_location('transport', path)
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)

for payload in (b'{}', b'x' * 126, b'x' * 65536):
    left, right = socket.socketpair()
    try:
        sender = threading.Thread(target=transport.send_frame, args=(left, payload))
        sender.start()
        first, second = transport.read_exact(right, 2)
        assert first == 129 and second & 128
        length = second & 127
        if length == 126:
            length = struct.unpack('!H', transport.read_exact(right, 2))[0]
        elif length == 127:
            length = struct.unpack('!Q', transport.read_exact(right, 8))[0]
        mask = transport.read_exact(right, 4)
        encoded = transport.read_exact(right, length)
        assert bytes(x ^ mask[i % 4] for i, x in enumerate(encoded)) == payload
        sender.join(timeout=2)
        assert not sender.is_alive()
    finally:
        left.close()
        right.close()
print('event transport framing checks passed')
