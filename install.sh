#!/usr/bin/env bash
#
# Leera self-hosted installer and operator tool.
#
#   curl -fsSL https://raw.githubusercontent.com/leera-app/leera-selfhost/main/install.sh | bash
#
# or, from a checkout:  ./deploy/selfhost/install.sh
#
# Commands:
#   (none)              install, or start an existing install
#   --upgrade           back up, pull new images, migrate, restart
#   --backup [DIR]      write a complete, restorable backup
#   --restore DIR       restore from a backup directory
#   --status            show version and container health
#   --help              this text
#
# A "complete" backup is three things — database dump, secret key, and .env.
# Any one of them missing makes the other two useless, which is why backup and
# restore are commands here rather than instructions in a document.

set -euo pipefail

INSTALL_DIR="${LEERA_HOME:-$HOME/leera}"
# The public distribution repo — this source repo is private, so customers can
# never fetch from it. Files live at the root of the dist repo, not under
# deploy/selfhost/. Kept in sync by the release workflow's publish-bundle job.
RAW_BASE="${LEERA_RAW_BASE:-https://raw.githubusercontent.com/leera-app/leera-selfhost/main}"
COMPOSE="docker compose"

# Resolved once, before anything cd's. Deliberately does NOT fall back to $0:
# under `curl … | bash` there is no script on disk, $0 is literally "bash", and
# dirname would yield "." — which, after cd'ing into the install dir, points at
# the install dir itself and makes the installer "copy" its own stale files
# over themselves instead of downloading fresh ones. Empty here is the correct
# signal for "piped, so download".
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi

say()  { printf '\033[1;35m[leera]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[leera]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[leera] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── Shared helpers ───────────────────────────────────────────────────────────

require_docker() {
  command -v docker >/dev/null 2>&1 || fail "docker is not installed — see https://docs.docker.com/engine/install/"
  docker compose version >/dev/null 2>&1 || fail "the docker compose plugin is missing — see https://docs.docker.com/compose/install/"
  docker info >/dev/null 2>&1 || fail "cannot talk to the docker daemon (is it running? do you need sudo?)"
}

require_install() {
  [ -f "$INSTALL_DIR/.env" ] || fail "no install found in $INSTALL_DIR — run install.sh first"
  cd "$INSTALL_DIR"
}

# ── Topology (which containers run) ──────────────────────────────────────────

# Upsert KEY=VALUE in .env. The key moves to the end of the file when it already
# exists; harmless, and it avoids sed over operator-supplied values that can
# contain slashes and ampersands (S3 secret keys routinely do).
env_set() {
  local key="$1" value="$2"
  if [ -f .env ] && grep -q "^${key}=" .env; then
    grep -v "^${key}=" .env > .env.tmp
    printf '%s=%s\n' "$key" "$value" >> .env.tmp
    mv .env.tmp .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
  chmod 600 .env
}

# True when .env defines KEY at all (even as empty). Distinct from "is non-empty"
# because an empty value is meaningful for the endpoint and TLS keys.
env_has() { [ -f .env ] && grep -q "^${1}=" .env; }

# Every install before external-DB/storage support ran the bundled Postgres and
# MinIO, so an .env without the mode keys must mean "bundled" for both. Getting
# this wrong on upgrade would stop starting the operator's database.
backfill_modes() {
  if ! env_has LEERA_DB_MODE; then
    env_set LEERA_DB_MODE bundled
    say "no database mode recorded — assuming the bundled Postgres"
  fi
  if ! env_has LEERA_STORAGE_MODE; then
    env_set LEERA_STORAGE_MODE bundled
    say "no storage mode recorded — assuming the bundled MinIO"
  fi
}

# Translate the two modes into the COMPOSE_PROFILES and Caddyfile that compose
# reads. Always recomputed, so the modes are the single source of truth and the
# two derived keys can never disagree with them.
derive_topology() {
  local db_mode="${LEERA_DB_MODE:-bundled}"
  local storage_mode="${LEERA_STORAGE_MODE:-bundled}"
  local profiles="" caddyfile="Caddyfile"

  case "$db_mode" in
    bundled)  profiles="db-bundled" ;;
    external) profiles="" ;;
    *) fail "LEERA_DB_MODE must be 'bundled' or 'external' (got '$db_mode')" ;;
  esac

  case "$storage_mode" in
    bundled)  profiles="${profiles:+$profiles,}s3-bundled" ;;
    external) caddyfile="Caddyfile.no-storage" ;;
    *) fail "LEERA_STORAGE_MODE must be 'bundled' or 'external' (got '$storage_mode')" ;;
  esac

  # `required: false` in docker-compose.yml is what lets the bundled services be
  # switched off — but it also makes a wrong profile fail OPEN: the project stays
  # valid and the API starts with no database, dying at runtime instead of here.
  # These two checks are the guard rail that turns that into a clear message.
  if [ "$db_mode" = "external" ] && [ -z "${LEERA_PG_HOST:-}" ]; then
    fail "LEERA_DB_MODE=external needs LEERA_PG_HOST set in $INSTALL_DIR/.env"
  fi
  if [ "$storage_mode" = "external" ] && [ -z "${LEERA_S3_BUCKET:-}" ]; then
    fail "LEERA_STORAGE_MODE=external needs LEERA_S3_BUCKET set in $INSTALL_DIR/.env"
  fi
  [ -f "$caddyfile" ] || fail "$caddyfile is missing from $INSTALL_DIR — re-run the installer to fetch the stack files"

  env_set COMPOSE_PROFILES "$profiles"
  env_set LEERA_CADDYFILE "$caddyfile"

  say "topology: database=$db_mode storage=$storage_mode (profiles: ${profiles:-none})"
}

