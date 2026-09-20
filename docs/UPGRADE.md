# Upgrading

```bash
./scripts/supported-versions.sh      # what is still supported
./scripts/upgrade.sh --to 8.8.1
```

`upgrade.sh` checks the target against Rocket.Chat's supported-versions feed,
enforces major-version stepping, takes a backup, pulls the image while the
current version keeps serving, swaps, waits for health, and prints a rollback
path if anything goes wrong.

## Version policy

Rocket.Chat publishes a signed supported-versions feed. Running a version that
has dropped off it means no security fixes, and eventually the server begins
warning users in the interface.

The support windows are not in release order. As of 2026-09-20:

| Version | Supported until |
|---|---|
| 8.5.3 | 2027-06-30 |
| 8.8.1 | 2027-03-31 |
| 8.7.1 | 2027-02-28 |
| 8.6.2 | 2027-01-31 |

8.5.x is a medium-term support line, so it outlives releases that came after
it. For a deployment meant to run untouched, 8.5.3 is the better choice even
though it is older. For newest features, 8.8.1.

Check for yourself rather than trusting this table, which ages:

```bash
./scripts/supported-versions.sh
./scripts/supported-versions.sh 8.5.3   # exit 0 if supported
```

## Major versions cannot be skipped

Each major version runs its own database migrations and expects to start from
the one before it. Going 7.x to 9.x directly leaves the schema in a state
nothing knows how to handle.

`upgrade.sh` refuses such a jump. Step through:

```bash
./scripts/upgrade.sh --to 8.5.3     # from 7.x
# let it start fully and finish migrating, then
./scripts/upgrade.sh --to 9.0.0
```

"Finish migrating" means the application is healthy and the logs have stopped
reporting migration activity. On a large database this takes minutes, not
seconds:

```bash
docker compose logs -f rocketchat | grep -i migrat
```

## What upgrade.sh does

1. **Support check** — the target must be in the feed, or you must confirm
   explicitly.
2. **Major-version check** — refuses a skipped major; warns loudly on a
   downgrade, which Rocket.Chat does not support once the schema has moved.
3. **Backup** — a full snapshot, verified non-empty. `--skip-backup` exists and
   is a bad idea.
4. **Pull** — while the current version is still serving, so the outage is the
   restart rather than the download.
5. **Swap** — `docker compose up -d`, which recreates only what changed. A full
   `down` would stop the database and object store too, for a longer outage and
   no benefit.
6. **Verify** — waits for the healthcheck, then runs `health-check.sh`.
7. **Rollback instructions** if verification fails.

## Rolling back

If the new version comes up unhealthy:

```bash
sed -i 's/^RC_VERSION=.*/RC_VERSION=8.5.3/' .env
docker compose up -d
```

**If the database was already migrated by the new version, this is not
enough.** The old application cannot read the new schema. Restore the
pre-upgrade snapshot as well:

```bash
./scripts/restore.sh --snapshot 20260920-030000
```

This is why the pre-upgrade backup is not optional in practice: without it, a
failed major upgrade has no way back.

## Upgrading the other components

MongoDB, NATS, MinIO and nginx are pinned separately in `.env`. They change far
less often and are not covered by `upgrade.sh`.

```bash
sed -i 's/^RC_NGINX_VERSION=.*/RC_NGINX_VERSION=1.31-alpine/' .env
docker compose pull nginx && docker compose up -d nginx
./scripts/health-check.sh
```

**MongoDB is the exception.** It cannot skip major versions either, and the
upgrade needs `featureCompatibilityVersion` raised after the binary is
replaced. Check Rocket.Chat's supported MongoDB versions before moving, take a
backup, and follow MongoDB's own upgrade procedure. Rocket.Chat 8.x requires
MongoDB 8.0 or later.

## Updating this deployment tooling

Separate from upgrading Rocket.Chat:

```bash
cd /opt/rocketchat
git pull
./scripts/setup.sh     # idempotent; re-applies configuration
```

Read the diff first if the changes touch `compose.yml` or the nginx templates.

## Before any upgrade

- [ ] Read the release notes for every version between yours and the target
- [ ] Confirm the target is in the supported-versions feed
- [ ] Confirm you are not skipping a major version
- [ ] Take a backup and confirm it is non-empty
- [ ] Have a maintenance window — the restart is a real outage
- [ ] Know your rollback: the current version number and the snapshot name
