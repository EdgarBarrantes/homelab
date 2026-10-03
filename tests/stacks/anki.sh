# Sourced by tests/vm.sh verify when anki is installed: the generated
# password logs in (a wrong one doesn't), one "device" uploads a card and
# a second one downloads it, with Anki's own client code.
ssh_vm 'cd homelab && source <(grep "^ANKI_PASSWORD=" stacks/anki/.env)
  docker exec -e PW="$ANKI_PASSWORD" anki python -c "
import os, tempfile
from anki.collection import Collection
url, pw = \"http://localhost:8080/\", os.environ[\"PW\"]
d = tempfile.mkdtemp()
c = Collection(d + \"/a.anki2\")
try:
    c.sync_login(\"me\", \"wrong\", url)
    raise SystemExit(\"wrong password accepted\")
except Exception as e:
    assert type(e).__name__ == \"SyncError\", e
a = c.sync_login(\"me\", pw, url)
n = c.new_note(c.models.by_name(\"Basic\")); n[\"Front\"] = \"vm-test\"; c.add_note(n, c.decks.id(\"Default\"))
out = c.sync_collection(a, False)
c.full_upload_or_download(auth=a, server_usn=out.server_media_usn, upload=True)
c2 = Collection(d + \"/b.anki2\")
out = c2.sync_collection(a, False)
c2.full_upload_or_download(auth=a, server_usn=out.server_media_usn, upload=False)
assert c2.find_notes(\"front:vm-test\"), \"card did not come back\"
"' && echo "  anki (login, sync round trip): ok"
