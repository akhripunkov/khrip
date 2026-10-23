#!/usr/bin/env python3
"""Independent wire peer: fragmentation, framing faults and no blind retries.

Only a minimal BSON reader is needed to identify the hello/probe test commands.
The peer never connects to any external database and has no third-party deps.
"""
import collections
import socketserver
import struct
import subprocess
import sys
import threading
import time


def i32(value):
    return struct.pack('<i', value)


def bson(fields):
    out = bytearray()
    for key, value in fields.items():
        name = key.encode() + b'\0'
        if isinstance(value, bool):
            out += b'\x08' + name + bytes([value])
        elif isinstance(value, int):
            out += b'\x10' + name + i32(value)
        elif isinstance(value, float):
            out += b'\x01' + name + struct.pack('<d', value)
        else:
            encoded = value.encode()
            out += b'\x02' + name + i32(len(encoded) + 1) + encoded + b'\0'
    return i32(len(out) + 5) + out + b'\0'


def crc32c(data):
    value = 0xffffffff
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ (0x82f63b78 if value & 1 else 0)
    return value ^ 0xffffffff


def message(request, body, flags=0):
    length = 21 + len(body) + (4 if flags & 1 else 0)
    wire = i32(length) + i32(700) + i32(request) + i32(2013)
    wire += struct.pack('<I', flags) + b'\0' + body
    if flags & 1:
        wire += struct.pack('<I', crc32c(wire))
    return wire


def recv_exact(sock, count):
    parts = bytearray()
    while len(parts) < count:
        chunk = sock.recv(count - len(parts))
        if not chunk:
            return None
        parts += chunk
    return bytes(parts)


class Peer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, bad_hello=False):
        super().__init__(('127.0.0.1', 0), Handler)
        self.bad_hello = bad_hello
        self.counts = collections.Counter()
        self.lock = threading.Lock()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.settimeout(5)
        try:
            while True:
                header = recv_exact(sock, 16)
                if header is None:
                    return
                size, request, _, opcode = struct.unpack('<iiii', header)
                assert opcode == 2013 and 26 <= size <= 16 * 1024 * 1024
                data = recv_exact(sock, size - 16)
                if data is None:
                    return
                body = data[5:]
                end = body.index(0, 5)
                command = body[5:end].decode()
                if command == 'hello':
                    if self.server.bad_hello:
                        sock.sendall(i32(20) + b'\0' * 16)
                        return
                    response = bson({'ok': 1.0, 'maxWireVersion': 25,
                                     'isWritablePrimary': True,
                                     'maxMessageSizeBytes': 48000000,
                                     'maxBsonObjectSize': 16777216,
                                     'maxWriteBatchSize': 100000})
                    sock.sendall(message(request, response))
                    continue
                assert command == 'probe'
                length = struct.unpack_from('<i', body, end + 1)[0]
                mode = body[end + 5:end + 5 + length - 1].decode()
                with self.server.lock:
                    self.server.counts[mode] += 1
                wire = message(request, bson({'ok': 1.0}))
                if mode == 'fragmented':
                    for offset in range(0, len(wire), 3):
                        sock.sendall(wire[offset:offset + 3])
                        time.sleep(.001)
                elif mode == 'checksum':
                    sock.sendall(message(request, bson({'ok': 1.0}), 1))
                elif mode == 'optional_flag':
                    sock.sendall(message(request, bson({'ok': 1.0}), 1 << 31))
                elif mode == 'truncated':
                    sock.sendall(wire[:23])
                    return
                elif mode == 'oversized':
                    sock.sendall(i32(0x7fffffff) + wire[4:16])
                    return
                elif mode == 'wrong_id':
                    sock.sendall(message(request + 1, bson({'ok': 1.0})))
                    return
                elif mode == 'timeout':
                    time.sleep(.6)
                    return
                elif mode == 'disconnect':
                    return
                elif mode == 'bad_bson':
                    sock.sendall(message(request, b'\xff\xff\xff\xff\0'))
                    return
                elif mode == 'bad_checksum':
                    wire = bytearray(message(request, bson({'ok': 1.0}), 1))
                    wire[-1] ^= 128
                    sock.sendall(wire)
                    return
                elif mode == 'required_flag':
                    sock.sendall(message(request, bson({'ok': 1.0}), 4))
                    return
                elif mode.startswith('code_'):
                    # ошибка команды: «не primary» и прочие (Н8)
                    sock.sendall(message(request, bson({
                        'ok': 0.0, 'code': int(mode[5:]), 'errmsg': 'state change'})))
                elif mode in ('big_ok', 'big_bad'):
                    # документ ответа больше 16 МиБ: до +16 КиБ — законно (С1)
                    size = 16 * 1024 * 1024 + (1000 if mode == 'big_ok' else 20000)
                    sock.sendall(message(request, bson({'ok': 1.0, 'pad': 'x' * (size - 27)})))
                else:
                    assert mode == 'recover'
                    sock.sendall(wire)
        except (ConnectionError, TimeoutError):
            return


def main():
    good = Peer()
    bad = Peer(bad_hello=True)
    for server in (good, bad):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        uris = [f'mongodb://127.0.0.1:{server.server_address[1]}/test?directConnection=true'
                for server in (good, bad)]
        result = subprocess.run([sys.argv[1], *uris], timeout=20)
        if result.returncode:
            return result.returncode
        expected = {'fragmented': 1, 'checksum': 1, 'optional_flag': 1,
                    'truncated': 1, 'oversized': 1, 'wrong_id': 1,
                    'timeout': 1, 'disconnect': 1, 'bad_bson': 1,
                    'bad_checksum': 1, 'required_flag': 1, 'recover': 14,
                    'code_59': 1, 'code_189': 1, 'code_13436': 1,
                    'code_10058': 1, 'big_ok': 1, 'big_bad': 1}
        if dict(good.counts) != expected or bad.counts:
            print('FAIL command delivery counts (unexpected retry or handshake send)',
                  dict(good.counts), dict(bad.counts))
            return 1
        print('MongoDB wire peer: exact delivery counts, no blind retries')
        return 0
    finally:
        for server in (good, bad):
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    raise SystemExit(main())
