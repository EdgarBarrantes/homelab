#!/usr/bin/env python3
# Run by NetAlertX's entrypoint among its start checks (mounted as
# /entrypoint.d/38-lab-settings.py), as NetAlertX's user, before its server
# starts. Writes the settings the homelab decides into app.conf at every
# start, over whatever was saved in the UI (the UI's login check reads
# app.conf itself, so APP_CONF_OVERRIDE isn't enough):
# - scan only the LAN NET_IFACE is on (NetAlertX's own guess also scans
#   Docker's bridges, VPNs and VM bridges);
# - the UI asks for NETALERTX_PASSWORD (stored as its SHA-256, as NetAlertX
#   does itself);
# - new devices, and devices marked "alert when down", are pushed to ntfy's
#   homelab-alerts topic when NTFY_PUBLISH_TOKEN is set (copied by render
#   when the ntfy stack is enabled).
import ast
import hashlib
import ipaddress
import os
import re
import subprocess
import sys

CONF = os.path.join(os.environ["NETALERTX_CONFIG"], "app.conf")
iface, domain = os.environ["NET_IFACE"], os.environ["DOMAIN"]

out = subprocess.run(["ip", "-4", "-o", "addr", "show", "dev", iface],
                     capture_output=True, text=True).stdout.split()
if "inet" not in out:
    sys.exit(f"lab settings: {iface} (NET_IFACE) has no IPv4 address")
lan = ipaddress.ip_interface(out[out.index("inet") + 1]).network

settings = {
    "SCAN_SUBNETS": [f"{lan} --interface={iface}"],
    "TIMEZONE": os.environ["TZ"],
    "SETPWD_enable_password": True,
    "SETPWD_password": hashlib.sha256(os.environ["NETALERTX_PASSWORD"].encode()).hexdigest(),
    "REPORT_DASHBOARD_URL": f"https://devices.{domain}",
    "NTFPRCS_INCLUDED_SECTIONS": ["new_devices", "down_devices"],
}

with open(CONF) as f:
    lines = f.read().splitlines()


def current(key):
    for line in lines:
        if line.startswith(key + "="):
            return ast.literal_eval(line.split("=", 1)[1].split("#")[0].strip())
    return None


plugins = current("LOADED_PLUGINS") or []
token = os.environ.get("NTFY_PUBLISH_TOKEN", "")
if token:
    settings |= {"NTFY_RUN": "on_notification", "NTFY_HOST": f"https://ntfy.{domain}",
                 "NTFY_TOPIC": "homelab-alerts", "NTFY_TOKEN": token, "NTFY_PRIORITY": "default"}
    settings["LOADED_PLUGINS"] = plugins + ["NTFY"] if "NTFY" not in plugins else plugins
else:
    settings |= {"NTFY_RUN": "disabled", "NTFY_TOKEN": ""}

for key, value in settings.items():
    new = f"{key}={value!r}"
    pattern = re.compile(rf"^{key}\s*=")
    for i, line in enumerate(lines):
        if pattern.match(line):
            lines[i] = new
            break
    else:
        lines.append(new)

with open(CONF + ".tmp", "w") as f:
    f.write("\n".join(lines) + "\n")
os.replace(CONF + ".tmp", CONF)
print(f"lab settings: scanning {lan} on {iface}, login on, "
      f"ntfy {'on' if token else 'off'}")
