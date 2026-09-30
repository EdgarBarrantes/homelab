"""Minimal stdlib Home Assistant websocket client.

Home Assistant usually runs on its own box (e.g. a Raspberry Pi). Some
settings (Assist pipelines, entity exposure/aliases, backup config, repairs)
only exist on HA's websocket API. This script runs ON the Pi, through the
SSH add-on, using the add-on's own $SUPERVISOR_TOKEN via the supervisor
proxy, so no token ever leaves the Pi:

    ssh homeassistant "python3 - '<json list of commands>'" < extras/homeassistant/hass_ws.py

Each command is a websocket message without "id", e.g.
    [{"type": "assist_pipeline/pipeline/list"}]
Prints one JSON line per command result; assist_pipeline/run also prints its
events until run-end.
"""
import base64, json, os, socket, struct, sys

def connect():
    s = socket.create_connection(("supervisor", 80), timeout=60)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET /core/websocket HTTP/1.1\r\nHost: supervisor\r\n"
               f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)
    assert b" 101 " in buf.split(b"\r\n")[0], buf[:200]
    return s

def send(s, obj):
    data = json.dumps(obj).encode()
    mask = os.urandom(4)
    n = len(data)
    hdr = bytes([0x81])
    if n < 126:
        hdr += bytes([0x80 | n])
    elif n < 65536:
        hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
    s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

def recv_exact(s, n):
    out = b""
    while len(out) < n:
        chunk = s.recv(n - len(out))
        if not chunk:
            raise EOFError
        out += chunk
    return out

def recv(s):
    msg = b""
    while True:
        b1, b2 = recv_exact(s, 2)
        n = b2 & 0x7F
        if n == 126:
            n = struct.unpack(">H", recv_exact(s, 2))[0]
        elif n == 127:
            n = struct.unpack(">Q", recv_exact(s, 8))[0]
        payload = recv_exact(s, n)
        if b1 & 0x0F == 0x9:  # ping -> ignore
            continue
        msg += payload
        if b1 & 0x80:
            return json.loads(msg)

s = connect()
assert recv(s)["type"] == "auth_required"
send(s, {"type": "auth", "access_token": os.environ["SUPERVISOR_TOKEN"]})
assert recv(s)["type"] == "auth_ok"
for i, cmd in enumerate(json.loads(sys.argv[1]), start=1):
    send(s, dict(cmd, id=i))
    while True:
        r = recv(s)
        if r.get("id") == i and r.get("type") == "result":
            print(json.dumps({"cmd": cmd["type"], "success": r["success"],
                              "result": r.get("result"), "error": r.get("error")}))
            if cmd["type"] != "assist_pipeline/run" or not r["success"]:
                break
        elif r.get("id") == i and r.get("type") == "event":
            ev = r["event"]
            print(json.dumps({"event": ev["type"], "data": ev.get("data")}))
            if ev["type"] in ("run-end", "error"):
                break
