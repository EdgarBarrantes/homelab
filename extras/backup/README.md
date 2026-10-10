# Backups

Nightly, by a systemd timer (not a container, and not Backrest: one
scheduler, the most reliable one on the machine). Set `BACKUP_TARGET` to
`local` or `smb` in `homelab.env` (the wizard asks), then
`./install.sh --backup` (the normal install does it too).

What it backs up, from each enabled stack's `stack.conf`:

| What | How | Kept |
|---|---|---|
| Postgres (Immich, Paperless) | `pg_dumpall` to dated `.sql.gz` in `db-dumps/` | `BACKUP_RETAIN_DAYS` (14) |
| Actual Budget | export via its HTTP wrapper, dated `.zip` (needs `ACTUAL_BUDGET_SYNC_ID`) | same |
| Photos, Paperless media, books, Calibre-Web, Gokapi, Open WebUI and Backrest data | restic snapshots in `restic-repo/`, deduplicated | 7 daily, 4 weekly, 6 monthly (per machine) |
| Config: `homelab.env`, every `.env`, the private overlay, `/etc/cloudflared`, Syncthing's identity, the Ollama model list | in the same snapshot (the repository is encrypted) | same |

Every Sunday it also reads back 5% of the repository (`restic check
--read-data-subset=5%`), so restores are tested, not only writes.

## Drill: do the backups really restore?

```bash
./lab backup drill                    # the backup target and the off-site copy
./lab backup drill --from offsite     # only one of them (primary | offsite)
./lab backup drill --files 20         # more sample files (default 5)
```

Read-only: nothing in the backups or the running stacks changes. For each
repository it takes the newest snapshot, restores a few random files that
haven't changed since then into a scratch folder in `/var/tmp` and
compares them with the live ones, and loads every stack's newest
database dump into a throwaway Postgres (the stack's own image, no
network) to compare its databases and table counts with the live ones.
It ends with a summary: what it read, how long it took, how fast (which
also tells you how long a full restore from that copy would take). Worth
doing after setting up backups, after moving them, and a few times a
year.

Files it creates: `/etc/homelab/restic-password` (generated; **save a copy
in your password manager**, the backups are useless without it),
`/etc/homelab/smb-credentials` (SMB only), the units in
`/etc/systemd/system/homelab-backup*` and, for SMB, a `.mount`/`.automount`
pair for `BACKUP_DIR`. Log: `/var/log/homelab-backup.log`.

It only ever writes `db-dumps/` and `restic-repo/` inside `BACKUP_DIR`,
and its only delete is the age-based prune inside `db-dumps/`, so the
target can hold other files.

```
./lab backup now       run one now
./lab backup status    timer, next run, last result
./lab backup log       follow the log
```

## Failure alerts

Set `BACKUP_NOTIFY_URL` in `extras/backup/.env` to anything that accepts a
JSON POST with `title` and `message`. With Home Assistant, a webhook
automation keeps any HA token off the server:

```yaml
alias: Backup failed
triggers:
  - trigger: webhook
    webhook_id: <long-random-id>
    allowed_methods: [POST]
    local_only: true
actions:
  - action: notify.mobile_app_<your_phone>
    data:
      title: "{{ trigger.json.title }}"
      message: "{{ trigger.json.message }}"
```

and `BACKUP_NOTIFY_URL=http://<ha-lan-ip>:8123/api/webhook/<long-random-id>`.
Test it: `sudo systemctl start homelab-backup-failed.service`.

## Missed-backup alerts (dead man's switch)

A failure alert can't fire when nothing runs at all (timer stopped, machine
off). Set `BACKUP_HEARTBEAT_URL` in `extras/backup/.env` and every
successful run POSTs `{"host", "status": "ok", "snapshot", "checked",
"offsite"}` there (`checked` is true after the Sunday `restic check`;
`offsite` is `ok`, `failed` or `off`, see below). Point it at a
push monitor (healthchecks.io, Uptime Kuma) or at a second Home Assistant
webhook that records the time, plus an hourly check that alerts when it
gets old:

```yaml
automation:
  - alias: Backup heartbeat
    triggers:
      - trigger: webhook
        webhook_id: <another-long-random-id>
        allowed_methods: [POST]
        local_only: true
    actions:
      - event: homelab_backup_ok
  - alias: Backup overdue
    triggers:
      - trigger: time_pattern
        minutes: 7
    conditions:
      - condition: template
        value_template: >-
          {{ now() - (states('sensor.homelab_backup_last_success')
             | as_datetime(now() - timedelta(days=99))) > timedelta(hours=36) }}
    actions:
      - action: notify.mobile_app_<your_phone>
        data:
          message: No successful backup for over 36 hours.
template:
  - triggers:
      - trigger: event
        event_type: homelab_backup_ok
    sensor:
      - name: Homelab backup last success
        device_class: timestamp
        state: "{{ now().isoformat() }}"
```

## Off-site copy

A backup target in the same building shares its fate (fire, theft, a
surge). `BACKUP_OFFSITE` in homelab.env names a second restic repository
that every run fills with `restic copy` after the local backup: a separate
repository, not a mirror of the folder, so damage or deletions in the
local one don't spread. It uses the same password, keeps the same
retention, is checked on Sundays and pruned on the 1st of the month. The
database dumps are part of every snapshot, so they go along.

Any restic backend works; for cloud storage you already pay for, use
rclone. With Google Drive:

