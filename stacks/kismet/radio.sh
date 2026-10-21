#!/bin/sh
# Host side of the kismet stack: moves each KISMET_SOURCE adapter's radio
# into the kismet container's network namespace (found by its
# LAB_KISMET_RADIO=1 marker), so Kismet sees that adapter and nothing else.
# Refused, always: an adapter that isn't on USB (a built-in card), one that
# isn't Wi-Fi, and one this machine is online through (an IPv4 address or
# the default route). Checks every 5 s, so a restarted Kismet or a
# re-plugged adapter gets it again; the kernel returns the radio to the host
# when the kismet container stops.
set -u
log() { echo "kismet-radio: $*"; }
[ -n "${KISMET_SOURCE:-}" ] || { log "no KISMET_SOURCE set: nothing to hand over"; exec sleep infinity; }

refusal() { # why interface $1 may not be handed over (empty = it may)
  case "$(readlink -f "/sys/class/net/$1/device")" in
    */usb[0-9]*) ;;
    *) echo "not a USB adapter (built-in cards are never used)"; return ;;
  esac
  [ -e "/sys/class/net/$1/phy80211" ] || { echo "not a Wi-Fi interface"; return; }
  if [ -n "$(ip -4 -o addr show dev "$1")" ] || ip route show default | grep -q " dev $1 "; then
    echo "this machine is online through it"
  fi
}

kismet_pid() { # a process of the kismet container
  for e in /proc/[0-9]*/environ; do
    if { tr '\0' '\n' < "$e"; } 2>/dev/null | grep -qx LAB_KISMET_RADIO=1; then
      e="${e#/proc/}"; echo "${e%/environ}"; return 0
    fi
  done
  return 1
}

said=""
say_once() { [ "$said" = "$*" ] || { log "$*"; said="$*"; }; }

while :; do
  for i in $KISMET_SOURCE; do
    [ -e "/sys/class/net/$i" ] || continue # with Kismet already, or unplugged
    why="$(refusal "$i")"
    if [ -n "$why" ]; then say_once "refusing $i: $why"; continue; fi
    pid="$(kismet_pid)" || continue
    phy="$(cat "/sys/class/net/$i/phy80211/name")"
    # Leftover monitor interfaces of a hard-stopped Kismet would move along.
    for n in /sys/class/ieee80211/"$phy"/device/net/*; do
      n="${n##*/}"
      [ "$n" != "$i" ] || continue
      if iw dev "$n" info 2>/dev/null | grep -q "type monitor"; then iw dev "$n" del && log "removed leftover $n"; fi
    done
    if iw phy "$phy" set netns "$pid"; then said=""; log "handed $i ($phy) to Kismet"
    else say_once "could not hand $i ($phy) to Kismet"; fi
  done
  sleep 5
done
