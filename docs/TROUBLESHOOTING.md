# Troubleshooting

Organised by what you observe, not by component.

Start here:

```bash
./scripts/health-check.sh
docker compose ps
docker compose logs --tail 50
```

---

## Installation

### The installer refuses: port already in use

Expected on a host already serving something. It names the holder:

```
[warn] port 80 is already in use by: caddy
```

Three ways forward:

- Use `behind-proxy` mode and let the existing service forward to this stack.
  Usually the right answer when the holder is another web server.
- Choose different ports. Note that `public-tls` still requires port 80, because
  Let's Encrypt HTTP-01 validation always connects there.
- Stop the other service.

### "MongoDB cannot safely store data on a fuseblk filesystem"

The chosen data path is on NTFS, exFAT, or a network mount. MongoDB needs POSIX
file locking and atomic rename; these filesystems do not provide them reliably,
and the corruption that follows is silent. Choose a path on ext4, xfs or btrfs.
This is a hard stop with no override, deliberately.

### "the 'docker compose' plugin is missing"

The standalone `docker-compose` v1 is a different program and will not work:
this stack uses compose profiles and `service_healthy` dependencies. Install the
plugin: <https://docs.docker.com/compose/install/>

### A compose project of this name already exists

Another stack on this host uses the same project name. Pass
`--project-name something-else`. Reusing the name adopts or replaces the other
stack's containers.

---

## Startup

### A container restarts repeatedly

```bash
docker compose ps
docker compose logs --tail 100 <service>
```

**mongodb** — usually a permissions problem on the data directory. The
`mongodb-permissions` container should fix ownership to uid 1001 before mongod
starts; check that it completed:

```bash
docker compose logs mongodb-permissions
```

**rocketchat** — check that `mongodb-init` finished and the replica set has a
primary:

```bash
docker compose logs mongodb-init
docker compose exec mongodb mongosh --quiet \
  'mongodb://mongodb:27017/?directConnection=true' --eval 'rs.status().members[0].stateStr'
```

Expect `PRIMARY`.

**nginx** — almost always a configuration error. The rendered configuration is
inside the container:

```bash
docker compose exec nginx nginx -t
docker compose exec nginx cat /etc/nginx/conf.d/default.conf
```

If it references a certificate that does not exist, `issue-cert.sh` has not
completed. Run it.

### MongoDB exits immediately: "will not start by default on v6.19+"

```
ERROR: Detected Linux kernel 7.2.6-arch2-1. MongoDB 8.0+ utilizes the tcmalloc allocator
which has a known issue with the v6.19 and newer Linux kernel. This container will not
start by default on v6.19+.
```

MongoDB 8.0+ bundles a tcmalloc whose rseq use conflicts with glibc's, and mongod segfaults
within about thirty seconds on kernel 6.19 or newer. The official image refuses to start rather
than crash later, and no 8.x tag offers an environment variable to override that check.

This stack handles it: the `mongodb` service invokes `mongod` directly rather than through the
image's Python entrypoint, and `configure.sh` sets `GLIBC_TUNABLES=glibc.pthread.rseq=1` when it
detects a kernel of 6.19 or newer. That is the documented workaround. It hands rseq to glibc and
disables tcmalloc's, which costs allocator performance and is not an officially supported
configuration, but the database runs.

If you see this error, your `.env` is missing the setting — usually because it was written on an
older kernel and the machine has since been upgraded:

```bash
grep RC_GLIBC_TUNABLES .env
```

Empty on a 6.19+ kernel means re-running `scripts/configure.sh` will fix it, or add it by hand:

```bash
echo 'RC_GLIBC_TUNABLES=glibc.pthread.rseq=1' >> .env
docker compose up -d --force-recreate mongodb
```

### Backups cannot be deleted: permission denied

Objects mirrored out of MinIO are written by a container. If the backup predates the fix that
runs that container as the invoking user, the files are owned by root and a non-root operator
cannot prune them. New snapshots are written correctly; to clear old ones:

```bash
sudo rm -rf /opt/rocketchat/backups/<old-snapshot>
```

### The replica set will not initialise

```bash
docker compose logs mongodb-init
docker compose exec mongodb mongosh --quiet \
  'mongodb://mongodb:27017/?directConnection=true' --eval 'rs.status()'
```

If `rs.status()` reports a member whose host is a hex string rather than
`mongodb:27017`, the set was initialised without a pinned hostname — from an
older version of this project, or by hand. Reconfigure:

```bash
docker compose exec mongodb mongosh --quiet \
  'mongodb://mongodb:27017/?directConnection=true' --eval '
    const c = rs.conf();
    c.members[0].host = "mongodb:27017";
    rs.reconfig(c, {force: true});
  '
docker compose restart rocketchat
```

### Rocket.Chat starts but cannot reach the transporter

Rocket.Chat 8.x requires NATS.

```bash
docker compose ps nats
docker compose logs --tail 30 nats
docker compose exec rocketchat env | grep TRANSPORTER
```

