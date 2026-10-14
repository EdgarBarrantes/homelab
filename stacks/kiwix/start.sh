#!/bin/sh
# Rebuild the library from every ZIM in /zim, then serve it. A file that
# isn't a valid ZIM (e.g. a download still in progress) is skipped.
set -e
lib=/library/library.xml
[ -w /library ] || { echo "kiwix: ./data (/library) is not writable by $(id -u):$(id -g)"; exit 1; }
rm -f "$lib.new"
n=0
for z in /zim/*.zim; do
  [ -e "$z" ] || continue
  if kiwix-manage "$lib.new" add "$z"; then n=$((n+1)); else echo "skipped (not a valid ZIM): $z"; fi
done
[ -e "$lib.new" ] || printf '<library version="20110515"></library>\n' > "$lib.new"
mv "$lib.new" "$lib"
echo "kiwix: $n ZIM file(s)"
exec kiwix-serve --port=8080 --nodatealiases --monitorLibrary --skipInvalid --library "$lib"
