# Сервис для tests/http.sh (tests/load/fetch_store.kh): «ok», если заголовков
# X-G-* в запросе 201 и все они одного поколения, иначе — что пришло. Порт —
# аргумент.
import http.client
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# по умолчанию — не больше 100 заголовков
http.client._MAXHEADERS = 1000


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        vals = [v for k, v in self.headers.items() if k.lower().startswith("x-g-")]
        if len(vals) == 201 and len(set(vals)) == 1:
            body = b"ok"
        else:
            body = ("mixed %d %s" % (len(vals), ",".join(sorted(set(vals))))).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
