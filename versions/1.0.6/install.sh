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
#   --upgrade           back up, download the new version, migrate, restart
#   --backup [DIR]      write a complete, restorable backup
#   --restore DIR       restore from a backup directory
#   --status            show version and container health
#   --qa-runner on|off  start or remove the built-in browser test runner
#   --help              this text
#
# Options for --upgrade:
#   --to VERSION        install a specific version instead of the newest one
#   --refresh-bundle    also update docker-compose.yml, the Caddyfiles and this
#                       script, and let the new script perform the upgrade
#   --skip-backup       external databases only; you are asserting you have one
#   --json-progress     emit machine-readable progress instead of prose
#
# Docker is a prerequisite this script installs itself when it is missing:
# Docker Engine plus the Compose plugin on Linux, Docker Desktop via Homebrew
# on macOS. It asks first; LEERA_INSTALL_DOCKER=yes answers yes ahead of time
# for unattended installs, LEERA_INSTALL_DOCKER=no declines and stops.
#
# If ports 80/443 already belong to a reverse proxy you run yourself, this asks
# and records LEERA_PROXY_MODE=external: Caddy moves to LEERA_PROXY_BIND
# (127.0.0.1:8080) and keeps routing, while your proxy terminates TLS in front
# of it. Set LEERA_PROXY_MODE up front to answer ahead of time. An install in
# that mode writes nginx-leera.conf here, ready to drop into nginx.
#
# A "complete" backup is three things — database dump, secret key, and .env.
# Any one of them missing makes the other two useless, which is why backup and
# restore are commands here rather than instructions in a document.
#
# This script is also what the in-app "Update now" button runs: the updater
# container calls it with --json-progress. There is deliberately no second
# upgrade implementation — the path almost nobody exercises by hand is the one
# that would rot.

set -euo pipefail

# The public distribution repo — this source repo is private, so customers can
# never fetch from it. Kept in sync by the release workflow's publish-bundle job
# through deploy/selfhost/publish-dist.sh, which explains the layout: each
# release's files under versions/<version>/, and at the root only the newest
# install.sh beside stack files frozen for installers up to 0.3.2.
RAW_BASE="${LEERA_RAW_BASE:-https://raw.githubusercontent.com/leera-app/leera-selfhost/main}"
COMPOSE="docker compose"

# The release this copy belongs to, written in when a release is published. A
# copy from a checkout keeps the marker, which is not a version.
BUNDLE_VERSION="${LEERA_BUNDLE_VERSION:-1.0.6}"

# The bundled object store, and the one tool this script uses on it: bucket
# setup, backups, restores and the move off MinIO. Pinned by digest as well as
# tag. Keep in step with docker-compose.yml.
#
# The store was MinIO up to 1.0.4. In September 2026 MinIO withdrew every
# public image of its server and client, from Docker Hub and then from its own
# registry, so a new install could not start and no backup could run. See
# migrate_object_store for how an install that ran MinIO moves across.
OBJECTS_IMAGE="chrislusf/seaweedfs:4.47@sha256:ce9e796f1fe6f06968f4c04bdaf8f678dad9c8acdfef3d244133d71bfa6bf882"
# How that store starts, exactly as the `objects` service in docker-compose.yml
# starts it (that file says why each part is there): refuse to run without
# credentials, give the filer a signing key derived from the S3 secret, then
# hand over to the image's own entrypoint. Only S3 listens beyond loopback.
OBJECTS_START='if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "MINIO_ROOT_USER and MINIO_ROOT_PASSWORD must be set in .env — refusing to serve storage without credentials" >&2
  exit 1
fi
mkdir -p /etc/seaweedfs
printf '"'"'[jwt.filer_signing]\nkey = "%s"\n'"'"' "$(printf '"'"'%s'"'"' "$AWS_SECRET_ACCESS_KEY" | sha256sum | cut -c1-64)" > /etc/seaweedfs/security.toml
chmod 644 /etc/seaweedfs/security.toml
exec /entrypoint.sh "$@"'
OBJECTS_ARGS=(server -ip=127.0.0.1 -ip.bind=127.0.0.1 -s3 -s3.port=9000 -s3.ip.bind=0.0.0.0
  -s3.port.iceberg=0 -s3.port.lance=0 -s3.iam=false)
RCLONE_IMAGE="rclone/rclone:1.75.1@sha256:45401ad7410db1d67ffdb58e19059ad20b0d8e0285a60e38bbec55cc1019c7a5"
# The MinIO container every install up to 1.0.4 ran, and the one-shot that
# made its bucket. Fixed names in those releases' docker-compose.yml.
OLD_MINIO_CONTAINER="leera-selfhost-minio"
OLD_MINIO_INIT_CONTAINER="leera-selfhost-minio-init"
# The store the move copies into, run by hand before the stack files that
# define the `objects` service are in place.
MOVE_CONTAINER="leera-selfhost-objects-move"
# What writes to the store, and so is stopped for the move's last pass: the API
# issues every upload URL and writes files itself; the mail server and the test
# runner write too.
MOVE_WRITERS="leera-selfhost-api leera-selfhost-mx leera-selfhost-qa-runner"

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
# This file, for an upgrade to compare with the installer it downloads.
INSTALLER_PATH="${BASH_SOURCE[0]:-}"
# What this script was invoked with, for handing an upgrade over to a newer
# copy of itself.
ORIGINAL_ARGS=("$@")

# Where the install lives. LEERA_HOME wins; otherwise the directory this script
# is sitting in, but only when that directory is itself an install — both files
# have to be there, so a checkout (docker-compose.yml, no .env) still installs
# to $HOME/leera and a `curl … | bash` (no SCRIPT_DIR at all) still does too.
#
# The "sitting in" case is what makes `sudo ./install.sh --upgrade` work.
# Without it sudo resolves $HOME to /root, and the script says "no install found
# in /root/leera" while standing in the install directory — which is a confusing
# thing to be told, and the reflex it provokes (rerun with sudo) is the reflex
# that produced the root-owned files in the first place.
if [ -n "${LEERA_HOME:-}" ]; then
  INSTALL_DIR="$LEERA_HOME"
elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/.env" ] && [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
  INSTALL_DIR="$SCRIPT_DIR"
else
  INSTALL_DIR="$HOME/leera"
fi

# Upgrade options, set by the dispatcher at the bottom.
JSON_PROGRESS=0
TARGET_VERSION=""
REFRESH_BUNDLE=0
SKIP_BACKUP=0
CURRENT_STEP=""

# Minimal JSON string escaping. Deliberately not jq: this script runs on a bare
# host before anything is installed, and the only characters that reach it are
# our own messages plus docker's output.
json_escape() {
  local s="$*"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/ }
  s=${s//$'\r'/}
  s=${s//$'\n'/ }
  printf '%s' "$s"
}

say()  {
  if [ "$JSON_PROGRESS" = "1" ]; then
    printf '{"event":"log","level":"info","message":"%s"}\n' "$(json_escape "$*")"
  else
    printf '\033[1;35m[leera]\033[0m %s\n' "$*"
  fi
}
warn() {
  if [ "$JSON_PROGRESS" = "1" ]; then
    printf '{"event":"log","level":"warn","message":"%s"}\n' "$(json_escape "$*")"
  else
    printf '\033[1;33m[leera]\033[0m %s\n' "$*"
  fi
}
report_error() {
  if [ "$JSON_PROGRESS" = "1" ]; then
    [ -n "$CURRENT_STEP" ] && printf '{"event":"step","step":"%s","status":"failed"}\n' "$CURRENT_STEP"
    printf '{"event":"log","level":"error","message":"%s"}\n' "$(json_escape "$*")"
  else
    printf '\033[1;31m[leera] ERROR:\033[0m %s\n' "$*" >&2
  fi
}
fail() {
  report_error "$@"
  exit 1
}

# Compose names volumes "<project>_<volume>", and derives the project from the
# directory it runs in: lowercased, with everything outside [a-z0-9_-] dropped.
# Mirrored here so a volume can be looked for before compose is invoked.
#
# The directory has to be the one on the *host*: inside the updater container
# this script runs from a bind mount at /install, which is nobody's project.
# See pin_project_name for what that cost.
compose_project_name() {
  if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
    printf '%s' "$COMPOSE_PROJECT_NAME"
  else
    sanitize_project_name "$(basename "$(host_path "$INSTALL_DIR")")"
  fi
}

# Compose's own normalisation, plus the leading-character rule it enforces
# separately: a project name has to start with a letter or a digit.
sanitize_project_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-' | sed 's/^[^a-z0-9]*//'
}

# Named stages, so the browser can draw a checklist instead of a log. The keys
# are shared with deploy/selfhost/updater/updater.sh; a key added on one side
# and not the other shows as a stage that never starts, which is the harmless
# direction for that to fail.
step() {
  CURRENT_STEP="$1"
  if [ "$JSON_PROGRESS" = "1" ]; then
    printf '{"event":"step","step":"%s","status":"running","message":"%s"}\n' \
      "$1" "$(json_escape "${2:-}")"
  elif [ -n "${2:-}" ]; then
    say "$2"
  fi
}
step_done() {
  if [ "$JSON_PROGRESS" = "1" ]; then
    printf '{"event":"step","step":"%s","status":"done"}\n' "$1"
  fi
  CURRENT_STEP=""
}

# Say where the script stopped whenever a command fails outside an if, && or ||.
#
# set -e stops the script at such a command and says nothing. That is how 0.3.2
# stopped every update started from the admin screen without a single error
# line: the stack-file fingerprint called openssl, the updater image had none,
# the error went to /dev/null, and the update page could only report that the
# installer had exited. Now the same failure names the command, the line and
# the exit status in the log the update page shows.
#
# set -E hands the trap to command substitutions and subshells too, and they
# must ignore it: a substitution that fails is reported once, by the command
# that used it, and one whose failure the script already allows carries on as
# it always did. Only the script's own shell reports and exits.
on_unexpected_error() {
  local code="$1" line="$2" failed="$3" where="${4:-}"
  [ "${BASH_SUBSHELL:-0}" -eq 0 ] || return 0
  trap - ERR
  report_error "install.sh stopped at line $line${where:+ in $where()}: \`$failed\` exited with status $code"
  exit "$code"
}
install_error_trap() {
  set -E
  trap 'on_unexpected_error "$?" "$LINENO" "$BASH_COMMAND" "${FUNCNAME[0]:-}"' ERR
}
install_error_trap

# ── Shared helpers ───────────────────────────────────────────────────────────

# Every fetch of a stack file goes through this.
#
# --connect-timeout is the point of it. raw.githubusercontent.com resolves to
# four anycast addresses, and on networks that blackhole some of them (rather
# than refusing the connection) curl waits out the OS SYN retry — 45-75 seconds
# — before trying the next one. Seven files fetched serially turns that into
# five to nine minutes of a silent terminal, which reads as a hang. Ten seconds
# is far longer than any healthy connect and short enough that walking all four
# addresses still costs less than one blackholed one used to.
#
# --retry covers the other half: a transient failure on the last address should
# start the list over rather than abort an install.
#
# wget is the fallback because the updater image is Alpine, whose BusyBox
# carries wget and nothing else: older updater images have no curl at all, and
# with curl-only fetching every download inside them failed — silently, via the
# best-effort branch of the stack-file refresh — so they never refreshed and
# a UI update recreated caddy from a compose file the host could not mount.
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL \
      --connect-timeout 10 \
      --max-time 120 \
      --retry 3 --retry-delay 2 --retry-connrefused \
      "$@"
    return
  fi
  # Only the `URL -o FILE` form is used in this script; translate it.
  local url="" dest="-"
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) dest="$2"; shift ;;
      *)  url="$1" ;;
    esac
    shift
  done
  wget -q -T 30 -O "$dest" "$url"
}

require_downloader() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || fail "neither curl nor wget is installed, so the stack files cannot be downloaded from $RAW_BASE"
}

# Fetch one bundle file, announcing it first. The announcement is the whole
# point: silence during a slow network is indistinguishable from a hang, and
# this is the only place in an install that can stall for minutes with nothing
# to show for it.
FETCH_INDEX=0
FETCH_TOTAL=0
fetch_bundle_file() {
  local name="$1" dest="${2:-$1}" url
  url="$(bundle_url "$(stamped_bundle_version)" "$name")"
  FETCH_INDEX=$((FETCH_INDEX + 1))
  say "  [$FETCH_INDEX/$FETCH_TOTAL] $name"
  fetch "$url" -o "$dest" || fail "could not download $name from $url
        The stack files are hosted on raw.githubusercontent.com. Check that this
        machine can reach it:
            curl -fsS -o /dev/null -w '%{http_code}\\n' $url"
}

# The release written into this copy when it was published; nothing for a copy
# from a checkout.
stamped_bundle_version() {
  case "$BUNDLE_VERSION" in
    ''|*[!0-9.]*) ;;
    *) printf '%s' "$BUNDLE_VERSION" ;;
  esac
}

# Where one stack file of a release is published. With no version, the root of
# the repo, which is the only place releases up to 0.3.2 put them.
bundle_url() {
  if [ -n "$1" ]; then
    printf '%s/versions/%s/%s' "$RAW_BASE" "$1" "$2"
  else
    printf '%s/%s' "$RAW_BASE" "$2"
  fi
}

# ── Docker bootstrap ─────────────────────────────────────────────────────────
#
# "Install Docker first, then run this" is a second command, on a fresh server,
# for something this script can do itself. So it does: a missing Docker Engine
# or Compose plugin is installed here, and the promise on the README — one
# command — is true on a bare host.

# Every docker call in this script goes through this wrapper, including the ones
# inside "$COMPOSE" (bash resolves the function before the PATH binary).
#
# It exists for the gap right after an install: adding the operator to the
# `docker` group only takes effect at their next login, and telling someone to
# log out halfway through an install is not an install. So we use sudo for the
# rest of this run instead. -E because prefix assignments — the wizard's
# LEERA_INSTALL_TOKEN, LEERA_VERSION — must survive into compose, and sudo
# scrubs the environment by default.
DOCKER_SUDO=0
docker() {
  if [ "$DOCKER_SUDO" = "1" ]; then
    # shellcheck disable=SC2033  # the argument is the docker binary, not this function
    command sudo -E docker "$@"
  else
    command docker "$@"
  fi
}

