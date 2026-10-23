#!/usr/bin/env python3
"""Deliberately malformed HTTP responses and request-count assertions."""
import http.server
import json
import socket
import ssl
import sys
import threading
import time
import urllib.parse


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, *args):
        super().__init__(*args)
        self.activity_lock = threading.Lock()
        self.active = self.peak = self.requests = 0


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        with self.server.activity_lock:
            if self.path == "/reset":
                self.server.peak = self.server.active
                self.server.requests = 0
            body = json.dumps({"active": self.server.active,
                               "peak": self.server.peak,
                               "requests": self.server.requests}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        path = urllib.parse.urlsplit(self.path).path
        if path in ("/admission", "/admission-truncated", "/hold"):
            with self.server.activity_lock:
                self.server.active += 1
                self.server.requests += 1
                self.server.peak = max(self.server.peak, self.server.active)
            time.sleep(0.4 if path == "/hold" else 0.08)
            with self.server.activity_lock:
                self.server.active -= 1
            length = 5 if path == "/admission-truncated" else 2
            self.wfile.write(f"HTTP/1.1 200 OK\r\nContent-Length: {length}\r\n\r\n".encode() + b"ok")
            self.wfile.flush()
            if length == 5:
                self.close_connection = True
            return
        if path == "/valid":
            self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            self.wfile.flush()
            return
        if path == "/chunked":
            self.wfile.write(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;extension=yes\r\no\r\n1\r\nk\r\n0\r\n\r\n")
            self.wfile.flush()
            return
        if path == "/slow":
            time.sleep(0.4)
            raw = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        elif path == "/truncated":
            raw = b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nok"
        elif path == "/truncated-chunk":
            raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nok"
        elif path == "/bad-chunk":
            raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok!!0\r\n\r\n"
        elif path == "/duplicate":
            raw = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nok"
        elif path == "/ambiguous":
            raw = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        elif path == "/overflow":
            raw = b"HTTP/1.1 200 OK\r\nContent-Length: 999999999999999999999999\r\n\r\n"
        elif path == "/large-close":
            raw = b"HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\nConnection: close\r\n\r\n" + b"z" * 1048576
        elif path == "/too-many-chunks":
            raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + b"1\r\nx\r\n" * 65537 + b"0\r\n\r\n"
        elif path == "/late-error":
            raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\nX-ClickHouse-Exception-Code: 395\r\n\r\n"
        elif path == "/unsupported-compression":
            raw = b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\nok"
        elif path == "/interim":
            raw = b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        else:
            raw = b"HTTP/1.1 500 Unknown\r\nContent-Length: 0\r\n\r\n"
        try:
            self.wfile.write(raw)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


if __name__ == "__main__":
    server = Server(("127.0.0.1", int(sys.argv[1])), Handler)
    if len(sys.argv) > 2:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_3
        context.load_cert_chain(sys.argv[2] + "/chain_ec.pem", sys.argv[2] + "/leaf.key")
        server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()
