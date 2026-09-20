# Backup and restore

## What is captured

`scripts/backup.sh` writes one timestamped snapshot directory containing:

| Contents | Source | Path in the snapshot |
|---|---|---|
| Uploaded files | `mc mirror` from the MinIO bucket | `minio/` |
| Database | `mongodump --archive --gzip` | `mongo.archive.gz` |
| Configuration | `.env`, `compose.yml`, `nginx/`, `certs/` | `config/` |
| Provenance | versions, domain, mode, capture order | `MANIFEST` |

The database dump covers all Rocket.Chat data: messages, accounts, channels,
permissions, settings, and the metadata rows that point at uploaded files.

## Consistency: the honest version

**These snapshots are not atomic.** Object storage and the database are captured
seconds to minutes apart, and activity in that window lands in one but not the
other.

The ordering is chosen so the inconsistency falls the harmless way:

```
objects first, then the database
```

A file uploaded during the window ends up as an object with no metadata row.
Nothing references it, so it is invisible to users — wasted space, no more.

Captured in the other order, the same upload produces a metadata row with no
object: a message showing an attachment that cannot be downloaded. That is a
visible defect that looks like data corruption to whoever hits it.

**To eliminate the window entirely** you need a point-in-time snapshot beneath
both stores at once: an LVM snapshot, a ZFS or Btrfs snapshot of the Docker
data root, or a hypervisor-level volume snapshot. Stop Rocket.Chat, take the
filesystem snapshot, start it again, then back up from the snapshot at leisure.
That is a few seconds of downtime for genuine consistency, and it is worth it
for a busy instance.

For most deployments the window is small enough not to matter. Know that it
exists rather than discovering it.

## Retention

`RC_BACKUP_KEEP_DAILY` (default 7) most recent snapshots, plus
`RC_BACKUP_KEEP_WEEKLY` (default 4) Sunday snapshots. Weeklies matter for the
failure you notice late: a corruption or a bad deletion from eleven days ago is
unrecoverable from seven daily snapshots alone.

Objects are hardlinked against the previous snapshot where the `hardlink`
utility is available, so unchanged files cost no additional space. Without it
each snapshot is a full copy — check `du -sh` on the backup directory after a
week and install `hardlink` if the growth is uncomfortable.

## Scheduling

Set up at install time as either systemd timers or `/etc/cron.d/rocketchat`,
depending on what you chose:

```bash
systemctl list-timers 'rocketchat-*'     # systemd
cat /etc/cron.d/rocketchat               # cron
```

With `RC_SCHEDULE=none`, nothing is scheduled and `backup.sh` must be driven by
whatever you already use.

## Off-site copies

**A backup on the same machine is not a backup.** It does not survive disk
failure, theft, fire, ransomware, or `rm -rf` on the wrong path. `backup.sh`
prints this reminder after every run and does not configure it for you, because
where your data is allowed to go is your decision, not this script's.

Options, roughly in order of how many people use them:

```bash
# Another machine you control
rsync -az --delete /opt/rocketchat/backups/ backup-host:/srv/rocketchat/

# Object storage (Backblaze B2, Wasabi, S3, anything rclone speaks)
rclone sync /opt/rocketchat/backups remote:rocketchat-backups

# An external disk, mounted for the duration
mount /dev/sdb1 /mnt/backup && rsync -a /opt/rocketchat/backups/ /mnt/backup/
```

Snapshots contain `.env`, which holds credentials in plaintext. Encrypt before
sending anywhere you do not fully control — `rclone` with a `crypt` remote, or
`age`/`gpg` over a tarball.

Whatever you choose, add it to the schedule immediately after `backup.sh`, and
verify at the destination rather than trusting the exit code at the source.

## Restore

```bash
./scripts/restore.sh
```

Lists the snapshots with their manifests, asks which one, then requires you to
type the domain name — a reflexive "y" should not be able to destroy an
instance.

What it does:

1. Takes a safety backup of the **current** state first, so a mistaken restore
   is itself recoverable.
2. Stops Rocket.Chat. MongoDB and MinIO stay up, since both are being written
   to.
3. `mongorestore --drop` from the snapshot.
4. `mc mirror --overwrite --remove` from the snapshot. The `--remove` is
   deliberate: without it, files uploaded after the snapshot survive as orphans
   that no database row points at, consuming space forever.
5. Starts Rocket.Chat and runs the health check.

Non-interactively:

```bash
./scripts/restore.sh --snapshot 20260920-030000
```

**Everything after the snapshot is lost** — messages, uploads, accounts. That
is what a restore is.

## Verifying a backup

A backup that has never been restored is a hypothesis. Test it somewhere that
is not production:

```bash
# On a second machine, or the same one with a different project name and ports
sudo ./install.sh --data-dir /opt/rocketchat-test \
  --project-name rctest --mode plain-http \
  --http-port 8080 --domain localhost \
  --firewall none --schedule none

cp -a /opt/rocketchat/backups/20260920-030000 /opt/rocketchat-test/backups/
cd /opt/rocketchat-test && ./scripts/restore.sh --snapshot 20260920-030000
```

Then check, in this order:

1. Log in as an existing user — proves the accounts collection restored
2. Read history in a busy channel — proves messages restored
3. **Open a file attachment** — proves objects and metadata agree

Step 3 is the one that catches a partial restore. Message history restores from
the database alone and looks completely fine while every attachment is broken.

## Restoring onto a different host

The snapshot's `config/env` carries the MinIO credentials the objects were
written with, so the new host must use the same ones:

1. Install the stack on the new host but do not create data yet.
2. Copy `RC_MINIO_ROOT_USER`, `RC_MINIO_ROOT_PASSWORD`, `RC_MINIO_ACCESS_KEY`
   and `RC_MINIO_SECRET_KEY` from `config/env` into the new `.env`.
3. `docker compose up -d` so `minio-init` creates the user with those keys.
4. Run the restore.

If the domain differs, update `RC_DOMAIN` and `RC_ROOT_URL` and re-run
`scripts/setup.sh`. Rocket.Chat also stores `Site_Url` in the database, which
the restore brings along — fix it in Admin → Settings → General, or clients will
be redirected to the old hostname.