# ── First-run setup wizard ───────────────────────────────────────────────────

# Run the browser wizard and block until it has written install.json.
#
# The wizard runs as a container in its own compose project, with the install
# directory bind-mounted. It never talks to Docker: a service that is reachable
# before any login exists, and whose job is opening connections to hosts named
# in the request body, must not also hold a socket that is root-equivalent on
# this machine. So it writes a file, and this function reads it.
run_wizard() {
  local token
  token="$(openssl rand -hex 16)"

  say "starting the setup wizard"
  # A wizard left behind by an interrupted run still holds port 80 and the
  # container name, which would make this attempt fail with an error about
  # neither. Clear it first — it carries no state worth keeping.
  LEERA_INSTALL_TOKEN=unused $COMPOSE -f compose.installer.yml -p leera-installer down >/dev/null 2>&1 || true
  docker rm -f leera-installer >/dev/null 2>&1 || true

  # Port 80 is free before the stack exists, and the wizard needs it twice over:
  # to be reachable without an SSH tunnel, and to answer the domain check the
  # same way Let's Encrypt will. If something else already holds it, fall back
  # to loopback rather than refusing to install.
  local on_port_80=1
  if ! LEERA_INSTALL_TOKEN="$token" $COMPOSE -f compose.installer.yml -p leera-installer up -d >/dev/null 2>&1; then
    on_port_80=0
    warn "port 80 is in use — setup will be reachable only on this machine, and the domain check is unavailable"
    LEERA_INSTALL_TOKEN="$token" LEERA_INSTALLER_BIND=127.0.0.1:7777 \
      LEERA_DOMAIN_CHECK=unavailable \
      $COMPOSE -f compose.installer.yml -p leera-installer up -d >/dev/null 2>&1 \
      || fail "could not start the setup wizard — check: $COMPOSE -f compose.installer.yml -p leera-installer logs"
  fi

  # Offer every address this machine might be reachable at and let the operator
  # pick, rather than guessing one and being wrong.
  #
  # No single source is sufficient. An external echo service returns the
  # internet-facing address — correct for a cloud VM with a public IP, but for
  # a LAN server or a private VPC subnet it returns the router or NAT gateway,
  # which does not route back here. The interface addresses cover exactly those
  # cases, and cost nothing when the public one is also right.
  local candidates=""
  if [ "$on_port_80" = "1" ]; then
    local public_ip
    public_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$public_ip" ] && candidates="$public_ip"

    local iface_ips=""
    if command -v ip >/dev/null 2>&1; then
      iface_ips="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')"
    elif command -v ifconfig >/dev/null 2>&1; then
      iface_ips="$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.')"
    fi
    for ip in $iface_ips; do
      case " $candidates " in *" $ip "*) ;; *) candidates="${candidates:+$candidates }$ip" ;; esac
    done
    candidates="${candidates:+$candidates }localhost"
  else
    candidates="127.0.0.1:7777"
  fi

  # Tearing the wizard down has to happen even if the operator hits Ctrl-C,
  # or the container keeps the port and the next run cannot bind it.
  # shellcheck disable=SC2064
  trap "LEERA_INSTALL_TOKEN=$token $COMPOSE -f compose.installer.yml -p leera-installer down >/dev/null 2>&1 || true" EXIT INT TERM

  cat <<EOF

  ┌─────────────────────────────────────────────────────────────────────┐
  │  Open one of these in your browser to finish setup.                 │
  │  Whichever address you already use to reach this machine:           │
  │                                                                     │