# `type -P` and not `command -v`: the function above makes `command -v docker`
# succeed on a host with no docker binary at all.
have_docker() { type -P docker >/dev/null 2>&1; }

# Set SUDO to whatever prefix gives us root, or fail the caller.
SUDO=""
need_root() {
  [ "$(id -u)" = "0" ] && { SUDO=""; return 0; }
  command -v sudo >/dev/null 2>&1 || return 1
  # sudo reads its password from /dev/tty, not stdin, so this still works under
  # `curl … | bash`, where stdin is the script.
  sudo -n true 2>/dev/null || say "root is needed to install Docker — sudo may ask for your password"
  sudo true || return 1
  SUDO="sudo"
}

# Ask before installing system packages. Under `curl … | bash` stdin is the
# script itself, so reading from it would swallow the rest of this file — the
# question goes to /dev/tty.
confirm_docker_install() {
  case "${LEERA_INSTALL_DOCKER:-ask}" in
    yes|1|true) return 0 ;;
    no|0|false) return 1 ;;
  esac
  # The updater container is nobody's terminal, and it has Docker already.
  [ "$JSON_PROGRESS" = "1" ] && return 1

  local reply=""
  if [ -r /dev/tty ]; then
    printf '\033[1;35m[leera]\033[0m %s [Y/n] ' "$1" > /dev/tty
    read -r reply < /dev/tty || reply=""
  else
    say "$1 — no terminal to ask on, continuing"
    return 0
  fi
  case "$reply" in ""|y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

DOCKER_DOCS="https://docs.docker.com/engine/install/"

install_docker_linux() {
  need_root || fail "Docker is not installed, and this script cannot install it without root.
        Run it as root, or install Docker yourself and try again:
            $DOCKER_DOCS"

  say "installing Docker Engine and the Compose plugin"

  # Docker's own convenience script, which is what their docs point at for
  # exactly this case. It covers Debian/Ubuntu/RHEL/Fedora/CentOS/SLES and
  # installs the compose plugin with the engine, so one download settles both.
  local tmp
  tmp="$(mktemp)"
  if curl -fsSL https://get.docker.com -o "$tmp" && $SUDO sh "$tmp"; then
    rm -f "$tmp"
  else
    rm -f "$tmp"
    # Distros get.docker.com does not support, but which package Docker anyway.
    if command -v apk >/dev/null 2>&1; then
      $SUDO apk add --no-cache docker docker-cli-compose \
        || fail "could not install Docker with apk — see $DOCKER_DOCS"
    elif command -v pacman >/dev/null 2>&1; then
      $SUDO pacman -Sy --noconfirm docker docker-compose \
        || fail "could not install Docker with pacman — see $DOCKER_DOCS"
    else
      fail "Docker's installer did not run on this distribution.
        Install Docker Engine and the Compose plugin by hand, then run this
        script again:
            $DOCKER_DOCS"
    fi
  fi

  have_docker || fail "Docker still is not on PATH after installing it — see $DOCKER_DOCS"
  start_docker_daemon
  say "installed $(command docker --version 2>/dev/null || echo docker)"
}

install_docker_macos() {
  command -v brew >/dev/null 2>&1 || fail "Docker Desktop is not installed. This script installs Docker on Linux
        servers only; on a Mac, install Docker Desktop and start it first:
            https://docs.docker.com/desktop/install/mac-install/"

  say "installing Docker Desktop with Homebrew"
  brew install --cask docker || fail "brew install --cask docker failed — install Docker Desktop by hand:
            https://docs.docker.com/desktop/install/mac-install/"

  start_docker_daemon
  command docker info >/dev/null 2>&1 || fail "Docker Desktop was installed but its engine did not start. Open it once
        from Applications, finish its first-run prompts, then run this again."
}

install_docker() {
  case "$(uname -s)" in
    Linux)  install_docker_linux ;;
    Darwin) install_docker_macos ;;
    *)      fail "no automatic Docker install for $(uname -s) — see $DOCKER_DOCS" ;;
  esac
}

# Bring the daemon up if it is installed but not running. A packaged install
# leaves it disabled on some distros, which otherwise looks identical to a
# permissions problem.
start_docker_daemon() {
  command docker info >/dev/null 2>&1 && return 0

  # Reachable as root means the daemon is fine and this is only a group
  # membership problem, which resolve_docker_access sorts out. Restarting a
  # healthy daemon underneath a running instance would be a poor way to find
  # that out. -n so the probe never sits on a password prompt of its own.
  if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
    # shellcheck disable=SC2033  # sudo runs the docker binary, not this function
    sudo -n docker info >/dev/null 2>&1 && return 0
  fi

  # A Mac has no service manager to ask and no docker group to be missing from:
  # the engine is Docker Desktop, so the only thing to do is launch it.
  if [ "$(uname -s)" = "Darwin" ]; then
    say "waiting for Docker Desktop to start"
    open -a Docker 2>/dev/null || true
    local mac_waited=0
    while [ "$mac_waited" -lt 180 ]; do
      command docker info >/dev/null 2>&1 && return 0
      sleep 3
      mac_waited=$((mac_waited + 3))
    done
    return 0
  fi

  need_root || return 0

  if command -v systemctl >/dev/null 2>&1; then
    say "starting the docker service"
    $SUDO systemctl enable --now docker >/dev/null 2>&1 \
      || $SUDO systemctl start docker >/dev/null 2>&1 || true
  elif command -v rc-service >/dev/null 2>&1; then
    say "starting the docker service"
    $SUDO rc-update add docker default >/dev/null 2>&1 || true
    $SUDO rc-service docker start >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    say "starting the docker service"
    $SUDO service docker start >/dev/null 2>&1 || true
  fi

  local waited=0
  while [ "$waited" -lt 60 ]; do
    command docker info >/dev/null 2>&1 && return 0
    $SUDO docker info >/dev/null 2>&1 && return 0
    sleep 2
    waited=$((waited + 2))
  done
  return 0
}

# Decide how the rest of this script reaches the daemon: directly, or via sudo.
resolve_docker_access() {
  command docker info >/dev/null 2>&1 && { DOCKER_SUDO=0; return 0; }

  [ "$(id -u)" = "0" ] && return 1
  command -v sudo >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2033  # ditto: sudo resolves docker from PATH
  sudo docker info >/dev/null 2>&1 || return 1

  # Without -E the wizard token and version pins never reach compose, and the
  # failure would surface as an unrelated interpolation error much later.
  sudo -E true 2>/dev/null || fail "Docker here works only through sudo, and this sudo will not preserve the
        environment. Add yourself to the docker group instead, log out and back
        in, then run this again:
            sudo usermod -aG docker $(id -un)"

  SUDO="sudo"
  DOCKER_SUDO=1
  # Membership takes effect at next login, so it does not help this run — it is
  # what makes the *next* one, and plain `docker ps`, work without sudo.
  if ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    # usermod on glibc distros, addgroup on Alpine/BusyBox.
    if $SUDO usermod -aG docker "$(id -un)" 2>/dev/null \
       || $SUDO addgroup "$(id -un)" docker 2>/dev/null; then
      warn "added $(id -un) to the 'docker' group — effective at your next login."
      warn "until then this script talks to Docker through sudo."
    else
      warn "using sudo for Docker: $(id -un) is not in the 'docker' group."
    fi
  fi
  return 0
}

install_compose_plugin() {
  need_root || fail "the Docker Compose plugin is missing and cannot be installed without root — see
            https://docs.docker.com/compose/install/"

  say "installing the Docker Compose plugin"
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq >/dev/null 2>&1 || true
    $SUDO apt-get install -y docker-compose-plugin >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y docker-compose-plugin >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y docker-compose-plugin >/dev/null 2>&1 || true
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper --non-interactive install docker-compose >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add --no-cache docker-cli-compose >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -Sy --noconfirm docker-compose >/dev/null 2>&1 || true
  fi
  docker compose version >/dev/null 2>&1 && return 0

  # No package, or a distro that ships only the deprecated v1 script. The plugin
  # is a single static binary, so fetching it directly is the reliable path.
  local arch dest tmp
  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    armv7l|armv7)  arch=armv7 ;;
    *) fail "no Compose plugin build for $(uname -m) — see https://docs.docker.com/compose/install/" ;;
  esac
  dest=/usr/local/lib/docker/cli-plugins
  tmp="$(mktemp)"
  say "downloading the Compose plugin binary"
  curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$arch" -o "$tmp" \
    || { rm -f "$tmp"; fail "could not download the Compose plugin — see https://docs.docker.com/compose/install/"; }
  $SUDO mkdir -p "$dest"
  $SUDO install -m 0755 "$tmp" "$dest/docker-compose" \
    || { rm -f "$tmp"; fail "could not install the Compose plugin into $dest"; }
  rm -f "$tmp"
}

require_docker() {
  if ! have_docker; then
    confirm_docker_install "Docker is not installed. Install Docker Engine and the Compose plugin now?" \
      || fail "Docker is required. Install it and run this again:
            $DOCKER_DOCS
        (or re-run with LEERA_INSTALL_DOCKER=yes to install it unattended)"
    install_docker
  fi

  start_docker_daemon
  resolve_docker_access || fail "cannot talk to the docker daemon (is it running? do you need sudo?)"

  if ! docker compose version >/dev/null 2>&1; then
    confirm_docker_install "The Docker Compose plugin is missing. Install it now?" \
      || fail "the docker compose plugin is missing — see https://docs.docker.com/compose/install/"
    install_compose_plugin
    docker compose version >/dev/null 2>&1 \
      || fail "the docker compose plugin is still missing after installing it — see
            https://docs.docker.com/compose/install/"
  fi
}

# Files `docker cp` and bind-mounted helpers create belong to root whenever we
# are going through sudo. Hand them back, or the operator cannot chmod their own
# backup — and the very next line of do_backup does exactly that.
reclaim_path() {
  [ "$DOCKER_SUDO" = "1" ] || return 0
  sudo chown -R "$(id -u):$(id -g)" "$1" 2>/dev/null || true
}

require_install() {
  [ -f "$INSTALL_DIR/.env" ] || fail "no install found in $INSTALL_DIR — run install.sh first"

  # An update performed from the admin UI runs this script as root inside the
  # updater container, and .env is rewritten by replacing it — so it comes back
  # owned by root, on a file the operator's own user then cannot read. Left to
  # itself that surfaces as a bare "grep: .env: Permission denied" from three
  # different places and no indication of what to do about it.
  if [ ! -r "$INSTALL_DIR/.env" ] || [ ! -w "$INSTALL_DIR/.env" ]; then
    fail "$INSTALL_DIR/.env is not readable and writable by $(id -un).
        An update run from the admin UI leaves it owned by root. Take it back:

            sudo chown -R $(id -un):$(id -gn) $INSTALL_DIR

        Then run this again as yourself. Running it under sudo instead would
        work, and would leave these files owned by root all over again."
  fi

  cd "$INSTALL_DIR"
  # Before any compose command in any subcommand: which stack is this, and
  # where does the host keep it?
  pin_project_name
  pin_host_install_dir
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

# Remove KEY from .env altogether.
env_unset() {
  [ -f .env ] && grep -q "^${1}=" .env || return 0
  grep -v "^${1}=" .env > .env.tmp
  mv .env.tmp .env
  chmod 600 .env
}

# True when .env defines KEY at all (even as empty). Distinct from "is non-empty"
# because an empty value is meaningful for the endpoint and TLS keys.
env_has() { [ -f .env ] && grep -q "^${1}=" .env; }

# The value of KEY in .env, empty when unset. env_set keeps one line per key;
# the tail is there for a file an operator has edited by hand.
env_get() { [ -f .env ] && sed -n "s/^${1}=//p" .env | tail -1; }

# The compose project the running stack is already filed under, asked of Docker
# rather than guessed from a path. Empty when none of it is up.
#
# Authoritative in a way that deriving from a directory is not: these container
# names are fixed in docker-compose.yml, so whichever project owns them is the
# project this install actually is.
running_project_name() {
  local c name
  for c in leera-selfhost-api leera-selfhost-db leera-selfhost-caddy \
           leera-selfhost-web leera-selfhost-updater; do
    name="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' \
      "$c" 2>/dev/null || true)"
    [ -n "$name" ] && { printf '%s' "$name"; return 0; }
  done
  return 0
}

# Pin the compose project name in .env, so both ways of starting an upgrade
# address the same stack.
#
# Compose derives the project from the directory it runs in, and that directory
# is not the same on the two paths. An operator runs this from the install
# directory, so the project is (say) "leera". The updater container runs the
# very same script from its bind mount, so the project is "install" — a second,
# empty project laid over the same files. `compose pull` does not care about
# projects, which is exactly why the download and verify steps still passed;
# then `compose up -d migrate` went to create that second project's containers
# and collided with the running stack's fixed container_names. What the operator
# saw was "the database migrator could not be started" and an empty
# `compose logs migrate` — empty because in project "install" there is no such
# container to have logs.
#
# The collision is the only thing that kept this from being much worse. Without
# the fixed names, an update from the admin UI would have brought a second stack
# up on fresh, empty volumes beside the real data.
#
# .env is where compose reads the name on both paths. An existing install keeps
# whatever name its containers already carry: recomputing it from a path could
# rename a live stack and orphan every volume it has.
pin_project_name() {
  local name=""
  env_has COMPOSE_PROJECT_NAME && name="$(env_get COMPOSE_PROJECT_NAME)"
  if [ -z "$name" ]; then
    name="$(running_project_name)"
    [ -n "$name" ] || name="$(compose_project_name)"
    [ -n "$name" ] || name=leera
    env_set COMPOSE_PROJECT_NAME "$name"
    say "recorded this install as compose project '$name'"
  fi
  export COMPOSE_PROJECT_NAME="$name"
}

# Record the install directory as the *host* sees it.
#
# Compose resolves a relative bind mount against the directory it runs in, but
# the daemon resolves the result against the host filesystem. Those are the same
# place when an operator runs compose themselves, and are not when the updater
# container runs it: there the directory is /install, which does not exist on
# the host. The daemon then auto-creates it — as a *directory* — and the mount
# either fails loudly (Caddyfile: a directory onto a file) or succeeds against
# an empty one, which is worse. `./secrets` did the latter, so an update driven
# from the UI could bring the API up with no secret key and report success.
#
# So the compose file mounts ${LEERA_HOST_INSTALL_DIR}/… and this pins the value
# once, in .env, where compose reads it from either context.
#
# Never recomputed from $INSTALL_DIR when it is already set: inside the updater
# that would rewrite the correct host path with /install and break the *next*
# update instead of this one.
pin_host_install_dir() {
  local dir="${LEERA_HOST_INSTALL_DIR:-}"
  [ -n "$dir" ] || { env_has LEERA_HOST_INSTALL_DIR && dir="$(env_get LEERA_HOST_INSTALL_DIR)"; }
  if [ -z "$dir" ]; then
    dir="$INSTALL_DIR"
    say "recorded the host install directory as '$dir'"
  fi
  env_set LEERA_HOST_INSTALL_DIR "$dir"
  export LEERA_HOST_INSTALL_DIR="$dir"
}

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
    say "no storage mode recorded — assuming the bundled object store"
  fi
  # Installs predating the update service default to running it: that is the
  # whole point of it existing, and an operator who does not want a container
  # holding the Docker socket sets LEERA_UPDATER=off here.
  if ! env_has LEERA_UPDATER; then
    env_set LEERA_UPDATER on
  fi
  # Every install predating external-proxy support ran the bundled Caddy on 80/443,
  # because that was the only thing the stack could do. Anything else would change
  # where a working install listens on its next upgrade.
  if ! env_has LEERA_PROXY_MODE; then
    env_set LEERA_PROXY_MODE bundled
  fi
  # Only read in external mode. Recorded regardless so an operator moving an install
  # behind a proxy has the knob in front of them, already at a sane value.
  #
  # Loopback by default: it is what keeps "the API is unreachable from outside, so
  # forwarded headers can only arrive through the proxy" true. An operator whose own
  # proxy runs in a container (where a host loopback port is unreachable) sets this
  # to 0.0.0.0:8080 or attaches their proxy to this project's network.
  if ! env_has LEERA_PROXY_BIND; then
    env_set LEERA_PROXY_BIND 127.0.0.1:8080
  fi
}

