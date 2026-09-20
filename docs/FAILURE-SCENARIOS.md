# Failure scenarios

What actually happens when each piece breaks, including the cases with no good
answer.

## Individual services

### MongoDB unavailable

**Symptom:** Rocket.Chat is completely down. The page does not load.

**Why:** Every message, account and setting lives there. There is no degraded
mode.

**Recovery:** `docker compose logs mongodb`. Usually the disk is full or the
data directory ownership is wrong. If the data itself is damaged, restore.

**Prevention:** watch disk on the Docker data root — `health-check.sh` reports
it.

### MinIO unavailable

**Symptom:** Messages send and arrive normally. Uploads fail. Existing
attachments show in the history but will not download. Avatars disappear.

**Why:** Only file storage is affected; the database is untouched.

**Recovery:** `docker compose restart minio`. If its volume is lost, message
history survives and every attachment is permanently gone — restore from a
snapshot.

This is the most confusing failure in the stack because the instance looks
healthy from the outside.

### NATS unavailable

**Symptom:** Rocket.Chat fails to start, or degrades once running. Rocket.Chat
8.x uses NATS as its transporter, so this is not optional.

**Recovery:** `docker compose restart nats`. NATS holds no durable state here,
so restarting is safe.

### nginx unavailable

**Symptom:** Connection refused. The application is fine behind it.

**Recovery:** `docker compose exec nginx nginx -t` — it is almost always a
configuration error, and after a certificate change it is almost always a
missing certificate file. Run `issue-cert.sh`.

### Rocket.Chat unavailable

**Symptom:** nginx returns 502.

**Recovery:** `docker compose logs --tail 100 rocketchat`. Common causes: the
replica set has no primary, NATS is unreachable, or the OOM killer took it
during a large upload.

---

## Host-level

### Reboot

Everything comes back. All services are `restart: unless-stopped`, and Docker
is enabled at boot.

Two caveats worth knowing: startup takes a few minutes, because MongoDB must
elect a primary before Rocket.Chat will start; and a container the admin
deliberately stopped stays stopped, which is the point of `unless-stopped` over
`always`.

### Disk full

**Symptom:** Uploads fail, MongoDB refuses writes, and the interface behaves
erratically. The error surface points at MongoDB, which is misleading.

**Recovery:**

```bash
df -h
docker system df
docker image prune -a
```

Then check backup retention — old snapshots are the usual cause.

**Prevention:** `health-check.sh` fails below 5 GB and warns below 15 GB on
each of the install directory, the Docker root, and the backup directory. Run
it from monitoring.

### Out of memory

**Symptom:** The Rocket.Chat container is killed mid-upload and restarts.
`dmesg | grep -i 'killed process'` confirms.

**Why:** Uploads are buffered in the application process.

**Recovery:** lower `RC_MAX_UPLOAD_SIZE`, or add RAM.

### Disk failure

**Symptom:** Everything is gone.

**Recovery:** backups, which is the only path. MinIO here is single-node with
no erasure coding and MongoDB is a single-member replica set — neither provides
redundancy of any kind.

**This is the scenario that justifies off-site backups.** A snapshot on the
failed disk is worth nothing. See [BACKUP-RESTORE.md](BACKUP-RESTORE.md).

---

## Certificates

### Renewal fails

Certbot begins attempting renewal 30 days before expiry and runs twice daily,
so there is a wide margin. `health-check.sh` fails at under 14 days remaining,
which is the signal that renewal is broken rather than merely pending.

Usual causes: the DNS record changed, port 80 became unreachable, or another
service took port 80.

### The certificate expires

Browsers show a full-page warning that users can click through. **The mobile
apps refuse to connect entirely** — this is the failure people notice first,
and it presents as "the app is broken" rather than as a certificate problem.

```bash
./scripts/renew-cert.sh --force-renewal
```

---

## Uploads

### An upload fails partway

**It starts over from zero.** Rocket.Chat does not support resumable uploads.
Nothing in this deployment can change that.

For a 2 GiB file on a stable connection this is an annoyance. For a 10 GB file
on a mobile connection it may never succeed.

### Partial objects in storage

A failed upload can leave an object with no database row. It is invisible and
consumes space. To find them, compare object count against the database:

```bash
docker compose run --rm --entrypoint sh minio-init -c '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc ls --recursive local/"$RC_MINIO_BUCKET" | wc -l
'
docker compose exec mongodb mongosh --quiet \
  'mongodb://mongodb:27017/rocketchat?replicaSet=rs0' \
  --eval 'db.rocketchat_uploads.countDocuments()'
```

A small discrepancy is normal. A large one suggests either many failed uploads
or a restore that captured the stores at different moments.

---

## Data loss

### Someone deletes a channel

Rocket.Chat deletion is immediate and permanent. Restore from a snapshot — which
means losing everything since. Prevention is the permission model: restrict who
can delete channels. See [ORGANIZATION.md](ORGANIZATION.md).

### A restore is run by mistake

`restore.sh` takes a safety backup of the current state before it does
anything, precisely for this. Restore that one.

### `.env` is lost

The MinIO credentials live only there. Without them `minio-init` creates a new
user and Rocket.Chat cannot read existing objects — message history survives,
every attachment becomes unreadable.

Backup snapshots include `config/env`. If no backup exists, the MinIO root
credential can be reset by recreating the container with new
`MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` values, but objects written under the
old application key remain readable only via the root credential, and the
mapping has to be rebuilt by hand.

Keep a copy of `.env` somewhere safe. It is small and it is the least
replaceable thing here.

---

## Limitations, stated plainly

- **No high availability.** Single node throughout. Every service is a single
  point of failure.
- **No redundancy.** One disk. MinIO has no erasure coding; MongoDB's replica
  set has one member and exists only to provide change streams.
- **No resumable uploads.** A product limitation.
- **Backups are not atomic.** See [BACKUP-RESTORE.md](BACKUP-RESTORE.md) for
  the ordering and how to close the window entirely.
- **MongoDB is unauthenticated.** The Docker network is the boundary. See
  [SECURITY.md](SECURITY.md).
- **MinIO community is frozen.** Newest release 2025-09-07, console removed
  2025-05-24.
- **Push notifications** require registering the workspace with Rocket.Chat's
  gateway. Without it, the mobile apps receive messages only while open.

If any of these is unacceptable for your use, that is a signal to move to a
clustered deployment or a managed service, not to work around it here.
