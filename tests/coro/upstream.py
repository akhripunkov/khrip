# Сервис для tests/coro.sh: ответы разной формы — по частям, с Content-Length,
# до закрытия соединения, в стиле HTTP/1.0 и обрыв без ответа. Порт — аргумент.
import socket
import sys
import threading

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sys.argv[1])))
srv.listen(64)


def handle(c):
    buf = b""
    while True:
        d = c.recv(65536)
        if not d:
            break
        buf += d
        while b"\r\n\r\n" in buf:
            head, buf = buf.split(b"\r\n\r\n", 1)
            path = head.split(b" ")[1]
            if path.startswith(b"/chunked"):
                c.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\nX-T: 1\r\n\r\n")
            elif path.startswith(b"/eof"):
                c.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nuntil-eof")
                c.close()
                return
            elif path.startswith(b"/len"):
                c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc")
            elif path.startswith(b"/nolen"):
                c.sendall(b"HTTP/1.0 200 OK\r\n\r\nold-style")
                c.close()
                return
            elif path.startswith(b"/drop"):
                c.close()
                return
    c.close()


while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