# Translate a path in *this* filesystem to the equivalent on the Docker host.
#
# Only differs when this script is running inside the updater container: a
# `docker run -v` bind mount is resolved by the daemon against the host, so
# passing /install/backups/... would mount a path that does not exist there and
# silently produce an empty backup.
host_path() {
  local p="$1"
  if [ -n "${LEERA_HOST_INSTALL_DIR:-}" ]; then
    printf '%s' "${p/#$INSTALL_DIR/$LEERA_HOST_INSTALL_DIR}"
  else
    printf '%s' "$p"
  fi
}

# Translate the two modes into the COMPOSE_PROFILES and Caddyfile that compose
# reads. Always recomputed, so the modes are the single source of truth and the
# two derived keys can never disagree with them.
derive_topology() {
  local db_mode="${LEERA_DB_MODE:-bundled}"
  local storage_mode="${LEERA_STORAGE_MODE:-bundled}"
  local profiles="" caddyfile="Caddyfile"
  # What .env said before this function overwrites it. The list built below is
  # derived purely from the mode keys, so it can never contain `mx` — that profile
  # only ever arrives by an operator editing COMPOSE_PROFILES by hand, and the
  # warning at the end has to look at what they wrote, not at what we computed.
  local prior_profiles="${COMPOSE_PROFILES:-}"

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

  case "${LEERA_UPDATER:-on}" in
    on)  profiles="${profiles:+$profiles,}updater" ;;
    off) ;;
    *) fail "LEERA_UPDATER must be 'on' or 'off' (got '${LEERA_UPDATER:-}')" ;;
  esac

  case "${LEERA_QA_RUNNER:-off}" in
    on)
      [ -n "${LEERA_QA_RUNNER_TOKEN:-}" ] \
        || fail "LEERA_QA_RUNNER=on needs LEERA_QA_RUNNER_TOKEN (a runner pool token) set in $INSTALL_DIR/.env"
      profiles="${profiles:+$profiles,}qa-runner"
      ;;
    off) ;;
    *) fail "LEERA_QA_RUNNER must be 'on' or 'off' (got '${LEERA_QA_RUNNER:-}')" ;;
  esac

  # Who owns :80 and :443. In `external` the operator's own reverse proxy does, and
  # Caddy moves to a loopback port behind it — still routing every path, just not
  # holding the front door. See the header of Caddyfile for why Caddy stays in the
  # picture at all rather than handing seven routes to somebody else's config.
  local http_ports https_ports caddy_site
  case "${LEERA_PROXY_MODE:-bundled}" in
    bundled)
      # These two must reproduce what the compose file said before these keys
      # existed, byte for byte. `0.0.0.0:80:80` would not: it pins IPv4, where a
      # bare `80:80` also binds IPv6 when the daemon has it on.
      http_ports="80:80"
      https_ports="443:443"
      caddy_site="${LEERA_DOMAIN:-:80}"
      ;;
    external)
      http_ports="${LEERA_PROXY_BIND:-127.0.0.1:8080}:80"
      # Published but unreachable, and unused: compose cannot drop a port entry by
      # profile, so it goes to loopback rather than being removed. Caddy serves no
      # TLS in this mode — the proxy in front already terminated it.
      https_ports="127.0.0.1:8443:443"
      # A bare port, never a hostname. This is what stops Caddy attempting ACME:
      # it cannot answer a challenge on ports it no longer holds, and a named site
      # would have it retrying issuance forever.
      caddy_site=":80"
      ;;
    *) fail "LEERA_PROXY_MODE must be 'bundled' or 'external' (got '${LEERA_PROXY_MODE:-}')" ;;
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
  # The bundled store refuses to start without them (with no identity at all it
  # would serve every file to anyone), so say which line is missing here rather
  # than leave the API waiting on a store that never becomes healthy.
  if [ "$storage_mode" = "bundled" ] && { [ -z "${MINIO_ROOT_USER:-}" ] || [ -z "${MINIO_ROOT_PASSWORD:-}" ]; }; then
    fail "the bundled object store needs MINIO_ROOT_USER and MINIO_ROOT_PASSWORD set in $INSTALL_DIR/.env"
  fi
  [ -f "$caddyfile" ] || fail "$caddyfile is missing from $INSTALL_DIR — re-run the installer to fetch the stack files"

  env_set COMPOSE_PROFILES "$profiles"
  env_set LEERA_CADDYFILE "$caddyfile"
  env_set LEERA_HTTP_PORTS "$http_ports"
  env_set LEERA_HTTPS_PORTS "$https_ports"
  env_set LEERA_CADDY_SITE "$caddy_site"

  # Inbound mail needs a certificate for the MX hostname, and in external mode
  # nothing here issues one: Caddy is not doing ACME, so tls::acceptor finds no
  # certificate, STARTTLS is never advertised, and mail is delivered in the clear —
  # which is what gets a domain flagged by Google and Microsoft. Silent is the one
  # thing that must not happen, so say so on every install and upgrade.
  case ",$prior_profiles," in
    *,mx,*)
      if [ "${LEERA_PROXY_MODE:-bundled}" = "external" ]; then
        warn "inbound email is enabled but this install sits behind your own reverse proxy,
        so nothing here can obtain a certificate for the MX hostname. Mail would be
        accepted WITHOUT encryption, which large providers penalise. Inbound email is
        supported on a bundled install — run it on its own instance if you need it."
      fi
      ;;
  esac

  say "topology: database=$db_mode storage=$storage_mode proxy=${LEERA_PROXY_MODE:-bundled} (profiles: ${profiles:-none})"
}

# Is something already listening on this TCP port?
#
# 0 = yes, 1 = no, 2 = could not tell. The third answer is the point: this script
# runs on whatever the operator happens to have, and a probe that guessed "free"
# where it cannot see would hand them the compose error we are trying to replace.
# Every caller treats 2 the same as "no" — act only on what we actually observed.
#
# No single tool is everywhere. The updater image is Alpine, whose BusyBox has
# netstat but neither ss nor lsof; macOS has lsof and netstat but no ss. Same
# command -v ladder as the interface probe in run_wizard, for the same reason.
port_in_use() {
  local port="$1"
  # Column 4 is the local address, in any of `0.0.0.0:80`, `[::]:80`, `*:80` or
  # macOS netstat's `*.80` — hence the [:.] rather than a colon.
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then return 0; fi
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then return 0; fi
    return 1
  fi
  if command -v netstat >/dev/null 2>&1; then
    if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then return 0; fi
    return 1
  fi
  return 2
}

# A best-effort name for whatever holds port 80, so the question below can say
# "nginx" instead of "something". Empty is a fine answer; this never fails.
listener_name() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -sS -o /dev/null -D - --max-time 3 http://127.0.0.1/ 2>/dev/null \
    | sed -n 's/^[Ss]erver: *//p' | tr -d '\r' | head -1
}

# Ask a yes/no question, with an explicit answer for every way there may be nobody
# to ask. Mirrors confirm_docker_install's contract: the updater container first,
# then /dev/tty rather than stdin — under `curl … | bash` stdin is the script body,
# and reading it would swallow the rest of the file.
#
# $1 question, $2 answer to use when there is no one to ask (0 = yes, 1 = no).
ask_yes_no() {
  local question="$1" fallback="$2" reply=""
  # Try to OPEN it, rather than trusting `[ -r /dev/tty ]`. The node can exist and
  # look readable while the open still fails with "Device not configured" — every
  # detached context does this — and the -r test would then wave us through to a
  # printf and a read that both fail noisily before landing on the fallback anyway.
  if [ "$JSON_PROGRESS" = "1" ] || ! { : < /dev/tty; } 2>/dev/null; then
    say "$question — no terminal to ask on"
    return "$fallback"
  fi
  printf '\033[1;35m[leera]\033[0m %s [Y/n] ' "$question" > /dev/tty
  read -r reply < /dev/tty || reply=""
  case "$reply" in ""|y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# Does this machine already have a reverse proxy in front of us?
#
# FRESH INSTALLS ONLY. On --upgrade the thing holding 80/443 is our own caddy, so
# probing there would flip every healthy install to external mode on its next
# upgrade. An existing install's mode lives in .env and nothing may change it
# behind the operator's back.
detect_external_proxy() {
  local busy=""
  if port_in_use 80;  then busy="80"; fi
  if port_in_use 443; then busy="${busy:+$busy and }443"; fi
  [ -n "$busy" ] || return 0

  local wanted
  wanted="${LEERA_PROXY_MODE:-}"
  case "$wanted" in
    external) return 0 ;;
    bundled)
      fail "port $busy is in use, but LEERA_PROXY_MODE=bundled means this install wants
        to own it. Free the port, or set LEERA_PROXY_MODE=external to run behind the
        server already there."
      ;;
  esac

  local who question
  who="$(listener_name)"
  question="Port $busy is already in use${who:+, by $who}.
        Are you putting Leera behind a reverse proxy you already run here?"

  # Nobody to ask: take the external answer. On a fresh install a busy port 80 is
  # strong evidence of an existing web server, and the alternative is exactly what
  # happened to one customer — the stack cannot bind, compose rolls back, and the
  # install is quietly abandoned half-finished.
  #
  # Note this is the opposite of confirm_docker_install's no-terminal default, and
  # deliberately so: there, carrying on is the conservative answer; here, carrying
  # on as bundled is the one thing that cannot work.
  if ask_yes_no "$question" 0; then
    export LEERA_PROXY_MODE=external
    say "using your reverse proxy — Leera will listen on ${LEERA_PROXY_BIND:-127.0.0.1:8080}"
  else
    fail "port $busy is in use and a bundled install needs it.
        Free the port and run this again, or re-run with LEERA_PROXY_MODE=external to
        put Leera behind the server you already have there."
  fi
}

# Mail is optional, so this warns rather than failing. Fresh installs only, and only
# when the operator asked for mx: on an upgrade the thing holding 25 is our own
# container. Worth saying because Ubuntu images so often ship postfix already
# listening, and the alternative is an opaque compose error much later.
check_mail_port() {
  case ",${COMPOSE_PROFILES:-}," in
    *,mx,*) ;;
    *) return 0 ;;
  esac
  if port_in_use 25; then
    warn "port 25 is already in use — Ubuntu images often ship postfix or exim running.
        Inbound email will not start until that port is free."
  fi
}

