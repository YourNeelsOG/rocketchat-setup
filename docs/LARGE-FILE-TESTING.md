# Large file uploads

## The honest ceiling

The default `RC_MAX_UPLOAD_SIZE` is 2 GiB. You can set it higher; whether it
*works* depends on things this project does not control.

Four constraints, in the order they bite:

1. **No resumable upload.** Rocket.Chat restarts an interrupted transfer from
   zero. A 10 GB upload on a 50 Mbit/s uplink is a 27-minute window in which a
   dropped Wi-Fi connection, a laptop sleeping, or a proxy timeout costs the
   whole transfer.
2. **The application buffers the file.** The upload is held by the Node process
   before it reaches object storage. Two concurrent 4 GB uploads on an 8 GB
   host invite the OOM killer, which kills the container for everyone rather
   than failing the one upload.
3. **`FileUpload_MaxFileSize` is declared as an `int`** in Rocket.Chat's
   settings registry, with a default of 104857600. 10737418240 exceeds the
   signed 32-bit maximum of 2147483647. It may work — the value passes through
   JavaScript numbers and BSON — but it is outside the range the setting's
   declared type implies, and not a configuration upstream exercises.
4. **Timeouts.** The nginx proxy timeouts here are 3600s. A 10 GB upload must
   sustain roughly 23 Mbit/s for a full hour without stalling to finish inside
   that window.

None of this is a reason not to raise the ceiling. It is a reason to find your
own ceiling by measurement rather than by setting a large number and hoping.

## Finding your real ceiling

Work upward. Stop at the first size that fails or takes unreasonably long.

```bash
# Generate test files without consuming real disk time
fallocate -l 100M /tmp/test-100m.bin
fallocate -l 500M /tmp/test-500m.bin
fallocate -l 1G   /tmp/test-1g.bin
fallocate -l 2G   /tmp/test-2g.bin
```

For each one, in a real client (not curl — the browser and mobile clients have
their own limits):

1. Upload it to a channel.
2. **Download it back and check the size matches.** Uploading alone proves
   nothing about whether it can be retrieved.
3. Watch memory during the transfer: `docker stats --no-stream rocketchat`

Then check each layer for complaints:

```bash
# nginx: 413 means client_max_body_size is the limit that stopped it
docker compose logs --tail 50 nginx | grep -E '413|client intended'

# Rocket.Chat: the application-side limit and any upload errors
docker compose logs --tail 100 rocketchat | grep -iE 'upload|file|size|error'

# MinIO: whether the object actually landed, and at what size
docker compose run --rm --entrypoint sh minio-init -c '
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc ls --recursive local/"$RC_MINIO_BUCKET" | tail -20
'
```

The MinIO check is how you distinguish "the upload failed" from "the upload
succeeded and the download is broken" — a distinction that matters, because the
second one has a different cause entirely.

## Raising the ceiling

One value, applied to both layers:

```bash
sed -i 's/^RC_MAX_UPLOAD_SIZE=.*/RC_MAX_UPLOAD_SIZE=5368709120/' .env   # 5 GiB
docker compose up -d --force-recreate nginx rocketchat
```

`nginx` must be recreated, not just reloaded: `client_max_body_size` comes from
the template, which is rendered at container start.

Common values:

| Size | Bytes |
|---|---|
| 1 GiB | 1073741824 |
| 2 GiB | 2147483648 |
| 4 GiB | 4294967296 |
| 5 GiB | 5368709120 |
| 10 GiB | 10737418240 |

In `behind-proxy` mode you must also raise the limit **on your own proxy**, or
it rejects the upload before this stack ever sees it:

```
# Caddy
request_body { max_size 5GB }

# nginx
client_max_body_size 5G;
proxy_request_buffering off;

# Traefik: no body size limit by default, but check any buffering middleware
```

## Timeouts

If large uploads fail at roughly the same elapsed time every attempt, a timeout
is the cause rather than a size limit. The relevant values are in
`nginx/templates/<mode>/default.conf.template`:

```nginx
proxy_connect_timeout 3600s;
proxy_send_timeout    3600s;
proxy_read_timeout    3600s;
```

Rough arithmetic: seconds needed ≈ file size in MB ÷ (upload Mbit/s ÷ 8).
A 2 GiB file at 20 Mbit/s is about 850 seconds — comfortably inside an hour. The
same file at 5 Mbit/s is about 3400 seconds, which is close enough to the limit
that a brief stall will cross it.

After editing a template: `docker compose up -d --force-recreate nginx`.

## Known limits that are not configurable

- **No resume.** An interrupted upload starts over. This is a Rocket.Chat
  design limitation, not a setting.
- **Mobile uploads over cellular** are the least reliable path by a wide
  margin. Handover between towers drops connections.
- **Browsers** vary in how they handle very large form uploads; Chrome and
  Firefox behave differently above about 2 GB.
- **Total storage** is bounded by the disk holding `RC_MINIO_PATH` or the
  Docker data root. `health-check.sh` reports both.

## Recommendation

For a general-purpose team instance, 2 GiB works reliably and covers nearly
every real use. If people need to move genuinely large files regularly, a chat
server is the wrong tool for it — a file server, object storage with presigned
links, or a purpose-built transfer tool will be faster and will survive
interruptions.
