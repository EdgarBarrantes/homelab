#!/bin/sh
# Every WATCH_INTERVAL seconds, asks Home Assistant (HA_URL) for its
# manifest. After WATCH_DOWN_AFTER failures in a row, publishes "down" to
# ntfy; when it answers again, "back". Without HA_URL it just idles.
set -u
[ -n "${HA_URL:-}" ] || { echo "HA_URL not set: nothing to watch"; exec sleep 2147483647; }
fails=0; down=0; since=""
# send <title> <tags> <priority> <message>
# Plain HTTP to the local server: the ntfy CLI can resolve a short host
# like http://ntfy to the public ntfy.sh instead.
send() {
  if wget -q -T 10 -O /dev/null --header "Authorization: Bearer $NTFY_TOKEN" \
      --header "Title: $1" --header "Tags: $2" --header "Priority: $3" \
      --post-data "$4" "$NTFY_URL/$NTFY_TOPIC"; then echo "sent: $1"
  else echo "publish failed: $1"; return 1; fi
}
echo "watching $HA_URL every ${WATCH_INTERVAL}s, alert after $WATCH_DOWN_AFTER failures"
while true; do
  if wget -q -T 10 -O /dev/null "$HA_URL/manifest.json" 2>/dev/null; then
    if [ "$down" = 1 ]; then
      send "Home Assistant is back" white_check_mark default "Answering again at $(date '+%H:%M') (down since $since)."
    fi
    fails=0; down=0
  else
    fails=$((fails + 1))
    [ "$fails" = 1 ] && since="$(date '+%H:%M')"
    if [ "$fails" -ge "$WATCH_DOWN_AFTER" ] && [ "$down" = 0 ]; then
      send "Home Assistant is down" warning high \
        "No answer from $HA_URL since $since. Its own alerts can't reach you until it's back." \
        && down=1   # retried next check if the publish failed
    fi
  fi
  sleep "$WATCH_INTERVAL"
done
