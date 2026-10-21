#!/bin/sh
# Writes Kismet's login (user "kismet", KISMET_PASSWORD) and site settings,
# waits for kismet-radio to hand over each KISMET_SOURCE adapter (this
# container's network namespace has no other Wi-Fi), then runs Kismet,
# hopping over KISMET_CHANNELS (default: every channel and width the adapter
# offers). Data frames are never logged (only management frames and device
# summaries); logs older than KISMET_KEEP_DAYS are deleted here.
set -eu

sources=""
for i in ${KISMET_SOURCE:-}; do
  n=0
  until [ -e "/sys/class/net/$i" ]; do
    n=$((n + 1))
    [ $n -le 60 ] || { echo "kismet: $i wasn't handed over (./lab logs kismet kismet-radio says why)"; exit 1; }
    sleep 1
  done
  opts="name=$i"
  [ -z "${KISMET_CHANNELS:-}" ] || opts="$opts,channels=\"$KISMET_CHANNELS\""
  sources="$sources
source=$i:$opts"
done
[ -n "$sources" ] || echo "kismet: no KISMET_SOURCE set: running without a capture source"

# Monitor interfaces Kismet made on the adapters: it removes them when it
# closes normally; without this a hard stop would leave them to the host.
cleanup() {
  for i in ${KISMET_SOURCE:-}; do
    phy="$(cat "/sys/class/net/$i/phy80211/name" 2>/dev/null)" || continue
    for n in /sys/class/ieee80211/"$phy"/device/net/*; do
      n="${n##*/}"
      [ "$n" != "$i" ] || continue
      if iw dev "$n" info 2>/dev/null | grep -q "type monitor"; then iw dev "$n" del && echo "kismet: removed $n"; fi
    done
  done
}

mkdir -p /root/.kismet
umask 077
printf 'httpd_username=kismet\nhttpd_password=%s\n' "$KISMET_PASSWORD" > /root/.kismet/kismet_httpd.conf
# randomized_hopping off: Kismet's shuffle steps 4 channels at a time, so a
# list whose length is even (38 channels, say) only ever visits half of it.
cat > /etc/kismet/kismet_site.conf <<EOF
remote_capture_enabled=false
randomized_hopping=false
log_prefix=/data
kis_log_data_packets=false$sources
EOF

find /data -maxdepth 1 -name '*.kismet*' -mtime +"${KISMET_KEEP_DAYS:-30}" -print -delete
cleanup
kismet --no-ncurses &
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null' TERM INT
wait "$pid" || true # returns early when the trap fires
wait "$pid" 2>/dev/null || true
cleanup
