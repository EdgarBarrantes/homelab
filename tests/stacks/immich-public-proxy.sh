# Sourced by tests/vm.sh verify when immich-public-proxy is installed: shared
# links made in Immich behave the same on the public pages. A link that allows
# downloads gets the "download all" button and a zip; one that doesn't gets
# neither; a password link shows the password page until unlocked.
# Same admin as tests/restore-test.sh (whichever signs up first).
ssh_vm 'python3 -' <<'PY' && echo "  immich-public-proxy (download per link, password): ok"
import http.cookiejar, json, struct, time, urllib.request, uuid, zlib

IMMICH, IPP = "http://127.0.0.1:2283/api", "http://127.0.0.1:3000"

def req(url, data=None, headers={}, opener=urllib.request.urlopen):
    r = urllib.request.Request(url, data=data, headers=headers)
    with opener(r, timeout=60) as resp:
        return resp.headers.get("Content-Type", ""), resp.read()

def api(path, body, token=None):
    h = {"Content-Type": "application/json"}
    if token: h["Authorization"] = "Bearer " + token
    try:
        return json.loads(req(IMMICH + path, json.dumps(body).encode(), h)[1] or b"{}")
    except urllib.error.HTTPError as e:
        if path.endswith("admin-sign-up"): return {}  # already signed up
        raise SystemExit(f"{path}: {e.code} {e.read()[:200]}")

def png(rgb):  # a 64x64 solid-colour PNG, stdlib only
    raw = b"".join(b"\0" + bytes(rgb) * 64 for _ in range(64))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")

for _ in range(60):
    try: req(IMMICH + "/server/ping"); break
    except Exception: time.sleep(5)
api("/auth/admin-sign-up", {"email": "restore@test.local", "password": "RestoreTest123", "name": "Restore Test"})
token = api("/auth/login", {"email": "restore@test.local", "password": "RestoreTest123"})["accessToken"]

ids = []
for i, (rgb, when) in enumerate([((200, 60, 60), "2026-05-03"), ((60, 160, 90), "2026-06-14"), ((60, 90, 200), "2026-06-20")]):
    b = uuid.uuid4().hex
    fields = {"deviceAssetId": f"ipp-test-{i}", "deviceId": "vm-test",
              "fileCreatedAt": when + "T10:00:00.000Z", "fileModifiedAt": when + "T10:00:00.000Z"}
    body = b"".join(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields.items())
    body += f'--{b}\r\nContent-Disposition: form-data; name="assetData"; filename="ipp-{i}.png"\r\nContent-Type: image/png\r\n\r\n'.encode()
    body += png(rgb) + f"\r\n--{b}--\r\n".encode()
    ids.append(json.loads(req(IMMICH + "/assets", body, {"Authorization": "Bearer " + token,
        "Content-Type": "multipart/form-data; boundary=" + b})[1])["id"])  # a duplicate returns the existing id

def link(**kw):
    return api("/shared-links", {"type": "INDIVIDUAL", "assetIds": ids, "showMetadata": True, **kw}, token)["key"]

ok, no, pw = link(allowDownload=True), link(allowDownload=False), link(allowDownload=True, password="vm-secret")

_, page = req(f"{IPP}/share/{ok}")
assert b'id="download-all"' in page, "download allowed: no download-all button"
ctype, z = req(f"{IPP}/share/{ok}/download")
assert z[:2] == b"PK", f"download allowed: no zip ({ctype})"

_, page = req(f"{IPP}/share/{no}")
assert b'id="download-all"' not in page, "download off: button shown"
ctype, body = req(f"{IPP}/share/{no}/download")
assert body[:2] != b"PK", "download off: zip served anyway"

jar = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())).open
_, page = req(f"{IPP}/share/{pw}", opener=jar)
assert b'id="download-all"' not in page and b"password" in page.lower(), "password link: gallery without password"
req(f"{IPP}/share/unlock", json.dumps({"key": pw, "password": "vm-secret"}).encode(),
    {"Content-Type": "application/json"}, opener=jar)
_, page = req(f"{IPP}/share/{pw}", opener=jar)
assert b'id="download-all"' in page, "password link: not unlocked"
PY