Expect `monolith+nats://nats:4222`.

---

## Certificates

### Issuance fails

`issue-cert.sh` runs a staging dry run first, so a failure here costs nothing
against the rate limit. In order of likelihood:

**The DNS record does not point here.**

```bash
getent ahosts chat.example.com
curl -s https://api.ipify.org
```

These must match.

**Port 80 is not reachable from the internet.** Test from elsewhere, not from
the server itself:

```bash
curl -I http://chat.example.com/.well-known/acme-challenge/test
```

Anything other than a response from this nginx — a timeout, or a different
server — means a firewall, NAT rule, or ISP block is in the way.

**Something else answers on port 80 first.** `ss -ltnp | grep :80`

### Rate limited

Let's Encrypt allows 5 failed validations per hostname per hour, and 50
certificates per registered domain per week. Wait out the hour, fix the actual
cause, and rehearse with `--staging-certs` before trying again.

### The certificate expired despite renewal being scheduled

The renewal ran but nginx was never reloaded, so it kept serving the
certificate it loaded at startup. `renew-cert.sh` handles the reload; confirm
it is what is scheduled:

```bash
systemctl list-timers 'rocketchat-*'
cat /etc/cron.d/rocketchat
./scripts/renew-cert.sh --force-renewal
```

### Mobile apps reject the certificate (local-tls)

The CA is not installed on the device, or on iOS the "Certificate Trust
Settings" step was skipped. See [MOBILE-SETUP.md](MOBILE-SETUP.md).

---

## Files

### Uploads fail at a particular size

Work outward from the client. A 413 in the nginx log means
`client_max_body_size` stopped it:

```bash
docker compose logs --tail 50 nginx | grep 413
```

Raise `RC_MAX_UPLOAD_SIZE` in `.env` and
`docker compose up -d --force-recreate nginx rocketchat`. In `behind-proxy`
mode, raise the limit on your own proxy too. See
[LARGE-FILE-TESTING.md](LARGE-FILE-TESTING.md).

### Uploads succeed but downloads fail

The signature of `FileUpload_S3_Proxy_Uploads` being false: Rocket.Chat
redirects the client to `http://minio:9000`, which no browser can resolve.

```bash
docker compose exec rocketchat env | grep Proxy_Uploads
```

Expect `true`. If not, `docker compose up -d --force-recreate rocketchat`.

### Uploads fail immediately with a storage error

Check MinIO and the application credential:

```bash
docker compose logs --tail 50 minio
docker compose logs minio-init
docker compose run --rm --entrypoint sh minio-init -c '
  mc alias set app http://minio:9000 "$RC_MINIO_ACCESS_KEY" "$RC_MINIO_SECRET_KEY" &&
  mc ls app/"$RC_MINIO_BUCKET"
'
```

If that fails, `minio-init` did not complete. Re-run it:
`docker compose up --force-recreate minio-init`

---

## Performance and capacity

### Everything is slow, or MongoDB refuses writes

Check the disk first. A full disk on this stack presents as MongoDB write
failures, which sends people looking in the wrong place.

```bash
df -h /var/lib/docker "$(grep RC_DATA_DIR .env | cut -d= -f2)"
docker system df
```

To reclaim: `docker image prune -a`, and check backup retention — snapshots are
the usual culprit.

### The Rocket.Chat container is killed during uploads

Out of memory. Rocket.Chat buffers uploads in the application process.

```bash
dmesg | grep -i 'killed process'
docker stats --no-stream
```

Lower `RC_MAX_UPLOAD_SIZE`, or add RAM. See
[LARGE-FILE-TESTING.md](LARGE-FILE-TESTING.md).

---

## Useful commands

```bash
# Everything, live
docker compose logs -f

# One service, recent
docker compose logs --tail 100 rocketchat

# What is actually published
docker compose ps --format '{{.Service}}\t{{.Ports}}'

# Resolved configuration, with .env substituted in
docker compose config

# Get into a container
docker compose exec rocketchat sh
docker compose exec mongodb mongosh 'mongodb://mongodb:27017/?directConnection=true'

# MinIO, which has no web console in current community builds
docker compose run --rm --entrypoint sh minio-init -c '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
  mc admin info local
  mc ls --recursive local/"$RC_MINIO_BUCKET" | head
'
```

## When you are stuck

Collect this before asking anywhere:

```bash
./scripts/health-check.sh 2>&1 | tee /tmp/rc-health.txt
docker compose ps >> /tmp/rc-health.txt
docker compose logs --tail 200 >> /tmp/rc-health.txt
grep -vE 'PASSWORD|SECRET|ACCESS_KEY|ROOT_USER' .env >> /tmp/rc-health.txt
```

Check that the redaction worked before sending it anywhere.

Deployment problems: <https://github.com/YourNeelsOG/rocketchat-setup/issues>.
Rocket.Chat problems: <https://forums.rocket.chat>.
