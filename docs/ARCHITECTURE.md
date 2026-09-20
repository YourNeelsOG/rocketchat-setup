# Architecture

## Components

| Service | Image | Why it is here |
|---|---|---|
| nginx | `nginx:1.30-alpine` | TLS termination, WebSocket upgrade, upload streaming |
| rocketchat | `registry.rocket.chat/rocketchat/rocket.chat` | The application |
| mongodb | `mongodb/mongodb-community-server:8.0-ubi8` | Message and account storage |
| nats | `nats:2.11-alpine` | Message transporter, required by Rocket.Chat 8.x |
| minio | `quay.io/minio/minio` | S3-compatible object storage for uploads |
| certbot | `certbot/certbot` | Certificate issuance and renewal (public-tls only) |

Three further containers run once and exit: `mongodb-permissions` fixes data
directory ownership, `mongodb-init` initialises the replica set, and
`minio-init` creates the bucket and the scoped credential.

## Why NATS

Rocket.Chat 8.x sets `TRANSPORTER` to `monolith+nats://nats:4222`. The official
compose repository ships NATS alongside the application and documents the
recommended stack as Rocket.Chat, a proxy, MongoDB, NATS and monitoring. It is
not an optional add-on for clustering; the monolith uses it too.

## Port matrix

| Port | Exposure | Why |
|---|---|---|
| 80 | Published | HTTP-to-HTTPS redirect, and the ACME challenge path |
| 443 | Published | The application |
| 3000 | Internal | Rocket.Chat. Published only in `behind-proxy` mode, to loopback by default |
| 27017 | Internal | MongoDB. Never published — it has no authentication |
| 4222 | Internal | NATS. Never published |
| 9000 | Internal | MinIO. Never published |
| 8222 | Internal | NATS monitoring, used only by the container healthcheck |

Everything except nginx is on a single Docker bridge network with no published
ports. The network is not marked `internal: true`, because Rocket.Chat needs
outbound access for push notification relay, the marketplace, and version
checks.

The subnet is chosen at install time from the ranges no existing Docker network
on the host occupies, so adding this stack to a machine already running
containers does not collide.

## Upload path

```
client ──▶ nginx ──▶ rocketchat ──▶ minio
```

nginx is configured with `proxy_request_buffering off`, so the body streams
through rather than being written to the proxy's disk in full before being
forwarded. `client_max_body_size` matches `RC_MAX_UPLOAD_SIZE`; a mismatch here
produces a 413 from nginx that never reaches the application.

Rocket.Chat itself buffers the upload in the application process before writing
to object storage. That is the real constraint on upload size, not nginx. See
[LARGE-FILE-TESTING.md](LARGE-FILE-TESTING.md).

## Download path, and why it is proxied

```
client ──▶ nginx ──▶ rocketchat ──▶ minio ──▶ rocketchat ──▶ nginx ──▶ client
```

This is a deliberate choice with a real cost, so it is worth understanding.

Rocket.Chat's S3 driver has three settings — `FileUpload_S3_Proxy_Uploads`,
`FileUpload_S3_Proxy_Avatars` and `FileUpload_S3_Proxy_UserDataFiles` — that
all default to **false**. With the defaults, a download request is answered
with a redirect to a presigned URL built from `FileUpload_S3_BucketURL`.

In this deployment that URL is `http://minio:9000`, a Docker-internal hostname.
A browser or mobile app receiving that redirect cannot resolve it. The failure
is asymmetric and easy to miss: uploads succeed, files appear in the channel,
and only opening one fails. This stack therefore sets all three to `true`.

The cost is that download bytes pass through the Node process rather than going
straight from object storage to the client.

**The alternative**, if download throughput matters more than a closed network
boundary: publish MinIO on its own subdomain with its own certificate, set
`FileUpload_S3_BucketURL` to that public URL, and set the three proxy settings
back to `false`. Clients then fetch presigned URLs directly. This needs a
second DNS record, a second certificate, and MinIO exposed to the internet.

## Storage

`RC_MONGO_PATH` and `RC_MINIO_PATH` each take either a Docker named volume or
an absolute host path. Named volumes are the default and live under Docker's
data root — which is frequently on a different filesystem from `/opt`, so
`health-check.sh` reports free space on both.

MongoDB's storage engine requires POSIX file locking and atomic rename. NTFS
via FUSE, exFAT, and network mounts do not provide these reliably, and the
resulting corruption is silent rather than loud. `configure.sh` and
`preflight.sh` both refuse to place MongoDB on one.

## MongoDB replica set

Rocket.Chat requires a replica set for change streams. This is a single-member
set, which provides no redundancy — only the change-stream interface.

The member is registered as `mongodb:27017`, not by the container's own
hostname. A bare `rs.initiate()` records the container ID, which changes every
time the container is recreated; the replica set then has no reachable member
and Rocket.Chat cannot connect, with no obvious cause in its logs. The service
also sets `hostname: mongodb` so the container agrees with the registration.

## Object storage: MinIO and the alternatives

Two facts worth knowing before committing:

- The newest tag on `quay.io/minio/minio` is `RELEASE.2025-09-07T16-13-09Z`.
- The administrative web console was removed from the community build in
  `RELEASE.2025-05-24`. Bucket, policy and user management are `mc` operations
  now. Any guide telling you to open the MinIO console is out of date; this
  stack disables the browser entirely (`MINIO_BROWSER=off`) since nothing needs
  it.

MinIO still works, and a frozen release is not an insecure one. But a component
receiving no upstream attention is a liability over a multi-year deployment.
The credible S3-compatible alternatives are **Garage** (small, simple,
single-binary) and **SeaweedFS** (larger, more features). Switching means
changing the `minio`/`minio-init` services and the `FileUpload_S3_*` settings;
the rest of the stack is unaffected.

MinIO here is single-node with no erasure coding. It protects against nothing
at the disk level.

## Credentials

Two MinIO credential pairs exist. The root pair administers the object store
and is used only by `minio-init`. Rocket.Chat receives a separate pair scoped
by policy to `GetObject`, `PutObject` and `DeleteObject` on the uploads bucket,
plus `ListBucket` on the bucket itself. A compromise of the application cannot
administer object storage, create buckets, or read anything outside that one
bucket.

## Certificate flow (public-tls)

The ordering matters and is the reason `issue-cert.sh` exists as a separate
step:

1. nginx starts with a bootstrap configuration that references no certificate
   and serves only `/.well-known/acme-challenge/`.
2. certbot validates over HTTP-01 through it — first as a dry run against the
   staging endpoint, which costs nothing against the rate limit.
3. The real certificate is issued.
4. nginx is recreated with the full configuration.

Starting with the full configuration cannot work: it references certificate
files that do not exist yet, so nginx fails to start, and certbot's challenge
then has nothing answering on port 80. Each waits on the other.

Renewal runs twice daily and reloads nginx **only if the certificate actually
changed**. Omitting the reload is the classic version of this bug: the renewal
succeeds, the file on disk is current, and nginx keeps serving the certificate
it loaded at startup until it expires.