# Write the nginx server block for an external-proxy install, with this install's
# domain and port already filled in.
#
# Generated rather than shipped: it is per-install, so it must NOT join
# BUNDLE_FILES or record_bundle_hashes would report every install as drifted.
#
# Deliberately plain HTTP with no ssl_certificate lines. `certbot --nginx` rewrites
# this block to add the certificate and the redirect, and it can only do that if the
# block loads first — a file naming certificate paths that do not exist yet fails
# `nginx -t`, which is where an operator following these instructions would stop.
write_nginx_conf() {
  local domain="${LEERA_DOMAIN:-leera.example.com}"
  local upstream="${LEERA_PROXY_BIND:-127.0.0.1:8080}"

  cat > nginx-leera.conf <<EOF
# Leera, behind the nginx you already run. Generated by install.sh.
#
# Everything goes to one upstream: the Caddy inside the Leera stack, which does the
# path routing (/api, /storage, /_leera/update and the rest). That is on purpose —
# those routes have sharp edges (the /storage prefix is part of an S3 signature, the
# AI stream must not be buffered) and they change between releases. Leave the single
# proxy_pass alone and this file never needs revisiting.

# Named for this file so it cannot collide with a map you already have.
map \$http_upgrade \$leera_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    # Caddy applies no request body limit, so neither does this: uploads go through
    # /storage/* to object storage and can be large. Set a number here if you want
    # one — it will apply to attachments.
    client_max_body_size 0;

    location / {
        proxy_pass http://$upstream;
        proxy_http_version 1.1;

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket upgrades.
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$leera_connection_upgrade;

        # The AI response stream is server-sent events. Buffering it here would
        # hold tokens back and deliver the reply in one lump at the end.
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
}
EOF
  say "wrote nginx-leera.conf for $domain"
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

  # The wizard writes install.json and install.secrets.env into this directory
  # through a bind mount, and this script reads them back straight afterwards.
  # A container writing as root would leave both files unreadable to whoever
  # ran the install, so it is told to write as that person instead.
  local install_uid
  install_uid="$(id -u):$(id -g)"
  export LEERA_INSTALL_UID="$install_uid"

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
  # In external mode detect_external_proxy has already established that the
  # operator's own proxy holds :80. Attempting the bind just to watch it fail would
  # print a warning contradicting the answer they gave a moment ago.
  if [ "${LEERA_PROXY_MODE:-bundled}" = "external" ]; then
    on_port_80=0
  elif ! LEERA_INSTALL_TOKEN="$token" $COMPOSE -f compose.installer.yml -p leera-installer up -d >/dev/null 2>&1; then
    on_port_80=0
    warn "port 80 is in use — setup will be reachable only on this machine, and the domain check is unavailable"
  fi
  if [ "$on_port_80" = "0" ]; then
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
  local public_ip=""
  local iface_ips=""
  if [ "$on_port_80" = "1" ]; then
    public_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"

    local raw_iface_ips=""
    if command -v ip >/dev/null 2>&1; then
      raw_iface_ips="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')"
    elif command -v ifconfig >/dev/null 2>&1; then
      raw_iface_ips="$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.')"
    fi
    for ip in $raw_iface_ips; do
      [ "$ip" = "$public_ip" ] && continue
      case " $iface_ips " in *" $ip "*) ;; *) iface_ips="${iface_ips:+$iface_ips }$ip" ;; esac
    done
  fi

  # Tearing the wizard down has to happen even if the operator hits Ctrl-C,
  # or the container keeps the port and the next run cannot bind it.
  # shellcheck disable=SC2064
  trap "LEERA_INSTALL_TOKEN=$token $COMPOSE -f compose.installer.yml -p leera-installer down >/dev/null 2>&1 || true" EXIT INT TERM

  cat <<EOF

  ┌─────────────────────────────────────────────────────────────────────┐
  │  Open one of these in your browser to finish setup:                 │
  │                                                                     │
EOF
  if [ "$on_port_80" = "1" ]; then
    if [ -n "$public_ip" ]; then
      echo "  │  On a cloud VM or server with a public IP (AWS, GCP, a VPS...):"
      printf '  │      http://%s/?token=%s\n' "$public_ip" "$token"
      echo "  │"
    fi
    if [ -n "$iface_ips" ]; then
      echo "  │  On the same network or VPC as this machine:"
      for h in $iface_ips; do
        printf '  │      http://%s/?token=%s\n' "$h" "$token"
      done
      echo "  │"
    fi
    echo "  │  Right on this machine:"
    printf '  │      http://localhost/?token=%s\n' "$token"
  else
    printf '  │      http://127.0.0.1:7777/?token=%s\n' "$token"
    echo "  │"
    echo "  │  Loopback only, because something else already has port 80. To"
    echo "  │  open it from your own machine, tunnel in first:"
    printf '  │      ssh -L 7777:127.0.0.1:7777 %s@<this-server>\n' "$(id -un)"
  fi
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

# True when this install uses the bundled object store. Backup/restore mirror
# the bucket only then — pulling an entire AWS bucket onto local disk is not
# what that code is for, and the operator's own S3 lifecycle rules cover it.
storage_is_bundled() { [ "${LEERA_STORAGE_MODE:-bundled}" = "bundled" ]; }

# True once this install's files live in SeaweedFS: installed on 1.0.5 or
# later, or moved across from MinIO by migrate_object_store.
store_is_seaweedfs() { [ "$(env_get LEERA_OBJECT_STORE)" = "seaweedfs" ]; }

# The network the stack runs on, for one-off helper containers.
stack_network() {
  # The API is the one container present in every topology, but the move off
  # MinIO stops it, so the stores and the database are asked too.
  local net
  for c in leera-selfhost-api leera-selfhost-objects "$OLD_MINIO_CONTAINER" leera-selfhost-db; do
    net="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$c" 2>/dev/null)"
    [ -n "$net" ] && { printf '%s' "$net"; return 0; }
  done
  return 0
}

# Run rclone on the stack network. Usage:
#   rclone_run [docker-run-args...] -- <rclone args...>
#
# Three remotes, all configured through the environment so nothing is written
# to disk: `store:` is the bundled store as this install has it now (MinIO
# until its files have moved, SeaweedFS after), `old:` the MinIO being moved
# off, and `new:` the SeaweedFS the move copies into. The credentials reach
# docker by name only (`-e NAME`), never as values on its command line, where
# anyone on the host could read them with ps.
rclone_run() {
  local net store_endpoint store_provider
  local -a docker_args=()
  net="$(stack_network)"
  [ -n "$net" ] || { warn "the stack's network was not found — is it running?"; return 1; }
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do docker_args+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  if store_is_seaweedfs; then
    store_endpoint="http://objects:9000"; store_provider="SeaweedFS"
  else
    store_endpoint="http://minio:9000"; store_provider="Minio"
  fi
  RCLONE_CONFIG_STORE_ACCESS_KEY_ID="${MINIO_ROOT_USER:-}" \
  RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD:-}" \
  RCLONE_CONFIG_OLD_ACCESS_KEY_ID="${MINIO_ROOT_USER:-}" \
  RCLONE_CONFIG_OLD_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD:-}" \
  RCLONE_CONFIG_NEW_ACCESS_KEY_ID="${MINIO_ROOT_USER:-}" \
  RCLONE_CONFIG_NEW_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD:-}" \
  docker run --rm --network "$net" ${docker_args[@]+"${docker_args[@]}"} \
    -e RCLONE_CONFIG_STORE_TYPE=s3 -e "RCLONE_CONFIG_STORE_PROVIDER=$store_provider" \
    -e "RCLONE_CONFIG_STORE_ENDPOINT=$store_endpoint" \
    -e RCLONE_CONFIG_STORE_ACCESS_KEY_ID -e RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY \
    -e RCLONE_CONFIG_OLD_TYPE=s3 -e RCLONE_CONFIG_OLD_PROVIDER=Minio \
    -e RCLONE_CONFIG_OLD_ENDPOINT=http://minio:9000 \
    -e RCLONE_CONFIG_OLD_ACCESS_KEY_ID -e RCLONE_CONFIG_OLD_SECRET_ACCESS_KEY \
    -e RCLONE_CONFIG_NEW_TYPE=s3 -e RCLONE_CONFIG_NEW_PROVIDER=SeaweedFS \
    -e "RCLONE_CONFIG_NEW_ENDPOINT=http://$MOVE_CONTAINER:9000" \
    -e RCLONE_CONFIG_NEW_ACCESS_KEY_ID -e RCLONE_CONFIG_NEW_SECRET_ACCESS_KEY \
    "$RCLONE_IMAGE" "$@"
}

# The rclone image, downloaded if this machine does not have it yet. Only the
# installs that predate 1.0.5 lack it, and only until their first update.
ensure_rclone_image() {
  docker image inspect "$RCLONE_IMAGE" >/dev/null 2>&1 && return 0
  docker pull -q "$RCLONE_IMAGE" >/dev/null 2>&1
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

# Make a changed Caddyfile take effect.
#
# The Caddyfile is a bind mount, so editing it does not change the container
# spec and `compose up -d` considers caddy already up to date — it keeps
# serving the config it read at boot. A routing fix shipped in a refreshed
# bundle would therefore never apply, on any number of updates, until someone
# restarted that container by hand. So ask Caddy to re-read it.
#
# Graceful: reload swaps the config with no dropped connections. Harmless when
# the config is unchanged, and harmless when compose *did* just recreate caddy
# (it is then reloading what it already has). A failed reload means the file is
# invalid, which restarting would not fix either — say so and leave the working
# config running.
reload_caddy() {
  $COMPOSE ps --status running --services 2>/dev/null | grep -qx caddy || return 0
  $COMPOSE exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
    || warn "the reverse proxy kept its previous configuration — the new Caddyfile was rejected.
        Check it with: $COMPOSE exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile"
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
  reclaim_path "$dest/secret_key"
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
  if ! storage_is_bundled; then
    say "external object storage — files stay in your bucket, not in this backup"
  elif [ "${BACKUP_SKIP_STORAGE:-0}" = "1" ]; then
    # Set by the update that moves the files off MinIO: that update leaves
    # MinIO's volume exactly as it was, and it is a better copy than this
    # directory would be, at no extra disk.
    say "uploaded files are not copied into this backup — they stay untouched in MinIO's volume until the update after this one"
  elif ensure_rclone_image \
      && rclone_run -v "$(host_path "$dest"):/backup" -- copy store:storage /backup/storage 2>/dev/null; then
    say "copied object storage"
  else
    warn "object storage was not copied — uploaded files are not in this backup"
  fi

  # rclone wrote the copy as root through the bind mount; same reasoning as above.
  reclaim_path "$dest"

  api_version > "$dest/VERSION" 2>/dev/null || true

  # The banner is for someone who asked for a backup. During an update it is
  # advice about a file they did not ask for, in the middle of a progress log.
  if [ "$JSON_PROGRESS" = "1" ]; then
    say "backup written to $dest"
    return 0
  fi

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
    # Which object store this machine runs, and the MinIO volume awaiting
    # removal, describe the machine and not the backup: a backup from before
    # 1.0.5 knows nothing of either, and restoring it must not send the next
    # update looking for a MinIO that is gone.
    local store old_volume since
    store="$(env_get LEERA_OBJECT_STORE)"
    old_volume="$(env_get LEERA_OLD_MINIO_VOLUME)"
    since="$(env_get LEERA_OBJECT_STORE_SINCE)"
    cp "$src/.env" .env
    chmod 600 .env
    env_set LEERA_OBJECT_STORE "${store:-seaweedfs}"
    [ -n "$old_volume" ] && env_set LEERA_OLD_MINIO_VOLUME "$old_volume"
    [ -n "$since" ] && env_set LEERA_OBJECT_STORE_SINCE "$since"
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

  # Backups from every release lay the files out the same way, one file per
  # object under storage/, so one from the MinIO days restores here unchanged.
  if [ -d "$src/storage" ] && storage_is_bundled; then
    say "restoring object storage"
    { ensure_rclone_image \
        && rclone_run -v "$(host_path "$src/storage"):/backup:ro" -- copy /backup store:storage; } \
      || warn "object storage restore failed — uploads may be missing"
  fi

  say "restarting the stack"
  $COMPOSE up -d
  reload_caddy
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

# Files the release owns. An operator who edits one of these loses their edit
# on the next --refresh-bundle, so we notice and stop instead.
BUNDLE_FILES="docker-compose.yml compose.installer.yml Caddyfile Caddyfile.no-storage updater.sh update-progress.html"
HASH_FILE=".bundle-hashes"
# Where an upgrade collects a release's stack files before putting them in place.
BUNDLE_STAGING=".bundle-staging"
# The first release published under versions/. Older ones exist only at the root.
FIRST_VERSIONED_BUNDLE="0.3.3"

# SHA-256 of a file, with whichever tool this machine has.
#
# Up to 0.3.2 this was openssl and nothing else, and the updater image has no
# openssl: the first release to change a stack file (0.3.2, updater.sh) made
# every update started from the admin screen stop here. coreutils, which the
# image does carry, has sha256sum; a macOS host has shasum.
bundle_hash() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum "$1")" || return 1
    printf '%s\n' "${out%% *}"
  elif command -v openssl >/dev/null 2>&1; then
    out="$(openssl dgst -sha256 "$1")" || return 1
    printf '%s\n' "${out##* }"
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 "$1")" || return 1
    printf '%s\n' "${out%% *}"
  else
    return 127
  fi
}

require_hash_tool() {
  command -v sha256sum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1 \
    || command -v shasum >/dev/null 2>&1 \
    || fail "none of sha256sum, openssl or shasum is installed, so the new stack files cannot be checked.
        Nothing has been changed."
}

# Whether two files have the same contents: cmp when this machine has it,
# otherwise their hashes, which says the same thing more slowly.
same_file() {
  if command -v cmp >/dev/null 2>&1; then
    cmp -s "$1" "$2"
  else
    [ -f "$1" ] && [ -f "$2" ] && [ "$(bundle_hash "$1")" = "$(bundle_hash "$2")" ]
  fi
}

# Whether version $1 is older than version $2, both like 1.4.2.
version_before() {
  local IFS=. i
  local -a left right
  read -r -a left <<<"$1"
  read -r -a right <<<"$2"
  for i in 0 1 2; do
    [ "${left[i]:-0}" -lt "${right[i]:-0}" ] && return 0
    [ "${left[i]:-0}" -gt "${right[i]:-0}" ] && return 1
  done
  return 1
}

# Record what we shipped, so drift can be told apart from a stale file.
record_bundle_hashes() {
  local f
  : > "$HASH_FILE"
  for f in $BUNDLE_FILES; do
    [ -f "$f" ] && printf '%s %s\n' "$(bundle_hash "$f")" "$f" >> "$HASH_FILE"
  done
  chmod 600 "$HASH_FILE" 2>/dev/null || true
}

recorded_hash() {
  [ -f "$HASH_FILE" ] || return 1
  awk -v f="$1" '$2 == f { print $1; found=1 } END { exit !found }' "$HASH_FILE"
}

