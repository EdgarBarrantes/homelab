# Sourced by tests/vm.sh verify when kiwix is installed (ssh_vm and the
# other harness helpers are available). Return non-zero to fail.
# A one-page ZIM, built here with python-libzim (no dated file to download),
# is picked up by a restart, served under its dateless URL and found by
# full-text search.
ssh_vm 'cd homelab && source <(grep "^ZIM_DIR=" homelab.env)
  docker run --rm -i -v "$ZIM_DIR":/out python:3.12-slim sh -c \
    "pip install -q --root-user-action=ignore libzim==3.7.0 && python - && chown $(id -u):$(id -g) /out/*.zim" || exit 1
  ./lab restart kiwix >/dev/null
  get() { docker exec kiwix wget -q -O - "http://localhost:8080$1"; }
  for _ in $(seq 1 30); do get /content/homelab-test_en/home 2>/dev/null | grep -q kiwixcanary && break; sleep 2; done
  get /content/homelab-test_en/home | grep -q kiwixcanary &&
    get "/search?books.name=homelab-test_en&pattern=kiwixcanary" | grep -q "Homelab test page"' <<'EOF' && echo "  kiwix (ZIM served, dateless URL, full-text search): ok"
from libzim.writer import Creator, Item, StringProvider, Hint

class Page(Item):
    def get_path(self): return "home"
    def get_title(self): return "Homelab test page"
    def get_mimetype(self): return "text/html"
    def get_contentprovider(self):
        return StringProvider("<html><head><title>Homelab test page</title></head>"
                              "<body><p>kiwixcanary offline library check</p></body></html>")
    def get_hints(self): return {Hint.FRONT_ARTICLE: True}

with Creator("/out/homelab-test_en_2026-01.zim").config_indexing(True, "eng") as c:
    c.set_mainpath("home")
    c.add_item(Page())
    for k, v in {"Name": "homelab-test_en", "Title": "Homelab test", "Language": "eng",
                 "Creator": "homelab", "Publisher": "homelab", "Date": "2026-01-01",
                 "Description": "VM test"}.items():
        c.add_metadata(k, v)
EOF
