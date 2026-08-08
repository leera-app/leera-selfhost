# Leera — self-hosted

Run Leera on your own server. One command installs the whole stack: web app,
API, PostgreSQL, object storage, and a reverse proxy with automatic HTTPS.

> The files in this repository are published automatically with each Leera
> release. `install.sh`, `docker-compose.yml` and `Caddyfile` are generated —
> edit your local copy under `~/leera`, not this repository.

## Requirements

- A Linux host with [Docker Engine](https://docs.docker.com/engine/install/)
  and the [Compose plugin](https://docs.docker.com/compose/install/)
- Ports **80** and **443** free — the proxy is the only thing that binds
  publicly; the API, database and object store stay on an internal network
- For HTTPS: a domain with a DNS **A record already pointing at this server**.
  Certificates are issued on first start, and that fails if DNS is not live yet.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/leera-app/leera-selfhost/main/install.sh | bash
```

You will be asked for a domain. Enter one (e.g. `pm.example.com`) for automatic
HTTPS via Let's Encrypt, or leave it blank for plain HTTP on `http://localhost`
— fine for evaluating on a laptop or LAN.

For an unattended install, set the domain up front:

```bash
LEERA_DOMAIN=pm.example.com bash -c "$(curl -fsSL https://raw.githubusercontent.com/leera-app/leera-selfhost/main/install.sh)"
```

The first run downloads images and can take a few minutes. When it finishes,
open the URL it prints — **the first account created becomes the administrator.**

Everything lives in `~/leera` (override with `LEERA_HOME`): the generated
`.env` holding your secrets, plus the compose file and Caddyfile.

## Back up before you have data worth losing

```bash
cd ~/leera && ./install.sh --backup
```

This writes a directory containing all three things a restore needs:

| file | why it matters |
| --- | --- |
| `leera.dump` | the database |
| `secret_key` | decrypts every stored credential in that dump, and signs sessions |
| `.env` | container passwords |
| `storage/` | uploaded files and brand assets (best-effort) |

**A database dump on its own will not restore your instance.** Stored
integration credentials, SMTP passwords and API keys are encrypted with
`secret_key`; without the matching key they are unreadable. Keep the whole
directory together, and copy it off the server — a backup that lives only on
the machine it backs up is not a backup.

Restore with:

```bash
cd ~/leera && ./install.sh --restore /path/to/backup
```

## Upgrade

```bash
cd ~/leera && ./install.sh --upgrade
```

Takes a pre-upgrade backup, pulls new images, applies migrations, and restarts.
Migrations are the one part a rollback will not undo, which is why the backup
is automatic and not optional.

## Check on it

```bash
cd ~/leera && ./install.sh --status
```

```bash
cd ~/leera && docker compose logs -f api web
```

## Pinning a version

Installs track the rolling `selfhost` tag by default. To pin, set the version
on first install:

```bash
LEERA_VERSION=selfhost-0.1.2 ./install.sh
```

Afterwards, edit `LEERA_VERSION` in `~/leera/.env` and run `--upgrade`.

Images are public:

- `ghcr.io/leera-app/leera-api:selfhost`
- `ghcr.io/leera-app/leera-web:selfhost`

Use the `selfhost` tags. The `latest` tag is a different build of the product
and is not supported for self-hosting.

## What gets installed

| service | role |
| --- | --- |
| `caddy` | reverse proxy, automatic HTTPS, the only service with published ports |
| `web` | Next.js application |
| `api` | Rust API |
| `migrate` | one-shot schema migrator, re-run on every upgrade |
| `db` | PostgreSQL 17 |
| `minio` | S3-compatible object storage for uploads |

A single public origin serves everything: `/api/*` to the API, `/storage/*` to
object storage, and everything else to the web app.