# Which release's stack files an upgrade to image tag $1 needs. A concrete tag
# names it. The floating `selfhost` tag means the newest release, and
# versions/latest says which that is. Nothing, when neither answers, means the
# files at the root of the repo.
resolve_bundle_version() {
  local tag="$1" version=""
  case "$tag" in
    selfhost-*) version="${tag#selfhost-}" ;;
    *) version="$(fetch "$RAW_BASE/versions/latest" -o - 2>/dev/null | tr -d '[:space:]' || true)" ;;
  esac
  case "$version" in
    ''|*[!0-9.]*) version="" ;;
  esac
  printf '%s' "$version"
}

# The installer's digest from the signed manifest, when the update was asked
# for through the update service: passed in the environment by an updater.sh
# that knows to, and read from the request being worked on under one that
# predates that. Empty when there is none, as when an operator runs this.
installer_digest() {
  if [ -n "${LEERA_INSTALLER_SHA256:-}" ]; then
    printf '%s' "$LEERA_INSTALLER_SHA256"
    return 0
  fi
  local request="${LEERA_UPDATE_DIR:-/data/update}/current.json"
  [ -r "$request" ] || return 0
  sed -n 's/.*"installer"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$request"
}

# Hand this upgrade over to the target release's installer.
#
# An upgrade is performed by the installer already on the machine — the one
# that came with the release being left — inside the updater container that
# release started. Every bug that installer has is a bug in this upgrade, and
# a fix shipped in a new release only reaches the upgrade *after* the one
# that installs it: that is how one broken step kept instances on 0.2.18
# across two releases. So before anything else, an upgrade fetches the
# installer of the release it is installing and hands over to it, and every
# upgrade from then on runs the newest code there is.
#
# The handover is the one part that has to stay simple enough never to need
# a fix itself: download, check, exec. When the update service supplies the
# installer's digest from the signed manifest, a copy that does not match
# stops the upgrade; otherwise the copy is trusted the way the stack files
# and `curl … | bash` already are, over TLS to GitHub. LEERA_BOOTSTRAPPED
# marks the handed-over run so that it does not hand over again.
bootstrap_installer() {
  local version="$1" tmp expected actual
  [ "$REFRESH_BUNDLE" = "1" ] || return 0
  [ -z "${LEERA_BOOTSTRAPPED:-}" ] || return 0
  [ -n "$version" ] || return 0

  require_downloader
  require_hash_tool
  tmp="$(mktemp)"
  if ! fetch "$(bundle_url "$version" install.sh)" -o "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    # A release from before versions/ existed has no installer of its own.
    # Anything else is decided by the stack-file download that follows,
    # which fails for the same reason and says so.
    version_before "$version" "$FIRST_VERSIONED_BUNDLE" \
      || warn "could not download the $version installer — continuing with this one"
    return 0
  fi

  expected="$(installer_digest)"
  if [ -n "$expected" ]; then
    actual="sha256:$(bundle_hash "$tmp")"
    if [ "$actual" != "$expected" ] && [ "${actual#sha256:}" != "$expected" ]; then
      rm -f "$tmp"
      fail "the installer downloaded for $version is not the one this release lists.
        Nothing has been changed. This is worth reporting."
    fi
  fi

  if [ -n "$INSTALLER_PATH" ] && same_file "$tmp" "$INSTALLER_PATH"; then
    rm -f "$tmp"
    return 0
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    warn "the $version installer does not parse — continuing with this one"
    return 0
  fi

  # Staged under the name the end of do_upgrade moves into place, so the
  # handed-over run leaves itself installed. Written beside and renamed over,
  # never onto: the file being replaced may be a script bash is reading.
  cp "$tmp" install.sh.new.tmp
  rm -f "$tmp"
  chmod +x install.sh.new.tmp
  mv -f install.sh.new.tmp install.sh.new
  say "handing over to the $version installer"
  hand_over install.sh.new "$version"
}

hand_over() {
  LEERA_BOOTSTRAPPED="$2" exec bash "$1" ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}
}

# Download the images this upgrade needs, one at a time.
#
# This used to be one `docker compose pull`, which fetches every image in the
# project and gives all of them up when any one cannot be fetched — and in
# September 2026 one could not: MinIO had withdrawn its images from Docker
# Hub, so no upgrade with bundled storage got its new Leera images, although
# MinIO itself was already on every one of those machines. What a release
# changes is Leera's own images, pulled here by their exact tag. Everything
# else the stack references is pulled only when this machine does not have
# it — a release that moves MinIO to another registry, say — and an image
# that is here already is left alone, whatever its registry says today.
#
# Nothing on this machine changes here: a download that fails leaves the
# installed version running and its stack files untouched.
pull_images() {
  local target_tag="$1" repo="${LEERA_IMAGE_REPO:-ghcr.io/leera-app}"
  local compose_file img images out
  step pull "Downloading the new version"

  for img in "$repo/leera-api:$target_tag" "$repo/leera-web:$target_tag"; do
    say "downloading $img"
    if ! out="$(docker pull "$img" 2>&1)"; then
      # A copy that is here already — built locally, or downloaded by an
      # earlier attempt — is the version asked for; the registry is not.
      if docker image inspect "$img" >/dev/null 2>&1; then
        warn "could not download $img — using the copy already on this machine"
      else
        fail "could not download $img. Nothing has been changed.
        Docker said: $(printf '%s' "$out" | grep -v '^ *$' | tail -n 2)
        Check that this machine can reach $repo, then update again."
      fi
    fi
  done

  # The stack files this upgrade will put in place, or the current ones when
  # it is not refreshing them; either way, only the services this install
  # runs, so an external object store never has MinIO pulled for it.
  compose_file="$BUNDLE_STAGING/docker-compose.yml"
  [ -f "$compose_file" ] || compose_file="docker-compose.yml"
  if ! images="$(LEERA_VERSION="$target_tag" $COMPOSE --project-directory . -f "$compose_file" config --images 2>/dev/null | sort -u)"; then
    warn "could not read the image list from $compose_file — anything missing is downloaded when the stack starts"
    images=""
  fi
  for img in $images; do
    case "$img" in
      "$repo/leera-api:"*|"$repo/leera-web:"*) continue ;;
      # The container running this script. An upgrade never replaces it.
      "$repo/leera-updater:"*) continue ;;
    esac
    docker image inspect "$img" >/dev/null 2>&1 && continue
    say "downloading $img"
    if ! out="$(docker pull "$img" 2>&1)"; then
      fail "could not download $img, which this release's stack needs. Nothing has been changed.
        Docker said: $(printf '%s' "$out" | grep -v '^ *$' | tail -n 2)"
    fi
  done
  step_done pull
}

# Download a release's stack files into $BUNDLE_STAGING and check them, without
# touching anything the running stack uses.
#
# `--upgrade` used to pull images and nothing else, which meant a release that
# added a service, changed a healthcheck, or added an environment key never
# reached an existing install: it kept running the compose file from the day it
# was installed. Refreshing the stack files fixes that, and it matters more once
# updates happen from the UI, where nobody is looking at the diff.
#
# This half runs in preflight, before the backup, so a download that fails or a
# file with local edits stops the update having changed nothing and cost
# nothing. apply_bundle puts the files in place once the backup exists.
stage_bundle() {
  local version="$1" f fetched=0 missing="" current recorded

  require_downloader
  require_hash_tool
  rm -rf "$BUNDLE_STAGING"
  mkdir -p "$BUNDLE_STAGING"

  if [ -n "$version" ]; then
    say "downloading the stack files for $version"
    for f in $BUNDLE_FILES install.sh; do
      if fetch "$(bundle_url "$version" "$f")" -o "$BUNDLE_STAGING/$f" 2>/dev/null; then
        fetched=$((fetched + 1))
      else
        rm -f "$BUNDLE_STAGING/$f"
        missing="$missing $f"
      fi
    done
    # One release's files are all or nothing: part of one release's stack on
    # top of another's is not a state anyone has tested. The exception is a
    # release from before versions/ existed, or a mirror that never had it —
    # nothing under versions/ at all — whose files are at the root.
    if [ -n "$missing" ]; then
      if [ "$fetched" -eq 0 ] \
         && { version_before "$version" "$FIRST_VERSIONED_BUNDLE" || [ -n "${LEERA_RAW_BASE:-}" ]; }; then
        warn "$version has no stack files under versions/ — using the ones at the root of $RAW_BASE"
        version=""
        missing=""
      elif [ "$fetched" -eq 0 ]; then
        rm -rf "$BUNDLE_STAGING"
        fail "could not download the stack files for $version from $(bundle_url "$version" "")
        Nothing has been changed. Check that this machine can reach
        raw.githubusercontent.com. A release published in the last few minutes
        may not have reached every download server yet; update again shortly."
      else
        rm -rf "$BUNDLE_STAGING"
        fail "only some of the stack files for $version could be downloaded (missing:$missing).
        Nothing has been changed. Update again in a few minutes."
      fi
    fi
  fi

  if [ -z "$version" ]; then
    # Best-effort per file, as releases up to 0.3.2 did: a file the root does
    # not have leaves the current copy in place.
    for f in $BUNDLE_FILES install.sh; do
      if fetch "$(bundle_url "" "$f")" -o "$BUNDLE_STAGING/$f" 2>/dev/null; then
        fetched=$((fetched + 1))
      else
        rm -f "$BUNDLE_STAGING/$f"
        missing="$missing $f"
      fi
    done
    # Not one file: that is not "already current", it is a download that did
    # not happen — and the update that follows relies on these files matching
    # the release. An update from the admin UI in particular needs the compose
    # file this bundle ships, because it runs compose from inside a container
    # where the previous file's relative mounts point at paths the host lacks.
    if [ "$fetched" -eq 0 ]; then
      rm -rf "$BUNDLE_STAGING"
      fail "could not download the stack files from $RAW_BASE.
        Nothing has been changed. Check that this machine can reach
        raw.githubusercontent.com, then update again."
    fi
    [ -z "$missing" ] || warn "could not download:$missing — keeping the current copies"
  fi

  for f in $BUNDLE_FILES; do
    [ -f "$BUNDLE_STAGING/$f" ] && [ -f "$f" ] || continue
    same_file "$f" "$BUNDLE_STAGING/$f" && continue
    current="$(bundle_hash "$f")"
    # No recorded hash means an install that predates this bookkeeping. We
    # cannot tell an edit from an old file there, and refusing to update
    # every such install is the worse mistake — so it falls through.
    if recorded="$(recorded_hash "$f")" && [ "$current" != "$recorded" ]; then
      rm -rf "$BUNDLE_STAGING"
      fail "$INSTALL_DIR/$f has local edits, and this update needs to replace it.
        Save your changes somewhere, restore the file, and update again.
        Nothing has been changed."
    fi
  done
}

# Put the staged stack files in place: the half of the refresh that changes
# something, run after the backup. stage_bundle has checked every file here.
apply_bundle() {
  step bundle "Updating the stack files"
  local f changed=0

  for f in $BUNDLE_FILES; do
    [ -f "$BUNDLE_STAGING/$f" ] || continue
    if [ -f "$f" ] && same_file "$f" "$BUNDLE_STAGING/$f"; then
      continue
    fi
    cp "$BUNDLE_STAGING/$f" "$f"
    changed=1
    say "updated $f"
  done
  [ -x updater.sh ] || chmod +x updater.sh 2>/dev/null || true

  # This script is running right now, and bash reads a script lazily by byte
  # offset — rewriting it mid-run makes it resume at the wrong place. Staged
  # here, moved into place by the last line of do_upgrade. A handed-over run
  # is that staged file already (see bootstrap_installer) and is left alone;
  # and a copy is always written beside and renamed over, never onto, in
  # case the file being replaced is the one running.
  if [ -f "$BUNDLE_STAGING/install.sh" ]; then
    if [ -f install.sh.new ] && same_file install.sh.new "$BUNDLE_STAGING/install.sh"; then
      say "a new install.sh will be applied when this finishes"
    elif same_file install.sh "$BUNDLE_STAGING/install.sh"; then
      rm -f install.sh.new
    else
      cp "$BUNDLE_STAGING/install.sh" install.sh.new.tmp
      chmod +x install.sh.new.tmp
      mv -f install.sh.new.tmp install.sh.new
      say "a new install.sh will be applied when this finishes"
    fi
  fi
  rm -rf "$BUNDLE_STAGING"

  [ "$changed" = "1" ] || say "stack files are already current"
  step_done bundle
}

# Images and a database dump both land here; running out of disk halfway
# through an update is a much worse failure than refusing to start one.
# Free space needed before an update starts.
#
# Covers the new images arriving while the old ones are still on disk, plus a
# pre-upgrade backup. It is a floor, not a measurement: the backup's real size
# depends on how much has been uploaded to this instance, which we cannot know
# before taking it. Raise it with LEERA_MIN_FREE_MB on an instance with a lot
# of attachments.
MIN_FREE_MB="${LEERA_MIN_FREE_MB:-3000}"

free_mb() {
  local kb
  kb="$(df -Pk "$INSTALL_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
  [ -n "$kb" ] || return 1
  echo $((kb / 1024))
}

