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

# The network the stack runs on, for one-off helper containers.
stack_network() {
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' leera-selfhost-minio 2>/dev/null
}

# Ask the running API what version it is. Empty when it is not up.
api_version() {
  docker exec leera-selfhost-api /bin/sh -c \
    'exec 3<>/dev/tcp/127.0.0.1/8081 && printf "GET /api/v1/instance/status/ HTTP/1.0\r\n\r\n" >&3 && cat <&3' \
    2>/dev/null | tr ',' '\n' | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1
}

wait_for_api() {
  say "waiting for the API"
  for _ in $(seq 1 120); do
    if docker exec leera-selfhost-api /bin/sh -c 'exec 3<>/dev/tcp/127.0.0.1/8081 && printf "GET /api/v1/instance/status/ HTTP/1.0\r\n\r\n" >&3 && head -1 <&3 | grep -q 200' 2>/dev/null; then
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

  say "dumping the database"
  # Custom format: compressed, and restorable selectively if it comes to that.
  docker exec leera-selfhost-db pg_dump -U postgres -Fc leera > "$dest/leera.dump" \
    || fail "pg_dump failed — is the database container running?"

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

  # Object storage (uploaded files, brand assets): large, so it is separate
  # from the three essentials and best-effort.
  # shellcheck disable=SC1091
  . ./.env
  local net
  net="$(stack_network)"
  if [ -n "$net" ] && docker run --rm --network "$net" -v "$dest:/backup" \
      --entrypoint /bin/sh minio/mc:latest -c \
      "mc alias set local http://minio:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null && mc mirror --quiet local/storage /backup/storage" 2>/dev/null; then
    say "copied object storage"
  else
    warn "object storage was not copied — uploaded files are not in this backup"
  fi

  api_version > "$dest/VERSION" 2>/dev/null || true

  cat <<EOF

  ✅  Backup written to $dest

      leera.dump    database
      secret_key    decrypts everything in the dump — keep it with the dump
      .env          container passwords
      storage/      uploaded files (if copied)

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

  say "starting the database only"
  $COMPOSE up -d db
  for _ in $(seq 1 60); do
    docker exec leera-selfhost-db pg_isready -U postgres -d leera >/dev/null 2>&1 && break
    sleep 2
  done

  say "restoring the database"
  # --clean --if-exists: replace a partially populated database rather than
  # merging into it, which would fail on every primary key.
  docker exec -i leera-selfhost-db pg_restore -U postgres -d leera --clean --if-exists < "$src/leera.dump" \
    || warn "pg_restore reported errors — review the output above before trusting this restore"

  say "restoring the secret key"
  $COMPOSE up -d api
  sleep 3
  docker cp "$src/secret_key" leera-selfhost-api:/data/secret_key
  docker exec leera-selfhost-api chmod 600 /data/secret_key 2>/dev/null || true

  if [ -d "$src/storage" ]; then
    say "restoring object storage"
    # shellcheck disable=SC1091
    . ./.env
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

  # Prefer local files when run from a checkout; otherwise download the pinned set.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    cp "$SCRIPT_DIR/docker-compose.yml" ./docker-compose.yml
    cp "$SCRIPT_DIR/Caddyfile" ./Caddyfile
  else
    say "downloading stack files"
    curl -fsSL "$RAW_BASE/docker-compose.yml" -o docker-compose.yml
    curl -fsSL "$RAW_BASE/Caddyfile" -o Caddyfile
  fi

  if [ ! -f .env ]; then
    say "first install — generating secrets"

    # Under `curl … | bash` stdin is the script itself, not a terminal, so a
    # plain `read` would return nothing and silently configure http://localhost
    # on a machine that wanted a real domain. Fall back to the controlling
    # terminal; LEERA_DOMAIN covers genuinely unattended installs.
    DOMAIN="${LEERA_DOMAIN:-}"
    if [ -z "$DOMAIN" ]; then
      if [ -t 0 ]; then
        TTY_IN=""
      elif [ -r /dev/tty ]; then
        TTY_IN="/dev/tty"
      else
        TTY_IN="none"
      fi

      if [ "$TTY_IN" != "none" ]; then
        printf '\033[1;35m[leera]\033[0m Domain for this instance (e.g. pm.example.com).\n'
        printf '        Leave empty for plain HTTP on http://localhost.\n'
        if [ -n "$TTY_IN" ]; then
          read -r -p "        Domain: " DOMAIN < "$TTY_IN" || true
        else
          read -r -p "        Domain: " DOMAIN || true
        fi
      fi
    fi

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
EOF
    chmod 600 .env
  else
    say "existing .env found — keeping current secrets"
  fi

  # shellcheck disable=SC1091
  . ./.env

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
