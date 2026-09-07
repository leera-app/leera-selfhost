# Leera — self-hosted

Run Leera on your own server. One command installs the whole stack: web app,
API, PostgreSQL, object storage, and a reverse proxy with automatic HTTPS.

> The files in this repository are published automatically with each Leera
> release. `install.sh`, `docker-compose.yml` and `Caddyfile` are generated —
> edit your local copy under `~/leera`, not this repository.

## Requirements

- A Linux host, and either root or `sudo` on it. **Docker is not a
  prerequisite** — the installer installs Docker Engine and the Compose plugin
  itself if they are missing, after asking.
- Ports **80** and **443** free — the proxy is the only thing that binds
  publicly; the API, database and object store stay on an internal network
- For HTTPS: a domain with a DNS **A record already pointing at this server**.
  Certificates are issued on first start, and that fails if DNS is not live yet.
- **25 GB of disk**, and 2 GB of RAM. The stack itself is about 1 GB of images
  and starts near-empty; the rest is headroom for your data, and for the fact
  that an upgrade needs room for the new images while the old ones are still
  there. An update refuses to start below 3 GB free rather than fill the disk
  half way through — see [Upgrade](#upgrade).

  Nothing here grows without a bound: container logs are capped, superseded
  images are removed after every successful update, only the newest three
  backups are kept on the server, and the application sweeps its own
  operational logs on a retention schedule. Your own data — tickets, documents,
  uploads — is the only thing that grows, which is as it should be.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/leera-app/leera-selfhost/main/install.sh | bash
```

On a bare server that is the only command: Docker is installed first (via
Docker's own install script), the daemon is started and enabled at boot, and
your user is added to the `docker` group. That group only takes effect at your
next login, so the rest of *this* run goes through `sudo` — nothing to do about
it, and nothing to log out for.

Add `LEERA_INSTALL_DOCKER=yes` to answer the Docker question up front for an
unattended install, or `LEERA_INSTALL_DOCKER=no` to install Docker yourself.

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

## Or let an AI agent do the whole thing

If you would rather not stand up a server by hand, paste the prompt below into
an agent that can run commands on your machine — Claude Code, Cursor, Codex,
anything with terminal access. It asks where you want Leera, provisions the
server, points DNS at it, waits for DNS to actually resolve, runs this
installer, and checks that the result really serves HTTPS before telling you
it is done.

Two things worth knowing first. The agent acts with **your** cloud credentials
on **your** account, so read the plan it shows you — it prices the resources
and waits for a yes before creating any of them. And it never asks you to paste
a secret into a chat window: where it needs access it does not have, it stops
and hands you the exact command to run in your own terminal.

````text
Install Leera (self-hosted) for me, end to end.

Work through these phases in order. Stop and wait for me before anything that
costs money or changes DNS.

PHASE 1 — Ask me where it should run
Ask which of these I want, and do nothing else until I answer:
  (a) AWS — you create the EC2 instance and the Route 53 record
  (b) GCP — you create the Compute Engine VM and the Cloud DNS record
  (c) A server I already have — I give you the host and SSH user
  (d) This machine — local evaluation only, no domain, plain HTTP

PHASE 2 — Get access, without me pasting secrets
Never ask me to type a password, private key, or access key into this chat.
Check what you already have:
  AWS: aws sts get-caller-identity
  GCP: gcloud auth list ; gcloud config get-value project
  SSH: ssh -o BatchMode=yes <user>@<host> true
If a check fails, stop and tell me the exact command to run in my own terminal
(aws configure sso, gcloud auth login, ssh-add ~/.ssh/<key>), then wait for me.
Then ask for the region/project/zone, and the domain I want to use — for
example pm.example.com. Confirm I actually control that domain's DNS.

PHASE 3 — Show me a priced plan before you build anything
List what you will create and the rough monthly cost, then wait for a yes:
  - one Linux VM: 2 vCPU, 4 GB RAM, 25 GB disk, current Ubuntu LTS
    (AWS t3.medium or GCP e2-medium is the right size to start)
  - a firewall rule opening ONLY 22, 80 and 443
  - a static IP, so the address survives a reboot
  - one DNS A record for my domain pointing at that IP
Create nothing outside that list. Do not modify or delete existing VPCs,
instances, security groups or DNS records that you did not create — if the
sensible path needs an existing resource, name it and ask me first.

PHASE 4 — Build it
Provision exactly what I approved, and tag every resource "leera-selfhost" so
it is easy to find and to tear down later. Report the resource IDs as you go.

PHASE 5 — Wait for DNS before installing. This one matters.
The installer requests an HTTPS certificate on first start, and Let's Encrypt
fails if the domain does not already resolve to the server. Do not skip ahead.
Poll until `dig +short <domain>` returns the VM's IP from more than one
resolver, and only then continue. If it has not propagated within 10 minutes,
tell me — do not install anyway and leave me with a broken certificate.

PHASE 6 — Install
SSH to the server and run:
  LEERA_DOMAIN=<domain> LEERA_INSTALL_DOCKER=yes \
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/leera-app/leera-selfhost/main/install.sh)"
Docker does not need to be installed first — the installer handles it. This
pulls images and takes a few minutes.

PHASE 7 — Prove it works. Do not just assert it.
  - cd ~/leera && ./install.sh --status
  - curl -sS -o /dev/null -w '%{http_code}' https://<domain>   → expect 200
  - curl -sSI https://<domain>                                 → no TLS error
If any of those fail, read the logs before reporting anything:
  cd ~/leera && docker compose logs --tail=100 caddy api web
Diagnose and fix it, or tell me plainly what is broken. Never report success
you have not verified.

PHASE 8 — Hand it over
Tell me:
  - the URL, and that THE FIRST ACCOUNT CREATED BECOMES THE ADMINISTRATOR —
    so I should sign up immediately, before anyone else reaches it
  - that everything lives in ~/leera, including the .env holding my secrets
  - how to back up: cd ~/leera && ./install.sh --backup — and that a backup
    only counts once it is copied OFF the server
  - how to upgrade: cd ~/leera && ./install.sh --upgrade
  - every resource you created, so I can delete it if I change my mind

IF YOU HIT A PERMISSION WALL
Do not work around it, and do not quietly give up. Tell me:
  - what you tried, and the exact error
  - which specific IAM permission or role is missing
  - the fastest way for me to grant it — as a command I can paste, AND as
    click-by-click console steps, since I may not have CLI admin rights
  - or, if I would rather do that one step myself, exactly what to click
Then wait for me. A stalled install I can finish beats a half-built one.
````

Nothing in that prompt is privileged: it is the manual process above, written
out. If you prefer to read before you run, everything it does is documented on
this page.

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
