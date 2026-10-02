# Pause from Home Assistant ("desktop mode")

When the server doubles as a desktop, the heavy services (GPU and CPU:
Ollama, Immich ML, OCR, speech) can be stopped and started again from a
Home Assistant switch, the phone or a voice command. HA runs
`lab-remote.sh` on this machine over SSH with a key that can do nothing
else:

- `pause`: `lab pause` (stops containers labelled `lab.tier: heavy`)
- `resume`: `lab resume` (starts everything enabled again)
- `status`: prints `paused` when no heavy container runs, else `running`

Every pause and resume is logged in `~/.local/state/lab-remote.log`.

## Setup

1. On the HA machine, a key just for this (HA OS: in the SSH add-on, so it
   lands in `/config/.ssh`, which HA's own container sees):

   ```bash
   mkdir -p /config/.ssh
   ssh-keygen -t ed25519 -N '' -C ha-desktop-mode -f /config/.ssh/lab_remote
   ssh-keyscan -t ed25519 <server-lan-ip> > /config/.ssh/known_hosts_lab
   ```

2. On the server, one line in `~/.ssh/authorized_keys` (the user that runs
   `lab`): the key, locked to this script and to HA's address, with no
   shell, terminal or forwarding:

   ```
   restrict,from="<ha-lan-ip>",command="/path/to/homelab/extras/remote-pause/lab-remote.sh" ssh-ed25519 AAAA... ha-desktop-mode
   ```

3. In HA (a package or `configuration.yaml`):

   ```yaml
   command_line:
     - switch:
         name: Desktop mode
         unique_id: lab_desktop_mode
         icon: mdi:monitor
         command_on: >-
           ssh -i /config/.ssh/lab_remote -o BatchMode=yes
           -o UserKnownHostsFile=/config/.ssh/known_hosts_lab you@<server-lan-ip> pause
         command_off: >-
           ssh -i /config/.ssh/lab_remote -o BatchMode=yes
           -o UserKnownHostsFile=/config/.ssh/known_hosts_lab you@<server-lan-ip> resume
         command_state: >-
           ssh -i /config/.ssh/lab_remote -o BatchMode=yes
           -o UserKnownHostsFile=/config/.ssh/known_hosts_lab you@<server-lan-ip> status
         value_template: "{{ value == 'paused' }}"
         command_timeout: 300
         scan_interval: 300
   ```

   The switch is on while paused. `scan_interval` keeps the state check
   to one SSH login every 5 minutes.

Note: with the speech stack paused, HA's voice pipeline can't transcribe,
so "turn off desktop mode" by voice won't work while it's on; use the
switch, a dashboard or a phone widget for that.
