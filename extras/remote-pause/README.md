# Pause from Home Assistant ("desktop mode")

When the server doubles as a desktop, the heavy services (GPU and CPU:
Ollama, Immich ML, OCR, speech) can be stopped and started again from a
Home Assistant switch, the phone or a voice command. HA runs
`lab-remote.sh` on this machine over SSH with a key that can do nothing
else:

- `pause`: `lab pause` (stops containers labelled `lab.tier: heavy`)
- `resume`: `lab resume` (starts everything enabled again)
- `status`: prints `paused` when no heavy container runs, else `running`
- `doctor`: `lab doctor` as one JSON line (`bad`, `warn`, `problems`,
  `paused`), for a health sensor; while paused, the stopped heavy
  containers don't count as problems. Also `reboot` (the OS's "reboot
  required" flag after updates), `reboot_since` and `reboot_pkgs`

- `screen`: brightness and volume of the desktop session as one JSON
  line (`{"brightness": 38, "volume": 60, "muted": false}`)
- `brightness <0-100>`: screen brightness (0 is the dimmest, never off);
  through COSMIC's settings daemon, so its own slider follows
- `volume <0-100>`: output volume of the default sink (PipeWire)

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

   A health sensor from the same key (state = number of problems):

   ```yaml
   command_line:
     - sensor:
         name: Server doctor
         command: >-
           ssh -i /config/.ssh/lab_remote -o BatchMode=yes
           -o UserKnownHostsFile=/config/.ssh/known_hosts_lab you@<server-lan-ip> doctor
         value_template: "{{ value_json.bad }}"
         json_attributes: [warn, problems, paused, reboot, reboot_since, reboot_pkgs]
         scan_interval: 900
   ```

   The switch is on while paused. `scan_interval` keeps the state check
   to one SSH login every 5 minutes.

   Brightness and volume as dropdowns (a sensor for the current values,
   a shell command to set them, and two template selects):

   ```yaml
   command_line:
     - sensor:
         name: Server screen
         command: >-
           ssh -i /config/.ssh/lab_remote -o BatchMode=yes
           -o UserKnownHostsFile=/config/.ssh/known_hosts_lab you@<server-lan-ip> screen
         value_template: "{{ value_json.brightness }}"
         unit_of_measurement: "%"
         json_attributes: [volume, muted]
         scan_interval: 300
   shell_command:
     server_screen: >-
       ssh -i /config/.ssh/lab_remote -o BatchMode=yes
       -o UserKnownHostsFile=/config/.ssh/known_hosts_lab you@<server-lan-ip> {{ what }} {{ level }}
   ```

Note: with the speech stack paused, HA's voice pipeline can't transcribe,
so "turn off desktop mode" by voice won't work while it's on; use the
switch, a dashboard or a phone widget for that.
