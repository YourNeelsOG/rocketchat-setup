# Security

## What this protects against, and what it does not

Stated plainly, because a security document that only lists the good parts is
worse than none.

**Protected:**

- Traffic between clients and the server, in `public-tls` and `local-tls` modes
- Direct access to MongoDB, MinIO and NATS from outside the host — none are
  published
- Object storage compromise via the application — Rocket.Chat holds a credential
  scoped to one bucket, not the MinIO root credential
- Credentials at rest on disk — `.env` is mode 600, root-owned

**Not protected:**

- **MongoDB has no authentication.** Anything that can reach the Docker network
  can read every message and account in the database. This matches the official
  Rocket.Chat compose setup, and is acceptable when this host runs nothing else
  that could be compromised. It is *not* acceptable if you run other containers
  from other sources on the same Docker daemon. See "Hardening" below.
- **Other containers on the same Docker host.** Docker bridge networks are not
  a strong isolation boundary against a container running as root on the same
  daemon.
- **The host itself.** Root on this machine reads `.env` and therefore
  everything.
- **Message content at rest.** Neither MongoDB nor MinIO is encrypted here.
  Full-disk encryption on the host is the practical answer.
- **`plain-http` mode has no transport security at all.** Logins cross the
  network in cleartext.

## Pre-deployment checklist

- [ ] Run `./scripts/preflight.sh` and resolve everything it reports
- [ ] Confirm `RC_SSH_PORT` is the port you actually connect on, before any
      firewall step
- [ ] Confirm `.env` is mode 600 and owned by root: `stat -c '%a %U' .env`
- [ ] Confirm nothing but nginx is published: `docker compose ps --format '{{.Service}} {{.Ports}}'`
- [ ] Create the administrator account **immediately** after the first start.
      Until one exists, the setup wizard is open to whoever reaches the server
      first. This is the single largest window of exposure in the whole install.
- [ ] Set up off-site backups — see [BACKUP-RESTORE.md](BACKUP-RESTORE.md)
- [ ] Verify from outside: `nmap -Pn <host>` should show only SSH, 80 and 443
- [ ] In `local-tls` mode, distribute `certs/ca.crt` over a channel you trust,
      not over the same network you are securing

## Credential locations

| Secret | Where | Mode |
|---|---|---|
| MinIO root pair | `.env` | 600 |
| MinIO application pair | `.env`, and Rocket.Chat's environment | 600 |
| TLS private key (public-tls) | `letsencrypt_data` volume | root-only |
| TLS private key (local-tls) | `certs/server.key` | 600 |
| Local CA private key | `certs/ca.key` | 600 |

`certs/ca.key` signs certificates your devices will trust. Anyone holding it
can impersonate your server to any device that installed the CA. It is not
needed after issuance: move it somewhere offline, or delete it and regenerate
the CA when you next need one.

Rocket.Chat's own environment is visible via `docker inspect` to anyone in the
`docker` group. Membership in that group is equivalent to root.

## Firewall

The installer adds rules and never removes existing ones. The SSH allow rule is
added **before** the firewall is enabled, never after — a default-deny policy
without an SSH rule strands a remote administrator with no way back in.

`RC_FIREWALL=none` is a legitimate answer, and the right one on a host whose
rules are managed centrally.

Rules added:

```
allow <RC_SSH_PORT>/tcp
allow <RC_HTTP_PORT>/tcp      # not in behind-proxy mode
allow <RC_HTTPS_PORT>/tcp     # public-tls and local-tls only
```

To review: `ufw status numbered` or `firewall-cmd --list-all`.

Note that Docker's own iptables rules can bypass ufw for published ports. This
stack publishes only nginx, so the practical exposure is the same either way,
but do not assume a ufw deny rule will block a published container port.

## TLS configuration

TLS 1.2 and 1.3 only. ECDHE key exchange with AES-GCM and ChaCha20-Poly1305.
Session tickets off. `server_tokens off`.

HSTS is set **only** in the `public-tls` template, never in `local-tls`. Sending
HSTS from a deployment backed by a certificate the browser cannot verify pins
that browser to HTTPS for a year against a server it refuses to trust, and
nothing on the server can reverse it.

## Hardening beyond the defaults

**Enable MongoDB authentication.** The meaningful one if this host runs other
workloads. It requires a keyfile for the replica set, a user with
`readWrite` on the `rocketchat` database, and `MONGO_URL` updated with
credentials and `authSource`. It is not the default here because it adds a
failure mode to first-boot for a threat that does not exist on a
single-purpose host.

**Full-disk encryption** on the host, which is the only thing that protects
message content at rest.

**Restrict the published port in behind-proxy mode.** If your proxy is on
another machine and you set `RC_BIND_ADDRESS=0.0.0.0`, add a firewall rule
limiting that port to the proxy's address. The default binds to loopback
precisely to avoid this.

**Rotate the MinIO application credential** periodically: generate a new pair,
`mc admin user add` and attach the policy, update `.env`, restart Rocket.Chat,
then `mc admin user remove` the old one. Do it in that order — removing first
breaks uploads until the restart completes.

**Review `docker inspect` exposure.** Anyone in the `docker` group can read
every environment variable in every container.

## Periodic audit

Monthly is a reasonable cadence:

- `./scripts/health-check.sh` — certificate expiry and backup age in particular
- `./scripts/supported-versions.sh` — is the running version still supported?
- Review Rocket.Chat admin: accounts, roles, and which channels are public
- Confirm off-site backups are actually arriving, by looking at the
  destination rather than at the sending side
- `docker compose ps --format '{{.Service}} {{.Ports}}'` — has anything new
  become published?
- Restore a backup into a throwaway instance. A backup that has never been
  restored is a hypothesis.

## Reporting a problem

Open an issue at
`https://github.com/YourNeelsOG/rocketchat-setup/issues` for problems with
this deployment tooling. Vulnerabilities in Rocket.Chat, MongoDB, NATS or MinIO
belong upstream with those projects.
