# rocketchat-setup

Self-hosted Rocket.Chat on one Linux machine: Rocket.Chat, MongoDB, NATS and
MinIO behind nginx, with TLS, backups and an upgrade path.

Built for a server that is **already doing something else**. The installer
probes the host and asks rather than assuming: which ports are free, where the
data should live, whether you already run a reverse proxy, which firewall (if
any) it should touch, and whether it should schedule anything at all.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/YourNeelsOG/rocketchat-setup/main/install.sh -o install.sh
```

Read it, then run it:

```bash
less install.sh
sudo bash install.sh
```

See exactly what it would do to your machine, changing nothing:

```bash
sudo bash install.sh --dry-run
```

There is a `curl … | sudo bash` one-liner in every project like this one. It is
not the instruction here, because piping a remote script into a root shell
gives you no chance to read what is about to run as root on your server.

### Unattended

Every question has a flag, so an interactive install and a scripted one produce
identical configuration:

```bash
sudo bash install.sh --non-interactive \
  --mode public-tls \
  --domain chat.example.com \
  --letsencrypt-email admin@example.com \
  --firewall ufw --ssh-port 22 \
  --schedule systemd
```

Or put the answers in a file:

```bash
cp .env.example answers.env
$EDITOR answers.env
sudo ./scripts/configure.sh --config answers.env --non-interactive
sudo ./scripts/setup.sh
```

---

## Deployment modes

The first question the installer asks, because it determines everything else.

| Mode | For | TLS | Needs a public IP |
|---|---|---|---|
| `public-tls` | A public server with a real domain | Let's Encrypt, auto-renewed | Yes |
| `local-tls` | A LAN, home lab or office server | Self-signed, CA generated locally | No |
| `behind-proxy` | A host already running Caddy, Traefik, nginx or NPM | Handled by your proxy | No |
| `plain-http` | An isolated network, or testing | None | No |

`behind-proxy` starts no nginx and issues no certificate. It publishes
Rocket.Chat on a port you choose — bound to loopback by default — and prints a
ready-made configuration snippet for your proxy.

`local-tls` generates a local CA. The Rocket.Chat mobile apps reject
certificates they cannot verify, so `certs/ca.crt` has to be installed on every
phone that will connect. The installer prints the steps for each platform.

---

## What the installer asks

Nothing below is hardcoded. Each has a matching flag; run
`scripts/configure.sh --help` for the full list.

- **Mode** and the hostname clients will use
- **Ports** — probed first. If something already holds 80, you are told *what*
  holds it and offered the next free port, rather than finding out when the
  stack half-starts.
- **Bind address** — every interface, or loopback only
- **Storage** — Docker named volumes, or a directory on a disk you choose.
  Either way the filesystem is checked: MongoDB on NTFS, exFAT or a network
  mount corrupts silently, so it is refused rather than warned about.
- **Upload ceiling** — with the real tradeoffs shown, not just a number
- **Rocket.Chat version** — checked live against the supported-versions feed
- **Compose project name and Docker subnet** — both checked against what is
  already on the host
- **Firewall** — ufw, firewalld, or leave it alone. Existing rules are kept.
- **Scheduling** — systemd timers, cron, or nothing

---

## Requirements

- A Linux host: Debian, Ubuntu, Arch, or RHEL-family
- 4 GB RAM minimum, 8 GB or more recommended
- 20 GB free, plus room for whatever gets uploaded
- Docker with the `docker compose` plugin (installed for you if missing).
  The standalone `docker-compose` v1 will not work: this stack uses compose
  profiles and `service_healthy` dependencies.
- For `public-tls` only: a public IP, a DNS record already pointing at it, and
  port 80 reachable from the internet

---

## Architecture

```
                    ┌──────────────────────────────────────────┐
   clients ────────▶│ nginx        :80 :443                    │
   (browser,        │  TLS, WebSocket upgrade, upload streaming│
    mobile,         └────────────────┬─────────────────────────┘
    desktop)                         │ http
                    ┌────────────────▼─────────────────────────┐
                    │ rocketchat   :3000                       │
                    └───┬──────────────┬──────────────┬────────┘
                        │              │              │
              ┌─────────▼───┐  ┌───────▼─────┐  ┌─────▼──────┐
              │ mongodb     │  │ nats        │  │ minio      │
              │ :27017 rs0  │  │ :4222       │  │ :9000      │
              └─────────────┘  └─────────────┘  └────────────┘

   Published to the host:  80, 443  (nginx only)
   Internal to the Docker network:  everything else
```

Only nginx is reachable from outside. MongoDB, NATS and MinIO have no published
ports at all, and file downloads are proxied through Rocket.Chat rather than
redirecting clients to object storage — see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for why that matters.

---

## Day-to-day

```bash
./scripts/health-check.sh              # services, certificate, disk, backup age
./scripts/backup.sh                    # one snapshot
./scripts/restore.sh                   # pick a snapshot and restore it
./scripts/upgrade.sh --to 8.8.1        # backup, pull, swap, verify, rollback path
./scripts/supported-versions.sh        # which releases are still supported
./scripts/uninstall.sh                 # teardown, with data kept unless you say otherwise
```

`health-check.sh` exits non-zero when something is wrong, so it works as a
monitoring probe as well as a command you run.

---

## Documentation

| Document | What it covers |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Topology, ports, upload and download paths, why NATS is here |
| [SECURITY.md](docs/SECURITY.md) | Threat model, what is *not* protected, hardening checklist |
| [BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) | What is captured, consistency limits, off-site options |
| [LARGE-FILE-TESTING.md](docs/LARGE-FILE-TESTING.md) | Finding your real upload ceiling |
| [MOBILE-SETUP.md](docs/MOBILE-SETUP.md) | Android, iOS, desktop, and why local-tls needs extra steps |
| [ORGANIZATION.md](docs/ORGANIZATION.md) | Channel structure, roles, onboarding |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptoms mapped to causes |
| [UPGRADE.md](docs/UPGRADE.md) | Version policy, stepping rules, rollback |
| [FAILURE-SCENARIOS.md](docs/FAILURE-SCENARIOS.md) | What breaks when each piece fails |

---

## Known limitations

Stated here rather than discovered later.

- **Linux kernel 6.19+ needs a MongoDB workaround.** MongoDB 8.0+ segfaults on these kernels
  and its official image refuses to start. The installer detects this and sets
  `GLIBC_TUNABLES=glibc.pthread.rseq=1`, which costs allocator performance and is not an
  officially supported configuration. Affects current Arch and Fedora today, and everything
  else eventually.
- **No resumable uploads.** Rocket.Chat restarts an interrupted transfer from
  zero. The default 2 GiB ceiling reflects what works reliably, not what the
  configuration will accept.
- **Single-node MinIO.** No erasure coding, no redundancy. The disk is a single
  point of failure and backups are the only recovery path.
- **MongoDB runs without authentication.** The Docker network is the security
  boundary. This matches the official Rocket.Chat compose setup; the
  implications are spelled out in [docs/SECURITY.md](docs/SECURITY.md).
- **MinIO community is effectively frozen.** The newest release available is
  from 2025-09-07, and its administrative console was removed in
  2025-05-24. Still functional, but not receiving attention.
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) names the alternatives.
- **Backups are not atomic.** Object storage is captured before the database so
  that the inconsistency window produces invisible orphans rather than broken
  attachments. [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) has the detail.

---

## License

MIT. See [LICENSE](LICENSE).