EOF
  for h in $candidates; do
    printf '  │      http://%s/?token=%s\n' "$h" "$token"
  done
  cat <<EOF
  │                                                                     │
  │  The link contains a one-time key. It works once, expires in an     │
  │  hour, and setup closes itself as soon as you are done.             │
  │                                                                     │
  │  Waiting… (Ctrl-C to cancel)                                        │
  └─────────────────────────────────────────────────────────────────────┘

EOF

  # 60 minutes, matching the wizard's own self-imposed deadline.
  local waited=0
  while [ ! -f install.json ]; do
    if ! docker ps --format '{{.Names}}' | grep -q '^leera-installer$'; then
      # It exits on its own only after a successful submit; anything else is a
      # crash, and the file check below turns that into a clear failure.
      sleep 2
      [ -f install.json ] && break
      fail "the setup wizard stopped before saving. Check: $COMPOSE -f compose.installer.yml -p leera-installer logs"
    fi
    sleep 2
    waited=$((waited + 2))
    [ "$waited" -ge 3600 ] && fail "timed out waiting for setup — re-run ./install.sh to try again"
  done

  say "settings received"
  LEERA_INSTALL_TOKEN="$token" $COMPOSE -f compose.installer.yml -p leera-installer down >/dev/null 2>&1 || true
  trap - EXIT INT TERM
}

# True when this install uses the bundled MinIO. Backup/restore mirror the
# bucket only then — pulling an entire AWS bucket onto local disk is not what
# that code is for, and the operator's own S3 lifecycle rules cover it.
storage_is_bundled() { [ "${LEERA_STORAGE_MODE:-bundled}" = "bundled" ]; }

# The network the stack runs on, for one-off helper containers.
stack_network() {
  # The API is the one container present in every topology; MinIO is absent on
  # an external-storage install, so it cannot be the only thing we ask.
  local net
  for c in leera-selfhost-api leera-selfhost-minio leera-selfhost-db; do
    net="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$c" 2>/dev/null)"
    [ -n "$net" ] && { printf '%s' "$net"; return 0; }
  done
  return 0
}

# ── Database access for backup/restore ───────────────────────────────────────
#
# The bundled Postgres is reachable with `docker exec`; an external one is not
# reachable from the host at all in the general case (private subnet, or only
# routable from inside the compose network). Both paths therefore go through a
# client that sits on the stack network, and the bundled case keeps using the
# container it already has.

# Run a postgres client tool against whichever database this install uses.
# Usage: pg_client_run <tool> [args...]   — stdin/stdout are passed through.
pg_client_run() {
  local tool="$1"; shift
  if [ "${LEERA_DB_MODE:-bundled}" = "bundled" ]; then
    docker exec -i leera-selfhost-db "$tool" -U postgres -d leera "$@"
  else
    local net; net="$(stack_network)"
    # Image is pinned to the same major as the bundled server so dump formats
    # stay compatible between a bundled backup and an external restore.
    # shellcheck disable=SC2086
    docker run --rm -i ${net:+--network "$net"} \
      -e PGPASSWORD="${LEERA_PG_PASSWORD:-}" \
      postgres:17-alpine \
      "$tool" \
        -h "${LEERA_PG_HOST:?LEERA_PG_HOST is not set}" \
        -p "${LEERA_PG_PORT:-5432}" \
        -U "${LEERA_PG_USER:-leera}" \
        -d "${LEERA_PG_DBNAME:-leera}" \
        "$@"
  fi
}

