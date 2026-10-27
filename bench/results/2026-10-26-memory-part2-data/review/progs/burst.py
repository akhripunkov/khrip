# burst.py PORT N SIZE PID: N concurrent clients, each GET /large/SIZE/t<i> (a
# response of SIZE bytes, slept 300 ms so they overlap), read all, close; RSS
# after 1 s idle. Then dead clients: N requests to /sleepbig/300/SIZE, closed
# with RST before the response; RSS after 1 s.
import socket, sys, time
PORT, N, SIZE, PID = map(int, sys.argv[1:5])
def rss():
    for l in open(f"/proc/{PID}/status"):
        if l.startswith("VmRSS"):
            return int(l.split()[1])
print("start", rss(), "KB")
socks = []
for i in range(N):
    s = socket.create_connection(("127.0.0.1", PORT))
    s.sendall(f"GET /sleepbig/300/{SIZE} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
    socks.append(s)
for s in socks:
    got = b""
    while b"\r\n\r\n" not in got:
        got += s.recv(65536)
    head, body = got.split(b"\r\n\r\n", 1)
    n = int([l for l in head.split(b"\r\n") if l.lower().startswith(b"content-length")][0].split(b":")[1])
    while len(body) < n:
        d = s.recv(1 << 20)
        if not d:
            break
        body += d
for s in socks:
    s.close()
time.sleep(1.0)
print("after normal burst", rss(), "KB")
socks = []
for i in range(N):
    s = socket.create_connection(("127.0.0.1", PORT))
    s.sendall(f"GET /sleepbig/300/{SIZE} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
    socks.append(s)
time.sleep(0.05)
for s in socks:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
    s.close()
time.sleep(1.0)
print("after dead-client burst", rss(), "KB")