1. Install rclone (the official .deb from rclone.org; distro packages are
   often too old) and create your own OAuth client in Google Cloud Console
   (Drive API on, consent screen published to *Production*: in "Testing"
   the login expires after 7 days; client type *Desktop app*).
2. As yourself: `rclone config`, a remote named `gdrive`, type `drive`,
   your client id and secret, scope `drive.file` (rclone only sees what it
   creates), browser login. Test: `rclone mkdir gdrive:homelab`.
3. Hand it to root, which runs the backups, and keep one copy only:
   `sudo install -m 600 -o root -g root ~/.config/rclone/rclone.conf /etc/homelab/rclone.conf`
   then `rm ~/.config/rclone/rclone.conf`.
4. In homelab.env: `BACKUP_OFFSITE=rclone:gdrive:homelab/restic` and,
   optionally, `BACKUP_OFFSITE_LIMIT_KBPS=1500` (about 12 Mbit/s) so the
   first upload, which carries everything, leaves room for other traffic.
   Later runs only send what changed.

The folder in Drive holds encrypted pack files, not browsable copies.
Reading it back, e.g. after losing the local target:

```bash
sudo RCLONE_CONFIG=/etc/homelab/rclone.conf restic \
  -r rclone:gdrive:homelab/restic --password-file /etc/homelab/restic-password snapshots
```

then `restic restore` as usual (the dumps are under the backup folder's
`db-dumps/` path inside the snapshot).

## Rebuilding a machine from its backups

When the disk is gone and only the backups and the restic password (from
your password manager) are left:

```bash
git clone https://github.com/<you>/homelab.git ~/homelab && cd ~/homelab
./install.sh --from-backup //192.168.1.1/Backup     # or a local folder
```

It mounts the backups, asks for the restic password, puts your config back
from the newest snapshot (`homelab.env`, every `.env`, the private overlay,
the tunnel credentials, Syncthing's identity; folders under another user's
home are moved to yours), installs Docker if needed, starts every stack,
restores the data from that same snapshot, pulls the Ollama models again,
and only then enables the nightly timer. `--snapshot ID` picks an older
one. Still by hand afterwards: `tailscale up`, importing the Actual export
(below) and re-linking the bank in Actual.

## Restoring (or moving to a new machine)

`./lab restore` brings everything back into the stacks enabled on this
machine: the files from a restic snapshot and each database from its dump.

On a new machine:

1. Install with the same stacks and point backups at the old target (the
   wizard's backup question, e.g. `smb`, `//192.168.1.1/Backup`,
   `/mnt/backup`). When the installer finds an existing repository it asks
   for **its restic password** (from your password manager) instead of
   making a new one.
2. Look before you leap:
   ```bash
   ./lab restore --dry-run
   ```
   It shows the snapshot it will use (newest, from any machine), each
   snapshot path and where it goes here, and which database dumps it
   picked (newest on or before the snapshot's day). Paths are matched by
   their tail, so a snapshot from another machine with other folders still
   lines up (`.../paperless-ngx/data/media`, `.../Immich`,
   `.../Calibre Library`). Anything it can't place is listed with the
   `--map` to use.
3. Restore:
   ```bash
   ./lab restore                         # asks before changing anything
   ./lab restore --snapshot 43de7880     # a specific snapshot
   ./lab restore --date 2026-09-01       # dumps from that day or earlier
   ./lab restore --only immich,paperless-ngx
   ./lab restore --map /old/path=/new/path
   ./lab restore --from offsite          # from the off-site copy instead
   ```
   For each stack it stops the stack, restores the files, moves the fresh
   database folder aside (`<folder>.pre-restore-<time>`, delete it once
   you're happy), loads the dump into a clean Postgres, resets the
   database password to this machine's generated one, and starts the stack
   again. Stacks are restored side by side like `lab up` (one line per
   stack, logs in `rendered/restore-logs/`; `--serial` for one after
   another with live output). Paperless's search index is rebuilt
   afterwards. The backup timer is paused meanwhile.

   `--from offsite` reads the off-site copy (`BACKUP_OFFSITE`, e.g. Google
   Drive through rclone with `/etc/homelab/rclone.conf`) when the backup
   target itself is gone: same snapshots, and the dumps come out of the
   snapshot, so `--date` can only pick days still kept there (7 daily, 4
   weekly, 6 monthly).
4. Actual Budget: the export is copied to `restore/`; import it in Actual
   (Files > Import file > Actual), then set its Sync ID with
   `./lab config actual-budget ACTUAL_BUDGET_SYNC_ID`.

Config only: `./lab restore --config` puts back the `.env` files, the
overlay and the rest of the config from a snapshot, skipping anything that
already exists here.

Not in the backups (by design): Ollama models themselves (the list is;
`--from-backup` pulls them), Homepage and Caddy config (generated),
certificates (Caddy gets new ones).

### By hand

```bash
sudo -i
export RESTIC_PASSWORD_FILE=/etc/homelab/restic-password
restic -r /mnt/backup/restic-repo snapshots
restic -r /mnt/backup/restic-repo restore latest:/home/you/Pictures/Immich --target /home/you/Pictures/Immich
gunzip -c /mnt/backup/db-dumps/paperless-2026-01-01.sql.gz | docker exec -i paperless_db psql -U paperless -d postgres
```

Or browse and restore single files in Backrest (`backrest.` hostname):
add the repository at `/repos/main` with the same password.
