# Sourced by tests/vm.sh verify when calibre-web is installed (ssh_vm and
# the other harness helpers are available). Return non-zero to fail.
# The import folder: a book copied in leaves the folder and lands in the
# library. Copied in whole (never written in place), as CWA expects.
ssh_vm 'source <(grep "^BOOKS" homelab/homelab.env); mkdir -p ~/tmp && cat > ~/tmp/t.epub && mv ~/tmp/t.epub "$BOOKS_IMPORT_DIR/import-test.epub"
  for _ in $(seq 1 60); do
    [[ ! -e "$BOOKS_IMPORT_DIR/import-test.epub" ]] && find "$BOOKS_DIR" -path "*Homelab Import Test*" -name "*.epub" | grep -q . && exit 0
    sleep 5
  done; exit 1' < "$HERE/fixtures/import-test.epub" && echo "  book import folder: ok"