# Refuse an update that would run the disk out — but reclaim what is already
# reclaimable before deciding.
#
# Previously this failed outright, which put an instance into a state it could
# not leave through the admin UI: the update button reported "not enough disk"
# while several hundred MB of superseded images sat there unreferenced, and
# nothing in the product would remove them. Pruning here is safe at this point
# in the run: the release running now and the one being installed are kept,
# and everything older is superseded either way.
check_disk_space() {
  local avail running="$1" target="$2"
  avail="$(free_mb)" || return 0
  [ "$avail" -ge "$MIN_FREE_MB" ] && return 0

  say "only ${avail} MB free — reclaiming space before continuing"
  prune_images "$running" "$target"
  prune_backups

  avail="$(free_mb)" || return 0
  if [ "$avail" -lt "$MIN_FREE_MB" ]; then
    fail "only ${avail} MB free on this server, and reclaiming what it could
        did not get above ${MIN_FREE_MB} MB. An update needs that much for the
        new images and a backup.

        Space is most often in old backups or Docker data:
          du -sh $INSTALL_DIR/backups/*
          docker system df

        Copy old backups off this machine and delete them, or grow the disk.
        Set LEERA_MIN_FREE_MB to override this check if you know better."
  fi
  say "reclaimed enough to continue — ${avail} MB free"
}

# ── Reclaiming space ─────────────────────────────────────────────────────────
#
# Nothing in a self-hosted install may grow without a bound. Both functions
# below exist because an install that has been upgraded a dozen times must sit
# on roughly the same amount of disk as one installed yesterday.

# How many pre-upgrade backups to keep on the server itself. Three is enough to
# step back past a bad release; it is not an archive, and it was never meant to
# be one — the banner in do_backup says to copy them off the machine.
BACKUP_KEEP="${LEERA_BACKUP_KEEP:-3}"

# Delete all but the newest $BACKUP_KEEP backups.
#
# Only ever considers directories this script created — the `pre-upgrade-*` and
# timestamp-named ones under $INSTALL_DIR/backups. A path the operator passed to
# --backup by hand is theirs, not ours, and is never swept.
prune_backups() {
  local dir="$INSTALL_DIR/backups"
  [ -d "$dir" ] || return 0
  [ "$BACKUP_KEEP" -gt 0 ] 2>/dev/null || return 0

  local old
  # -maxdepth/-mindepth so this can only ever match a backup directory itself,
  # never something inside one. `sort -r` on the timestamped names is a
  # chronological sort: they are ISO-8601 basic format, which sorts lexically.
  old="$(find "$dir" -mindepth 1 -maxdepth 1 -type d \
           \( -name 'pre-upgrade-*' -o -name '20*T*Z' \) 2>/dev/null \
         | sort -r | tail -n +$((BACKUP_KEEP + 1)))"
  [ -n "$old" ] || return 0

  local n=0
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    rm -rf -- "$b" && n=$((n + 1))
  done <<EOF
$old
EOF
  [ "$n" -gt 0 ] && say "removed $n old backup(s), keeping the newest $BACKUP_KEEP"
  return 0
}

# Drop every release's images except the ones named, then untagged layers.
#
# Releases are tagged per version (selfhost-1.0.2, selfhost-1.0.3, ...), so an
# update never untags the image it replaces: the previous release stays tagged
# and `docker image prune` alone — which is all this did up to 1.0.3 — never
# matches it. Every update left the previous api, web and runner images behind,
# and a 20 GB server found 11 GB of them.
#
# Only our own api, web and qa-runner repositories are considered, so an image
# the operator runs for something else on this host is never touched. The
# updater is left alone: it has its own version and is what is running this.
# `image rm` without -f refuses an image a container still uses, so a failure
# here is a skip, never a stopped service.
#
# Pass the tags to keep. After an update that is only the new one — this runs
# after the health check, when rollback is off the table.
prune_images() {
  local repo="${LEERA_IMAGE_REPO:-ghcr.io/leera-app}" ref tag before after n=0
  before="$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null | awk -F'\t' '$1=="Images"{print $2}')"
  while IFS= read -r ref; do
    case "$ref" in
      "$repo"/leera-api:* | "$repo"/leera-web:* | "$repo"/leera-qa-runner:*) ;;
      *) continue ;;
    esac
    tag="${ref##*:}"
    [ "$tag" = "<none>" ] && continue
    case " $* " in *" $tag "*) continue ;; esac
    docker image rm "$ref" >/dev/null 2>&1 && n=$((n + 1))
  done <<EOF
$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
EOF
  docker image prune -f >/dev/null 2>&1 || {
    warn "could not prune old images — not fatal, but disk use will keep growing"
    return 0
  }
  after="$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null | awk -F'\t' '$1=="Images"{print $2}')"
  say "removed $n image(s) from earlier releases (reclaimable: ${before:-?} → ${after:-?})"
  return 0
}

# Confirm the image we just pulled is the one the signed release names.
#
# Tags move; digests do not. Without this, "install 1.4.2" means "install
# whatever selfhost-1.4.2 points at today", and the signature on the manifest
# stops being worth much.
check_digest() {
  local image="$1" expected="$2" actual
  [ -n "$expected" ] || { say "no published digest for $image — skipping that check"; return 0; }

  actual="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" 2>/dev/null)"
  case "$actual" in
    *"$expected"*) say "verified $image" ;;
    *) fail "the image downloaded for $image is not the one this release lists.
        Nothing has been changed. This is worth reporting." ;;
  esac
}

# Keep the database's own error in both terminal and browser progress logs.
# Use the container name so diagnostics also work outside the install directory.
show_migration_logs() {
  local logs line
  if ! logs="$(docker logs --tail 50 leera-selfhost-migrate 2>&1)"; then
    warn "could not read the migrator log. Check: docker logs --tail 150 leera-selfhost-migrate"
    return 0
  fi
  if [ -z "$logs" ]; then
    warn "the migrator did not write any log output"
    return 0
  fi
  say "Database migrator output:"
  while IFS= read -r line; do
    say "$line"
  done <<<"$logs"
}

# Run the one-shot migrator and wait for it, so "updating the database" is a
# visible stage rather than something hidden inside a dependency condition.
run_migrations() {
  step migrate "Updating the database"

  # Not silenced. When `up` refuses, its own stderr is the only thing that says
  # why, and the obvious next command cannot say it: a container that was never
  # created has no logs, so "check compose logs migrate" sent operators to an
  # empty page. Discarding this line is what turned a fixable misconfiguration
  # into a dead end.
  local up_out
  if ! up_out="$($COMPOSE up -d migrate 2>&1)"; then
    fail "the database migrator could not be started. Application containers have not been restarted.
        Compose said: $(printf '%s' "$up_out" | grep -v '^ *$' | tail -n 3)"
  fi

  local state code
  for _ in $(seq 1 900); do
    state="$(docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' leera-selfhost-migrate 2>/dev/null || true)"
    case "$state" in
      "false "*)
        code="${state#false }"
        if [ "$code" != "0" ]; then
          show_migration_logs
          fail "the database update failed (exit $code). Application containers have not been restarted.
        Database changes already applied are not undone.
        Check: docker logs --tail 150 leera-selfhost-migrate"
        fi
        step_done migrate
        return 0
        ;;
    esac
    sleep 2
  done
  show_migration_logs
  fail "the database update is still running after 30 minutes. Check: docker logs --tail 150 leera-selfhost-migrate"
}

# Put the previous version back. Images only: migrations are not reversible,
# which is why the pre-update backup is taken and why that is said plainly.
rollback_to() {
  local tag="$1" backup="$2" up_out=""
  warn "rolling back to $tag"
  env_set LEERA_VERSION "$tag"
  # Not silenced: when this fails, compose's own line is the only thing that
  # says why — and it is the same line that just failed the update.
  if ! up_out="$($COMPOSE up -d caddy web api 2>&1)"; then
    warn "putting the previous version back did not fully succeed.
        Compose said: $(printf '%s' "$up_out" | grep -v '^ *$' | tail -n 3)"
  fi
  restart_move_stopped
  reload_caddy

  if wait_for_api; then
    # The API answering is not the same as the rollback having taken. When
    # compose gave up before recreating api, the API that answers is the new
    # one, and the reverse proxy may not be running at all — this instance
    # once reported "put back on its previous version" with the new version
    # serving and caddy dead, so the site was down.
    local got want="${tag#selfhost-}"
    got="$(api_version)"
    if [ "$want" != "$tag" ] && [ -n "$got" ] && [ "$got" != "$want" ]; then
      fail "the update failed, and putting the previous version back did not take:
        the API reports version $got rather than $want. Restore the pre-update
        backup, or bring the stack up by hand:
            ./install.sh --restore $backup
            $COMPOSE up -d
        Then check: $COMPOSE ps"
    fi
    if ! $COMPOSE ps --status running --services 2>/dev/null | grep -qx caddy; then
      fail "the update failed, and the reverse proxy is not running, so the site is
        unreachable until it is. Check: $COMPOSE logs caddy
        Then: $COMPOSE up -d caddy"
    fi
    fail "the update failed and this instance was put back on its previous version.
        Database changes made by the new version are not undone. If anything looks
        wrong, restore the pre-update backup:
            ./install.sh --restore $backup"
  fi
  fail "the update failed, and putting the previous version back did not bring the
        API up either. Restore the pre-update backup:
            ./install.sh --restore $backup
        Then check: $COMPOSE logs api migrate"
}

# ── Moving off MinIO ─────────────────────────────────────────────────────────
#
# Every install up to 1.0.4 kept its uploads in a bundled MinIO. MinIO withdrew
# every public image of its server and client in September 2026, so from 1.0.5
# the bundled store is SeaweedFS, and the update to it copies the files across.
#
# The copy runs before anything the running stack uses is replaced. The stack
# files, the images, and MinIO with its volume all stay as they were until the
# copy has been checked object by object, so a failure anywhere in here leaves
# the installed version running on MinIO — the same outcome as a download that
# fails, and it says so. MinIO's image is already on every one of these
# machines, whatever its registry says now, so reading the files needs nothing
# downloaded.
#
# MinIO's volume outlives the move by one release, as the way back. The update
# after that removes it (remove_old_minio_volume).

# Set while a move is under way, for abandon_object_store_move and the restart.
MOVE_STOPPED=""
MOVE_NEW_VOLUME=""
MOVE_CREATED_VOLUME=0
MOVED_THIS_RUN=0

# Whether an update to these stack files has files to move: a bundled store
# not on SeaweedFS yet, going to stack files that run SeaweedFS.
object_store_move_needed() {
  local compose_file="$1"
  storage_is_bundled || return 1
  store_is_seaweedfs && return 1
  [ -f "$compose_file" ] && grep -q 'container_name: leera-selfhost-objects$' "$compose_file"
}

# The volume MinIO keeps its files in, asked of the container: the compose
# project an install is filed under has changed across releases, so the name
# cannot be assumed.
old_minio_volume() {
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' \
    "$OLD_MINIO_CONTAINER" 2>/dev/null
}

# Free MB on the disk that holds Docker's volumes. That need not be the disk
# this directory is on, and from inside the updater container this script
# cannot see it at all, so a helper container that mounts the volume is asked.
volume_disk_free_mb() {
  local kb
  kb="$(docker run --rm -v "$1:/v:ro" --entrypoint df "$RCLONE_IMAGE" -Pk /v 2>/dev/null \
        | awk 'NR==2 {print $4}')"
  [ -n "$kb" ] || return 1
  echo $((kb / 1024))
}

# Put the stack back exactly as it was, and stop the update.
abandon_object_store_move() {
  local c
  docker rm -f "$MOVE_CONTAINER" >/dev/null 2>&1 || true
  if [ "$MOVE_CREATED_VOLUME" = "1" ]; then
    docker volume rm "$MOVE_NEW_VOLUME" >/dev/null 2>&1 || true
  fi
  docker start "$OLD_MINIO_CONTAINER" >/dev/null 2>&1 || true
  for c in $MOVE_STOPPED; do docker start "$c" >/dev/null 2>&1 || true; done
  MOVE_STOPPED=""
  fail "$1. Nothing has been changed: this install is still on its current version,
        with its files in MinIO as before. Try the update again; if it fails the
        same way, the log above says where."
}

# Start what the move stopped and nothing else has restarted: the restart step
# names only caddy, web, api and the test runner, and the inbound mail server
# is not among them.
restart_move_stopped() {
  local c
  for c in $MOVE_STOPPED; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] && continue
    docker start "$c" >/dev/null 2>&1 || warn "could not start $c again — start it with: docker start $c"
  done
  MOVE_STOPPED=""
}

# rclone's flags for a copy between the two stores: whole-object checksums, the
# objects' own Content-Type and Content-Disposition, and a line of progress
# every half minute so a large copy is visibly moving.
MOVE_RCLONE_FLAGS=(--checksum --metadata --transfers 8 --stats 30s --stats-one-line --stats-log-level NOTICE)

# Usage: migrate_object_store <stack file being moved to> <version moving to>
migrate_object_store() {
  local compose_file="$1" since="$2"
  object_store_move_needed "$compose_file" || return 0

  if ! docker inspect "$OLD_MINIO_CONTAINER" >/dev/null 2>&1; then
    # No MinIO container. With no volume either, nothing was ever stored and the
    # new store starts empty. With one, the files exist but nothing here can
    # read them, and switching stores would hide them.
    local project
    project="$(compose_project_name)"
    if docker volume inspect "${project}_minio_data" >/dev/null 2>&1; then
      fail "this install's uploaded files are in the volume ${project}_minio_data, but the
        MinIO container that serves them ($OLD_MINIO_CONTAINER) is not there, so they
        cannot be moved to the new store. Nothing has been changed.
        Bring the installed version back up with:   $COMPOSE up -d
        and update again."
    fi
    env_set LEERA_OBJECT_STORE seaweedfs
    return 0
  fi

  step migrate "Moving uploaded files to the new storage"
  local old_vol net size bytes count mb need free c img tries
  old_vol="$(old_minio_volume)"
  [ -n "$old_vol" ] || fail "could not tell which volume MinIO keeps its files in. Nothing has been changed."
  MOVE_NEW_VOLUME="$(compose_project_name)_objects_data"

  for img in "$OBJECTS_IMAGE" "$RCLONE_IMAGE"; do
    docker image inspect "$img" >/dev/null 2>&1 && continue
    docker pull -q "$img" >/dev/null 2>&1 \
      || fail "could not download $img, which moving the uploaded files needs. Nothing has been changed."
  done

  # MinIO is normally up. Start it if it is not, and wait until it reads.
  docker start "$OLD_MINIO_CONTAINER" >/dev/null 2>&1 || true
  net="$(stack_network)"
  [ -n "$net" ] || fail "could not find this stack's network. Nothing has been changed."
  tries=0
  until size="$(rclone_run -- size old:storage --json 2>/dev/null)"; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || fail "could not read the uploaded files from MinIO ($OLD_MINIO_CONTAINER). Nothing has been changed.
        Check: docker logs --tail 50 $OLD_MINIO_CONTAINER"
    sleep 2
  done
  bytes="$(printf '%s' "$size" | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')"
  count="$(printf '%s' "$size" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
  [ -n "$bytes" ] && [ -n "$count" ] \
    || fail "could not tell how much MinIO holds (rclone said: $size). Nothing has been changed."
  mb=$(( (bytes + 1048575) / 1048576 ))

  # One more copy of the files, plus the headroom every update keeps.
  need=$(( mb + MIN_FREE_MB ))
  if free="$(volume_disk_free_mb "$old_vol")" && [ "$free" -lt "$need" ]; then
    fail "moving the uploaded files needs about $need MB free on Docker's disk (the files
        take $mb MB, plus room to work), and there is $free MB. Nothing has been changed.
        Old backups under $INSTALL_DIR/backups are the usual place to find it; or grow
        the disk. Then update again."
  fi
  say "moving $count uploaded file(s), $mb MB, from MinIO to SeaweedFS"

  # The new store runs by hand, on the volume the `objects` service will use,
  # labelled as compose's own so that compose adopts it when that service
  # starts rather than warning about a volume it did not create.
  if ! docker volume inspect "$MOVE_NEW_VOLUME" >/dev/null 2>&1; then
    docker volume create \
        --label "com.docker.compose.project=$(compose_project_name)" \
        --label com.docker.compose.volume=objects_data \
        "$MOVE_NEW_VOLUME" >/dev/null \
      || fail "could not create the volume $MOVE_NEW_VOLUME. Nothing has been changed."
    MOVE_CREATED_VOLUME=1
  fi
  docker rm -f "$MOVE_CONTAINER" >/dev/null 2>&1 || true
  AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER" AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD" \
    docker run -d --name "$MOVE_CONTAINER" --network "$net" -v "$MOVE_NEW_VOLUME:/data" \
      -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
      --entrypoint /bin/sh "$OBJECTS_IMAGE" -c "$OBJECTS_START" objects "${OBJECTS_ARGS[@]}" >/dev/null \
    || abandon_object_store_move "could not start the new store"
  tries=0
  until docker exec "$MOVE_CONTAINER" curl -fsS -o /dev/null http://127.0.0.1:9000/healthz 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || abandon_object_store_move "the new store did not start (docker logs $MOVE_CONTAINER)"
    sleep 2
  done
  rclone_run -- mkdir new:storage || abandon_object_store_move "could not create the bucket in the new store"

  # The bulk of the copy, with the site still up: however long it takes, it
  # costs no downtime.
  rclone_run -- sync old:storage new:storage "${MOVE_RCLONE_FLAGS[@]}" \
    || abandon_object_store_move "copying the files to the new store failed"

  # Now nothing may write to MinIO before the switch. The restart starts the
  # writers again, on the new store. The pause lets an upload already under
  # way finish into MinIO and be copied below.
  for c in $MOVE_WRITERS; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] || continue
    docker stop "$c" >/dev/null 2>&1 && MOVE_STOPPED="$MOVE_STOPPED $c"
  done
  sleep 5
  rclone_run -- sync old:storage new:storage "${MOVE_RCLONE_FLAGS[@]}" \
    || abandon_object_store_move "copying the files changed since the first pass failed"
  rclone_run -- check old:storage new:storage \
    || abandon_object_store_move "the copy in the new store does not match MinIO"

  # Checked. MinIO stops now, so an upload that still reaches for it fails
  # loudly and is retried against the new store rather than landing in one that
  # nothing reads any more. Its volume stays, as the way back.
  docker stop "$OLD_MINIO_CONTAINER" >/dev/null 2>&1 || true
  env_set LEERA_OBJECT_STORE seaweedfs
  env_set LEERA_OLD_MINIO_VOLUME "$old_vol"
  env_set LEERA_OBJECT_STORE_SINCE "$since"
  MOVED_THIS_RUN=1
  docker rm -f "$MOVE_CONTAINER" "$OLD_MINIO_CONTAINER" "$OLD_MINIO_INIT_CONTAINER" >/dev/null 2>&1 || true
  say "moved $count file(s) to SeaweedFS and checked every one. MinIO's volume ($old_vol) is kept until the next update, then removed."
  step_done migrate
}

# The update after the move: the new store has served a whole release, so the
# MinIO volume kept as the way back is removed. MinIO's images are left alone:
# another stack on the same machine may run them, and nobody can download them
# again.
#
# Usage: remove_old_minio_volume <version this update started from> <version it installs>
remove_old_minio_volume() {
  local before="$1" target="$2" vol since
  vol="$(env_get LEERA_OLD_MINIO_VOLUME)"
  [ -n "$vol" ] || return 0
  [ "$MOVED_THIS_RUN" = "1" ] && return 0
  since="$(env_get LEERA_OBJECT_STORE_SINCE)"
  # Only on an update from the release that moved the files, or later, to a
  # newer one — not on a retry of that same release. Any version that is not
  # known keeps the volume: removing it early is the one mistake here that
  # cannot be taken back.
  case "$before" in ''|*[!0-9.]*) return 0 ;; esac
  case "$target" in ''|*[!0-9.]*) return 0 ;; esac
  case "$since" in ''|*[!0-9.]*) return 0 ;; esac
  version_before "$before" "$since" && return 0
  version_before "$since" "$target" || return 0

  if docker volume inspect "$vol" >/dev/null 2>&1; then
    if ! docker volume rm "$vol" >/dev/null 2>&1; then
      warn "could not remove MinIO's old volume $vol. Once you are sure the files are all in
        SeaweedFS, remove it by hand: docker volume rm $vol"
      return 0
    fi
    say "removed MinIO's old volume $vol — this install's files have been in SeaweedFS since $since"
  fi
  env_unset LEERA_OLD_MINIO_VOLUME
  env_unset LEERA_OBJECT_STORE_SINCE
}

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

  step preflight "Checking this server"
  local before before_tag target_tag bundle_version
  before="$(api_version)"
  before_tag="${LEERA_VERSION:-selfhost}"
  say "current version: ${before:-unknown}"

  if [ -n "$TARGET_VERSION" ]; then
    case "$TARGET_VERSION" in
      *[!0-9.]*) fail "--to expects a version like 1.4.2 (got '$TARGET_VERSION')" ;;
    esac
  elif [ "$REFRESH_BUNDLE" = "1" ]; then
    # No version asked for: the newest one published. Without this, an
    # install pinned to a tag by a previous upgrade only ever reinstalled it.
    TARGET_VERSION="$(resolve_bundle_version selfhost)"
    [ -n "$TARGET_VERSION" ] && say "newest published version: $TARGET_VERSION"
  fi
  # Concrete tags, not the floating `selfhost` one: it is what makes "put the
  # previous version back" mean something specific.
  target_tag="$before_tag"
  [ -n "$TARGET_VERSION" ] && target_tag="selfhost-$TARGET_VERSION"
  bundle_version="$(resolve_bundle_version "$target_tag")"

  # Usually the last line of this script to run: see the note on the function.
  bootstrap_installer "$bundle_version"

  check_disk_space "$before_tag" "$target_tag"
  # Before the backup, so that a download that fails or a locally edited stack
  # file stops the update having changed nothing. They go in place after it.
  if [ "$REFRESH_BUNDLE" = "1" ]; then
    stage_bundle "$bundle_version"
  fi
  # Whether this update moves the uploaded files off MinIO. Only a refreshed
  # bundle can: without new stack files the stack stays on MinIO, and moving
  # the files would leave it reading from a store they are no longer in.
  local moving=0
  if [ "$REFRESH_BUNDLE" = "1" ] && object_store_move_needed "$BUNDLE_STAGING/docker-compose.yml"; then
    moving=1
    say "this update moves the uploaded files from MinIO to SeaweedFS (MinIO no longer publishes its images)"
  fi
  step_done preflight

  # An upgrade runs migrations, and migrations are the one thing pulling the
  # old image back will not undo. Back up first.
  local backup_dir
  backup_dir="$INSTALL_DIR/backups/pre-upgrade-$(date -u +%Y%m%dT%H%M%SZ)"
  if [ "$SKIP_BACKUP" = "1" ] && [ "${LEERA_DB_MODE:-bundled}" = "external" ]; then
    step backup "Skipping the backup, as requested"
    warn "no pre-update backup was taken — you asserted you have your own"
    backup_dir="(no backup taken)"
    step_done backup
  else
    step backup "Backing up"
    # Not silenced under --json-progress: do_backup's own output is structured
    # there, and its failure message is the one thing someone watching an
    # update actually needs. Only the human-readable banner is suppressed.
    if [ "$JSON_PROGRESS" = "1" ]; then
      BACKUP_SKIP_STORAGE="$moving" do_backup "$backup_dir"
    else
      BACKUP_SKIP_STORAGE="$moving" do_backup "$backup_dir" >/dev/null
      say "backup written to $backup_dir"
    fi
    # Bound the set immediately: the backup that just landed is the one that
    # pushes the oldest past the retention count.
    prune_backups
    step_done backup
  fi

  pull_images "$target_tag"

  step verify "Verifying what was downloaded"
  local repo="${LEERA_IMAGE_REPO:-ghcr.io/leera-app}"
  check_digest "$repo/leera-api:$target_tag" "${LEERA_DIGEST_API:-}"
  check_digest "$repo/leera-web:$target_tag" "${LEERA_DIGEST_WEB:-}"
  step_done verify

  # The uploaded files move first, while the stack files, the images and MinIO
  # itself can all still be left exactly as they are if the move fails. See
  # migrate_object_store.
  if [ "$moving" = "1" ]; then
    migrate_object_store "$BUNDLE_STAGING/docker-compose.yml" "$bundle_version"
  fi

  # From here the stack changes: the stack files, then the version they run.
  if [ "$REFRESH_BUNDLE" = "1" ]; then
    apply_bundle
  fi
  if [ "$target_tag" != "$before_tag" ]; then
    env_set LEERA_VERSION "$target_tag"
    export LEERA_VERSION="$target_tag"
  fi

  run_migrations

  step restart "Restarting"
  # Everything except the updater, which is the container running this script.
  # The test runner is named too when it is on: `up` recreates only the
  # services it is given, and left out it would stay on the version it started
  # with through every update.
  local services="caddy web api"
  [ "${LEERA_QA_RUNNER:-off}" = "on" ] && services="$services qa-runner"
  # shellcheck disable=SC2086
  $COMPOSE up -d $services \
    || rollback_to "$before_tag" "$backup_dir"
  restart_move_stopped
  reload_caddy
  step_done restart

  step health "Checking it came back"
  if ! wait_for_api; then
    rollback_to "$before_tag" "$backup_dir"
  fi

  local after
  after="$(api_version)"
  if [ -n "$TARGET_VERSION" ] && [ -n "$after" ] && [ "$after" != "$TARGET_VERSION" ]; then
    warn "expected version $TARGET_VERSION but the API reports $after"
  fi
  step_done health

  # Only now: up to this point rollback_to may still need the image we came
  # from, and pruning is what would have taken it away.
  step cleanup "Reclaiming disk space"
  prune_images "$target_tag"
  # The version this update started from, as the stack files had it: that is
  # what was running, whatever the API said (an API that did not answer says
  # nothing). The floating `selfhost` tag names no version, so then the API's
  # answer is all there is.
  local before_version="${before_tag#selfhost-}"
  case "$before_version" in ''|*[!0-9.]*) before_version="${before:-}" ;; esac
  remove_old_minio_volume "$before_version" "${target_tag#selfhost-}"
  step_done cleanup

  # Safe now: this script has finished reading itself.
  if [ -f install.sh.new ]; then
    mv -f install.sh.new install.sh
    chmod +x install.sh
  fi
  record_bundle_hashes

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

  # An install that still keeps its uploaded files in MinIO must not have these
  # stack files put over its own: they run SeaweedFS instead, which would start
  # empty and leave every file looking lost. --upgrade moves them across and
  # checks them first; this does neither. Asked before anything is copied.
  if [ -f .env ] && [ "$(env_get LEERA_STORAGE_MODE)" != "external" ] && ! store_is_seaweedfs \
      && docker inspect "$OLD_MINIO_CONTAINER" >/dev/null 2>&1; then
    fail "this install keeps its uploaded files in MinIO, which this version replaces with
        SeaweedFS. Run   $INSTALL_DIR/install.sh --upgrade   instead: it moves the files
        across and checks them before switching. Nothing has been changed."
  fi

  # Prefer local files when run from a checkout; otherwise download the pinned
  # set. The "$SCRIPT_DIR" != "$PWD" guard keeps a re-run from copying the
  # install dir's own files onto themselves, which cp rejects.
  if [ -n "$SCRIPT_DIR" ] && [ "$SCRIPT_DIR" != "$PWD" ] && [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    cp "$SCRIPT_DIR/docker-compose.yml" ./docker-compose.yml
    cp "$SCRIPT_DIR/compose.installer.yml" ./compose.installer.yml
    cp "$SCRIPT_DIR/Caddyfile" ./Caddyfile
    cp "$SCRIPT_DIR/Caddyfile.no-storage" ./Caddyfile.no-storage
    cp "$SCRIPT_DIR/install.sh" ./install.sh
    # The update service runs these two from here rather than from its own
    # image, so that a release can change how updates work without having to
    # replace the container that performs updates.
    cp "$SCRIPT_DIR/updater/updater.sh" ./updater.sh
    cp "$SCRIPT_DIR/updater/progress.html" ./update-progress.html
  else
    # Counted so the per-file lines below can say how far along they are. The
    # seventh is install.sh, which the branch at the end of this block may skip.
    FETCH_INDEX=0
    FETCH_TOTAL=6
    [ "$SCRIPT_DIR" != "$PWD" ] && FETCH_TOTAL=7
    say "downloading stack files ($FETCH_TOTAL small files, a few seconds on a good connection)"
    fetch_bundle_file docker-compose.yml
    fetch_bundle_file compose.installer.yml
    fetch_bundle_file Caddyfile
    fetch_bundle_file Caddyfile.no-storage
    fetch_bundle_file updater.sh
    fetch_bundle_file update-progress.html
    # Every operator command (--upgrade, --backup, --restore, --status) is
    # documented as `cd ~/leera && ./install.sh …`, so the script has to land
    # here too. Under `curl … | bash` there is no local copy to copy from.
    #
    # Skipped when we are *already* executing ./install.sh from this directory:
    # bash reads a script lazily by byte offset, so rewriting the file mid-run
    # can make it resume at the wrong place. Download to a temp name and move
    # it into place so the file is never half-written either.
    if [ "$SCRIPT_DIR" != "$PWD" ]; then
      fetch_bundle_file install.sh install.sh.tmp
      mv install.sh.tmp install.sh
    fi
  fi
  chmod +x ./install.sh ./updater.sh 2>/dev/null || true
  record_bundle_hashes

  # Bind-mounted read-only into api/migrate for a private-CA bundle. Created
  # here so Docker does not create it root-owned on first `up`.
  mkdir -p ./secrets && chmod 700 ./secrets

  if [ ! -f .env ]; then
    say "first install — generating secrets"

    # Before the wizard, because the answer decides whether the wizard can have
    # port 80 at all. Fresh installs only — see the note on the function.
    detect_external_proxy

    # The browser wizard is the normal path: it asks where the database and
    # files should live and verifies both before anything starts. It is skipped
    # when the answers were supplied as environment variables, which is how
    # unattended and scripted installs work.
    if [ -z "${LEERA_DB_MODE:-}" ] && [ -z "${LEERA_STORAGE_MODE:-}" ] && [ ! -f install.json ]; then
      run_wizard
    fi

    # An install dir left over from a version that ran the wizard as root has a
    # secrets file this user cannot read. Sourcing it would fail with a bare
    # "Permission denied" and no hint of what to do about it.
    if [ -f install.secrets.env ] && [ ! -r install.secrets.env ]; then
      fail "install.secrets.env is not readable by $(id -un) — an earlier install wrote it as root.
  Fix it with:

      sudo chown $(id -u):$(id -g) $INSTALL_DIR/install.secrets.env $INSTALL_DIR/install.json

  then re-run this script."
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

    # Postgres reads POSTGRES_PASSWORD only when it initialises an empty data
    # directory. A pgdata volume left over from an earlier install therefore
    # keeps whatever password it was born with, while the .env about to be
    # written below gets a freshly generated one — and nothing notices until the
    # migrator dies with "password authentication failed for user postgres",
    # several steps and one confusing compose error later. The mismatch is only
    # fixable while both halves are still in hand, so it is caught here.
    if [ "${LEERA_DB_MODE:-bundled}" != "external" ]; then
      pgdata_volume="$(compose_project_name)_pgdata"
      db_container="$(compose_project_name)-selfhost-db"
      if docker volume inspect "$pgdata_volume" >/dev/null 2>&1; then
        # No apostrophes in the prose below: this heredoc is expanded inside a
        # command substitution, where a lone quote character ends the string
        # early and turns the rest of the script into a parse error.
        stale_db_msg=$(cat <<EOM
a database volume from an earlier install is still here, but its .env is gone.

  Volume: $pgdata_volume

The password lives in two places that have to agree: inside that volume, and in
.env. Generating a new .env now would leave them disagreeing forever, so pick:

  KEEP THE DATA. Put the matching .env back in $INSTALL_DIR and rerun.
  If that .env is gone for good, give the volume a password you know:

      docker compose up -d db
      docker exec -it $db_container \\
          psql -U postgres -c "ALTER USER postgres PASSWORD 'NEW_PASSWORD'"

  then rerun, and put that same NEW_PASSWORD into the generated .env.

  START CLEAN. This DESTROYS everything in that volume, including every
  account, organization, and file recorded in it:

      docker volume rm $pgdata_volume

  Take a dump first if there is any doubt at all:

      docker compose up -d db
      docker exec $db_container pg_dumpall -U postgres > leera-backup.sql
EOM
)
        fail "$stale_db_msg"
      fi
    fi

    cat > .env <<EOF
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Keep this file safe:
# a full backup = database dump + the api container's /data volume + this file.
LEERA_DOMAIN=$DOMAIN
LEERA_PUBLIC_URL=$PUBLIC_URL

# Who owns ports 80 and 443 on this machine.
#   bundled  — the Caddy in this stack does, and obtains certificates itself.
#   external — a reverse proxy you already run does. It terminates TLS and
#              forwards everything to Caddy at LEERA_PROXY_BIND, which goes on
#              routing each path to the right container. See nginx-leera.conf.
LEERA_PROXY_MODE=${LEERA_PROXY_MODE:-bundled}
LEERA_PROXY_BIND=${LEERA_PROXY_BIND:-127.0.0.1:8080}
POSTGRES_PASSWORD=$(openssl rand -hex 24)
MINIO_ROOT_USER=leera
MINIO_ROOT_PASSWORD=$(openssl rand -hex 24)
# The bundled object store is SeaweedFS; the two names above are its access
# key and secret, kept from the MinIO it replaced so that no .env had to change.
LEERA_OBJECT_STORE=seaweedfs

# Where the images come from. Point these at your own registry, or at images
# you built locally with scripts/build-selfhost-images.sh.
LEERA_IMAGE_REPO=${LEERA_IMAGE_REPO:-ghcr.io/leera-app}
LEERA_VERSION=${LEERA_VERSION:-selfhost}

# The compose project this stack is filed under. Pinned rather than left to
# compose's default of "the directory name", because the updater container runs
# install.sh from its own bind mount: without this, an update from the admin UI
# would address a different project than an update over SSH, and find none of
# these containers or volumes. Changing it after install orphans both.
COMPOSE_PROJECT_NAME=$(compose_project_name)

# What this instance brings its own of: 'bundled' or 'external'. These decide
# which containers run — install.sh turns them into COMPOSE_PROFILES below.
LEERA_DB_MODE=${LEERA_DB_MODE:-bundled}
LEERA_STORAGE_MODE=${LEERA_STORAGE_MODE:-bundled}

# The update service, which is what makes "Update now" work in the admin UI.
# Set to 'off' if you would rather no container held the Docker socket; updates
# then happen here, with ./install.sh --upgrade.
LEERA_UPDATER=${LEERA_UPDATER:-on}
# Pinned separately from LEERA_VERSION: the update service is a Docker CLI and
# a shell script, it is not replaced on every release, and it must not be the
# container being recreated while it is performing a recreation.
LEERA_UPDATER_VERSION=${LEERA_UPDATER_VERSION:-selfhost}

# Browser test runner for automated QA cases. 'on' needs a runner pool token
# created by a workspace administrator; each browser uses 500 MB+ of memory.
LEERA_QA_RUNNER=${LEERA_QA_RUNNER:-off}
LEERA_QA_RUNNER_TOKEN=${LEERA_QA_RUNNER_TOKEN:-}
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

  # Fresh installs get this from the generated .env; a re-run over an install
  # that predates the key is where it gets recorded.
  pin_project_name
  pin_host_install_dir

  backfill_modes

  # shellcheck disable=SC1091
  . ./.env

  derive_topology
  check_mail_port
  [ "${LEERA_PROXY_MODE:-bundled}" = "external" ] && write_nginx_conf

  # The image tags are floating (":selfhost"), moved to the newest release by
  # every publish — `up -d` alone only pulls an image that is missing outright,
  # so a tag already cached locally from an earlier attempt on this host would
  # otherwise be reused silently instead of refetched, leaving a fresh install
  # running whatever version happened to be current the last time anything on
  # this machine pulled it.
  say "starting the stack (first run downloads images and can take a few minutes)"
  $COMPOSE pull || warn "could not pull — continuing with the images already on this machine"
  $COMPOSE up -d
  reload_caddy

  if ! wait_for_api; then
    say "the API did not come up in time. Check logs with:"
    say "    cd $INSTALL_DIR && $COMPOSE logs api migrate"
    exit 1
  fi

  # In external mode the stack is up but nothing outside can reach it yet: the
  # operator's proxy has no idea we exist. Say what is left, in order, with their
  # own domain already substituted — this is the difference between a mode people
  # can adopt and one they abandon halfway.
  if [ "${LEERA_PROXY_MODE:-bundled}" = "external" ]; then
    cat <<EOF

  ✅  Leera is running (version $(api_version)), listening on ${LEERA_PROXY_BIND:-127.0.0.1:8080}.

  ⚠️   It is NOT reachable yet. Your own reverse proxy is in front, so three
      things are left — all on your side, none of them ours to do for you:

      1. Publish it through nginx:

             sudo cp $INSTALL_DIR/nginx-leera.conf /etc/nginx/sites-available/leera
             sudo ln -s /etc/nginx/sites-available/leera /etc/nginx/sites-enabled/leera
             sudo nginx -t && sudo systemctl reload nginx

      2. Get a certificate. Unlike the bundled Caddy, nginx does not obtain one
         for you, so use the certbot you already have. It edits the block from
         step 1 in place to add TLS and the redirect:

             sudo certbot --nginx -d ${LEERA_DOMAIN:-your-domain}

      3. Open ${LEERA_PUBLIC_URL} and finish setup (first account becomes admin).

      Inbound project email is not supported in this mode — nothing here can get
      a certificate for an MX hostname. Run Leera on its own instance if you
      need it.
EOF
  else
    cat <<EOF

  ✅  Leera is running (version $(api_version)).

      Open now and finish setup (the first account becomes the admin):

          ${LEERA_PUBLIC_URL}
EOF
  fi

  cat <<EOF

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

  Updates arrive in the app: Instance Settings → Updates tells you when
  there is a new version and installs it for you. That is what the
  leera-selfhost-updater container is for — it holds this host's Docker
  socket, so if you would rather it did not exist, set LEERA_UPDATER=off
  in $INSTALL_DIR/.env and update from here instead.

  Update from here any time with:   cd $INSTALL_DIR && ./install.sh --upgrade
EOF
}

# Turn the browser test runner on or off: record it in .env, recompute the
# profiles, and start or remove that one container. The "Built-in runner"
# switch on the Test runners page runs this through the update service, which
# hands the token over as LEERA_QA_RUNNER_TOKEN_NEW — an environment value, so
# it never appears in a process list. By hand, `--qa-runner on` reuses the
# token already in .env.
do_qa_runner() {
  local mode="$1" token up_out
  case "$mode" in
    on|off) ;;
    *) fail "--qa-runner takes 'on' or 'off' (got '${mode:-nothing}')" ;;
  esac
  require_docker
  require_install
  backfill_modes
  # shellcheck disable=SC1091
  . ./.env

  step runner "Switching the browser test runner $mode"
  if [ "$mode" = "on" ]; then
    token="${LEERA_QA_RUNNER_TOKEN_NEW:-${LEERA_QA_RUNNER_TOKEN:-}}"
    [[ "$token" =~ ^pm_run_[A-Za-z0-9_-]+$ ]] \
      || fail "the test runner needs a runner pool token (pm_run_…). Turn it on from Workspace settings → Test runners, or set LEERA_QA_RUNNER_TOKEN in $INSTALL_DIR/.env"
    env_set LEERA_QA_RUNNER on
    env_set LEERA_QA_RUNNER_TOKEN "$token"
    LEERA_QA_RUNNER=on
    LEERA_QA_RUNNER_TOKEN="$token"
    derive_topology
    say "starting the browser test runner (its first start downloads the browser image)"
    # --no-deps: the API is already up, and recreating it here would drop
    # every signed-in session's request for nothing.
    if ! up_out="$($COMPOSE up -d --no-deps qa-runner 2>&1)"; then
      fail "the browser test runner could not be started.
        Compose said: $(printf '%s' "$up_out" | grep -v '^ *$' | tail -n 3)"
    fi
    say "the browser test runner is running"
  else
    env_set LEERA_QA_RUNNER off
    env_set LEERA_QA_RUNNER_TOKEN ""
    LEERA_QA_RUNNER=off
    LEERA_QA_RUNNER_TOKEN=""
    derive_topology
    # By container name: with its profile gone, compose no longer knows the service.
    docker rm -f leera-selfhost-qa-runner >/dev/null 2>&1 || true
    say "the browser test runner is stopped"
  fi
  step_done runner
}

usage() {
  sed -n '3,34p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

COMMAND=""
ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --upgrade|--backup|--restore|--status)
      [ -z "$COMMAND" ] || fail "pick one command at a time ($COMMAND and $1)"
      COMMAND="$1"
      # --backup and --restore take a directory; --upgrade and --status do not.
      case "$1" in
        --backup|--restore)
          if [ -n "${2:-}" ] && [ "${2#--}" = "$2" ]; then ARG="$2"; shift; fi
          ;;
      esac
      ;;
    --qa-runner)
      [ -z "$COMMAND" ] || fail "pick one command at a time ($COMMAND and $1)"
      COMMAND="$1"
      ARG="${2:-}"
      [ $# -gt 1 ] && shift
      ;;
    --to)             TARGET_VERSION="${2:-}"; shift ;;
    --refresh-bundle) REFRESH_BUNDLE=1 ;;
    --skip-backup)    SKIP_BACKUP=1 ;;
    --json-progress)  JSON_PROGRESS=1 ;;
    --help|-h)        usage; exit 0 ;;
    *)                fail "unknown option: $1 (try --help)" ;;
  esac
  shift
done

case "$COMMAND" in
  # An upgrade driven from the UI always refreshes the stack files; one driven
  # by hand asks for it, so an operator running --upgrade on a machine with no
  # internet access to the bundle host still gets their images.
  --upgrade) do_upgrade ;;
  --backup)  do_backup "$ARG" ;;
  --restore) do_restore "$ARG" ;;
  --status)  do_status ;;
  --qa-runner) do_qa_runner "$ARG" ;;
  "")        do_install ;;
esac