# Ask the running API what version it is. Empty when it is not up.
api_version() {
  docker exec leera-selfhost-api /bin/bash -c \
    'exec 3<>/dev/tcp/127.0.0.1/8081 && printf "GET /api/v1/instance/status/ HTTP/1.0\r\n\r\n" >&3 && cat <&3' \
    2>/dev/null | tr ',' '\n' | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1
}

wait_for_api() {
  say "waiting for the API"
  for _ in $(seq 1 120); do
    if docker exec leera-selfhost-api /bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/8081 && printf "GET /api/v1/instance/status/ HTTP/1.0\r\n\r\n" >&3 && head -1 <&3 | grep -q 200' 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# ── Backup ───────────────────────────────────────────────────────────────────

do_backup() {
  require_docker
  require_install

  local dest="${1:-}"
  [ -n "$dest" ] || dest="$INSTALL_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$dest"
  chmod 700 "$dest"

  # Needed before the first pg_client_run: it decides bundled vs external.
  # shellcheck disable=SC1091
  . ./.env

  say "dumping the database"
  # Custom format: compressed, and restorable selectively if it comes to that.
  pg_client_run pg_dump -Fc > "$dest/leera.dump" \
    || fail "pg_dump failed — is the database reachable?"

  say "copying the secret key"
  # Without this file every encrypted column in the dump is unreadable — LLM
  # keys, SMTP passwords, OAuth secrets — and every session is invalid, since
  # JWTs are signed with it.
  docker cp leera-selfhost-api:/data/secret_key "$dest/secret_key" \
    || fail "could not copy /data/secret_key from the api container"
  chmod 600 "$dest/secret_key"

  say "copying .env"
  cp .env "$dest/.env"
  chmod 600 "$dest/.env"

  # Private-CA bundles and any other key material the stack mounts. Small, and
  # a restore without them produces an instance that cannot reach its database.
  if [ -d ./secrets ] && [ -n "$(ls -A ./secrets 2>/dev/null)" ]; then
    say "copying secrets/"
    cp -R ./secrets "$dest/secrets"
    chmod -R go-rwx "$dest/secrets"
  fi

  # Object storage (uploaded files, brand assets): large, so it is separate
  # from the three essentials and best-effort.
  if storage_is_bundled; then
    local net
    net="$(stack_network)"
    if [ -n "$net" ] && docker run --rm --network "$net" -v "$dest:/backup" \
        --entrypoint /bin/sh minio/mc:latest -c \
        "mc alias set local http://minio:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null && mc mirror --quiet local/storage /backup/storage" 2>/dev/null; then
      say "copied object storage"
    else
      warn "object storage was not copied — uploaded files are not in this backup"
    fi
  else
    say "external object storage — files stay in your bucket, not in this backup"
  fi

  api_version > "$dest/VERSION" 2>/dev/null || true

  cat <<EOF

  ✅  Backup written to $dest

      leera.dump    database
      secret_key    decrypts everything in the dump — keep it with the dump
      .env          container passwords and which services this install runs
      secrets/      private-CA bundles, if this install uses any
      storage/      uploaded files (bundled object storage only)

  Copy the whole directory somewhere off this machine. A backup that lives
  only on the server it backs up is not a backup.
EOF
}

# ── Restore ──────────────────────────────────────────────────────────────────

do_restore() {
  local src="${1:-}"
  [ -n "$src" ] || fail "usage: install.sh --restore <backup-directory>"
  [ -d "$src" ] || fail "$src is not a directory"
  [ -f "$src/leera.dump" ] || fail "$src/leera.dump not found"
  [ -f "$src/secret_key" ] || fail "$src/secret_key not found — the dump cannot be decrypted without it"

  require_docker
  require_install

  warn "This REPLACES the current database and secret key in $INSTALL_DIR."
  if [ -t 0 ]; then
    read -r -p "        Type 'restore' to continue: " CONFIRM || true
    [ "$CONFIRM" = "restore" ] || fail "aborted"
  fi

  if [ -f "$src/.env" ]; then
    say "restoring .env"
    cp "$src/.env" .env
    chmod 600 .env
  fi

  if [ -d "$src/secrets" ]; then
    say "restoring secrets/"
    rm -rf ./secrets && cp -R "$src/secrets" ./secrets
    chmod 700 ./secrets
  fi

  # The backup's .env carries the topology, so re-derive before touching compose.
  backfill_modes
  # shellcheck disable=SC1091
  . ./.env
  derive_topology

  if [ "${LEERA_DB_MODE:-bundled}" = "bundled" ]; then
    say "starting the database only"
    $COMPOSE up -d db
    for _ in $(seq 1 60); do
      docker exec leera-selfhost-db pg_isready -U postgres -d leera >/dev/null 2>&1 && break
      sleep 2
    done
  else
    say "using the external database at ${LEERA_PG_HOST}"
  fi

  say "restoring the database"
  # --clean --if-exists: replace a partially populated database rather than
  # merging into it, which would fail on every primary key.
  pg_client_run pg_restore --clean --if-exists < "$src/leera.dump" \
    || warn "pg_restore reported errors — review the output above before trusting this restore"

  say "restoring the secret key"
  $COMPOSE up -d api
  sleep 3
  docker cp "$src/secret_key" leera-selfhost-api:/data/secret_key
  docker exec leera-selfhost-api chmod 600 /data/secret_key 2>/dev/null || true

  if [ -d "$src/storage" ] && storage_is_bundled; then
    say "restoring object storage"
    local net
    net="$(stack_network)"
    [ -n "$net" ] && docker run --rm --network "$net" -v "$src/storage:/backup" \
      --entrypoint /bin/sh minio/mc:latest -c \
      "mc alias set local http://minio:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null && mc mirror --quiet /backup local/storage" \
      || warn "object storage restore failed — uploads may be missing"
  fi

  say "restarting the stack"
  $COMPOSE up -d
  if wait_for_api; then
    say "restore complete — the API is answering (version $(api_version))"
    say "sign in to confirm: existing sessions survive when the secret key matches"
  else
    fail "the API did not come up. If it exits complaining about SECRET_KEY, the
        restored key does not match the restored database — both must come from
        the same backup. Check: $COMPOSE logs api"
  fi
}

# ── Upgrade ──────────────────────────────────────────────────────────────────

do_upgrade() {
  require_docker
  require_install

  # An install predating external-DB support has no mode keys. Record the
  # bundled defaults before anything reads COMPOSE_PROFILES, or this upgrade
  # would quietly stop starting the operator's own database and object store.
  backfill_modes
  # shellcheck disable=SC1091
  . ./.env
  derive_topology

  local before
  before="$(api_version)"
  say "current version: ${before:-unknown}"

  # An upgrade runs migrations, and migrations are the one thing pulling the
  # old image back will not undo. Back up first, always.
  say "taking a pre-upgrade backup"
  do_backup "$INSTALL_DIR/backups/pre-upgrade-$(date -u +%Y%m%dT%H%M%SZ)" >/dev/null

  say "pulling updated images"
  # A locally built image has nothing to pull from; that is not a failure, it
  # just means the new version is whatever you built.
  $COMPOSE pull || warn "could not pull — continuing with the images already on this machine"

  say "applying migrations and restarting"
  # `up -d` re-runs the one-shot migrate container, which the api waits on.
  $COMPOSE up -d

  if ! wait_for_api; then
    fail "the API did not come up after the upgrade. Check: $COMPOSE logs api migrate
        The pre-upgrade backup is in $INSTALL_DIR/backups/"
  fi

  local after
  after="$(api_version)"
  say "upgrade complete: ${before:-unknown} → ${after:-unknown}"
}

# ── Status ───────────────────────────────────────────────────────────────────

do_status() {
  require_docker
  require_install
  local version
  version="$(api_version)"
  say "version: ${version:-unknown (API not answering)}"
  $COMPOSE ps
}

# ── Install ──────────────────────────────────────────────────────────────────

do_install() {
  require_docker

  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  # Prefer local files when run from a checkout; otherwise download the pinned
  # set. The "$SCRIPT_DIR" != "$PWD" guard keeps a re-run from copying the
  # install dir's own files onto themselves, which cp rejects.
  if [ -n "$SCRIPT_DIR" ] && [ "$SCRIPT_DIR" != "$PWD" ] && [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    cp "$SCRIPT_DIR/docker-compose.yml" ./docker-compose.yml
    cp "$SCRIPT_DIR/compose.installer.yml" ./compose.installer.yml
    cp "$SCRIPT_DIR/Caddyfile" ./Caddyfile
    cp "$SCRIPT_DIR/Caddyfile.no-storage" ./Caddyfile.no-storage
    cp "$SCRIPT_DIR/install.sh" ./install.sh
  else
    say "downloading stack files"
    curl -fsSL "$RAW_BASE/docker-compose.yml" -o docker-compose.yml
    curl -fsSL "$RAW_BASE/compose.installer.yml" -o compose.installer.yml
    curl -fsSL "$RAW_BASE/Caddyfile" -o Caddyfile
    curl -fsSL "$RAW_BASE/Caddyfile.no-storage" -o Caddyfile.no-storage
    # Every operator command (--upgrade, --backup, --restore, --status) is
    # documented as `cd ~/leera && ./install.sh …`, so the script has to land
    # here too. Under `curl … | bash` there is no local copy to copy from.
    #
    # Skipped when we are *already* executing ./install.sh from this directory:
    # bash reads a script lazily by byte offset, so rewriting the file mid-run
    # can make it resume at the wrong place. Download to a temp name and move
    # it into place so the file is never half-written either.
    if [ "$SCRIPT_DIR" != "$PWD" ]; then
      curl -fsSL "$RAW_BASE/install.sh" -o install.sh.tmp
      mv install.sh.tmp install.sh
    fi
  fi
  chmod +x ./install.sh

  # Bind-mounted read-only into api/migrate for a private-CA bundle. Created
  # here so Docker does not create it root-owned on first `up`.
  mkdir -p ./secrets && chmod 700 ./secrets

  if [ ! -f .env ]; then
    say "first install — generating secrets"

    # The browser wizard is the normal path: it asks where the database and
    # files should live and verifies both before anything starts. It is skipped
    # when the answers were supplied as environment variables, which is how
    # unattended and scripted installs work.
    if [ -z "${LEERA_DB_MODE:-}" ] && [ -z "${LEERA_STORAGE_MODE:-}" ] && [ ! -f install.json ]; then
      run_wizard
    fi

    # Answers from the wizard become environment for the rest of this function,
    # so the two paths converge here and the .env template below is written once.
    if [ -f install.secrets.env ]; then
      set -a
      # shellcheck disable=SC1091
      . ./install.secrets.env
      set +a
      rm -f install.secrets.env   # one copy of every secret at rest, in .env
    fi

    DOMAIN="${LEERA_DOMAIN:-}"
    if [ -n "$DOMAIN" ]; then
      PUBLIC_URL="https://$DOMAIN"
    else
      PUBLIC_URL="http://localhost"
    fi

    cat > .env <<EOF
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Keep this file safe:
# a full backup = database dump + the api container's /data volume + this file.
LEERA_DOMAIN=$DOMAIN
LEERA_PUBLIC_URL=$PUBLIC_URL
POSTGRES_PASSWORD=$(openssl rand -hex 24)
MINIO_ROOT_USER=leera
MINIO_ROOT_PASSWORD=$(openssl rand -hex 24)

# Where the images come from. Point these at your own registry, or at images
# you built locally with scripts/build-selfhost-images.sh.
LEERA_IMAGE_REPO=${LEERA_IMAGE_REPO:-ghcr.io/leera-app}
LEERA_VERSION=${LEERA_VERSION:-selfhost}

# What this instance brings its own of: 'bundled' or 'external'. These decide
# which containers run — install.sh turns them into COMPOSE_PROFILES below.
LEERA_DB_MODE=${LEERA_DB_MODE:-bundled}
LEERA_STORAGE_MODE=${LEERA_STORAGE_MODE:-bundled}
EOF

    if [ "${LEERA_DB_MODE:-bundled}" = "external" ]; then
      cat >> .env <<EOF

# External Postgres. Create the database first and let the migrate container
# populate it. An empty LEERA_PG_SSL means TLS is verified against the system
# trust store plus the built-in AWS RDS bundle; 'disable' turns TLS off; set
# LEERA_PG_CA_FILE to a PEM under ./secrets for a private CA.
LEERA_PG_HOST=${LEERA_PG_HOST:-}
LEERA_PG_PORT=${LEERA_PG_PORT:-5432}
LEERA_PG_USER=${LEERA_PG_USER:-leera}
LEERA_PG_PASSWORD=${LEERA_PG_PASSWORD:-}
LEERA_PG_DBNAME=${LEERA_PG_DBNAME:-leera}
# Single-dash: an explicit 'disable' from the setup wizard must survive, while
# an unset value still defaults to verified TLS. Hardcoding this empty silently
# ignored the wizard's "Encrypt the connection" choice.
LEERA_PG_SSL=${LEERA_PG_SSL-}
LEERA_PG_CA_FILE=${LEERA_PG_CA_FILE:-}
EOF
    fi

    if [ "${LEERA_STORAGE_MODE:-bundled}" = "external" ]; then
      # Both endpoint keys are written PRESENT BUT EMPTY on purpose. Empty means
      # "plain AWS S3": the API then signs virtual-hosted URLs against
      # bucket.s3.region.amazonaws.com. Deleting these lines is not equivalent —
      # absent makes the API fall back to this instance's own origin and sign
      # path-style URLs that AWS will never honour. For an S3-compatible store
      # (Wasabi, R2, MinIO elsewhere) set both to that store's URL instead.
      cat >> .env <<EOF

# External object storage.
LEERA_S3_ENDPOINT=${LEERA_S3_ENDPOINT:-}
LEERA_S3_PUBLIC_ENDPOINT=${LEERA_S3_PUBLIC_ENDPOINT:-}
LEERA_S3_BUCKET=${LEERA_S3_BUCKET:-}
LEERA_S3_REGION=${LEERA_S3_REGION:-us-east-1}
LEERA_S3_ACCESS_KEY=${LEERA_S3_ACCESS_KEY:-}
LEERA_S3_SECRET_KEY=${LEERA_S3_SECRET_KEY:-}
LEERA_S3_PATH_STYLE=${LEERA_S3_PATH_STYLE:-}
EOF
    fi

    chmod 600 .env
  else
    say "existing .env found — keeping current secrets"
  fi

  backfill_modes

  # shellcheck disable=SC1091
  . ./.env

  derive_topology

  say "starting the stack (first run downloads images and can take a few minutes)"
  $COMPOSE up -d

  if ! wait_for_api; then
    say "the API did not come up in time. Check logs with:"
    say "    cd $INSTALL_DIR && $COMPOSE logs api migrate"
    exit 1
  fi

  cat <<EOF

  ✅  Leera is running (version $(api_version)).

      Open now and finish setup (the first account becomes the admin):

          ${LEERA_PUBLIC_URL}

  ┌─────────────────────────────────────────────────────────────────────┐
  │  BACKUPS — read this once, thank yourself later                     │
  │                                                                     │
  │  Run:  ./install.sh --backup                                        │
  │                                                                     │
  │  It captures all three things a restore needs: the database dump,   │
  │  the secret key, and this install's .env. Losing the secret key     │
  │  makes every stored credential in the dump unreadable — a database  │
  │  backup on its own will NOT restore this instance.                  │
  │                                                                     │
  │  Copy the backup directory off this machine.                        │
  └─────────────────────────────────────────────────────────────────────┘

  Upgrade later with:   cd $INSTALL_DIR && ./install.sh --upgrade
EOF
}

usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

case "${1:-}" in
  --upgrade) do_upgrade ;;
  --backup)  do_backup "${2:-}" ;;
  --restore) do_restore "${2:-}" ;;
  --status)  do_status ;;
  --help|-h) usage ;;
  "")        do_install ;;
  *)         fail "unknown option: $1 (try --help)" ;;
esac
