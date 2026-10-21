# HTTPS-сервер с keep-alive для tests/tls.sh: /hello, /big=N, /conns (сколько
# соединений принято), POST /echo (длина тела и его края).
import http.server
import ssl
import sys

conns = [0]


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, body):
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/big="):
            self.reply(b"x" * int(self.path[5:]))
        elif self.path == "/conns":
            self.reply(str(conns[0]).encode())
        else:
            self.reply(b"hello")

    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        self.reply(str(len(data)).encode() + b" " + data[:4] + b" " + data[-4:])


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[1], sys.argv[2])
srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[3])), H)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
accept = srv.get_request


def counted():
    r = accept()
    conns[0] += 1
    return r


srv.get_request = counted
srv.serve_forever()
