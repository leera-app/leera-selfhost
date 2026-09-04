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
# Options for --upgrade:
#   --to VERSION        install a specific version instead of the newest tag
#   --refresh-bundle    also update docker-compose.yml, the Caddyfiles and this
#                       script — a release that adds a service needs them
#   --skip-backup       external databases only; you are asserting you have one
#   --json-progress     emit machine-readable progress instead of prose
#
# Docker is a prerequisite this script installs itself when it is missing:
# Docker Engine plus the Compose plugin on Linux, Docker Desktop via Homebrew
# on macOS. It asks first; LEERA_INSTALL_DOCKER=yes answers yes ahead of time
# for unattended installs, LEERA_INSTALL_DOCKER=no declines and stops.
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
fail() {
  if [ "$JSON_PROGRESS" = "1" ]; then
    [ -n "$CURRENT_STEP" ] && printf '{"event":"step","step":"%s","status":"failed"}\n' "$CURRENT_STEP"
    printf '{"event":"log","level":"error","message":"%s"}\n' "$(json_escape "$*")"
  else
    printf '\033[1;31m[leera] ERROR:\033[0m %s\n' "$*" >&2
  fi
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
# best-effort branch in refresh_bundle — so the stack files never refreshed and
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
  local name="$1" dest="${2:-$1}"
  FETCH_INDEX=$((FETCH_INDEX + 1))
  say "  [$FETCH_INDEX/$FETCH_TOTAL] $name"
  fetch "$RAW_BASE/$name" -o "$dest" || fail "could not download $name from $RAW_BASE
        The stack files are hosted on raw.githubusercontent.com. Check that this
        machine can reach it:
            curl -fsS -o /dev/null -w '%{http_code}\\n' $RAW_BASE/$name"
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
    say "no storage mode recorded — assuming the bundled MinIO"
  fi
  # Installs predating the update service default to running it: that is the
  # whole point of it existing, and an operator who does not want a container
  # holding the Docker socket sets LEERA_UPDATER=off here.
  if ! env_has LEERA_UPDATER; then
    env_set LEERA_UPDATER on
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
  if storage_is_bundled; then
    local net
    net="$(stack_network)"
    if [ -n "$net" ] && docker run --rm --network "$net" -v "$(host_path "$dest"):/backup" \
        --entrypoint /bin/sh minio/mc:latest -c \
        "mc alias set local http://minio:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null && mc mirror --quiet local/storage /backup/storage" 2>/dev/null; then
      say "copied object storage"
    else
      warn "object storage was not copied — uploaded files are not in this backup"
    fi
  else
    say "external object storage — files stay in your bucket, not in this backup"
  fi

  # mc wrote the mirror as root through the bind mount; same reasoning as above.
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
    [ -n "$net" ] && docker run --rm --network "$net" -v "$(host_path "$src/storage"):/backup" \
      --entrypoint /bin/sh minio/mc:latest -c \
      "mc alias set local http://minio:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null && mc mirror --quiet /backup local/storage" \
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

bundle_hash() { openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'; }

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

# Bring the stack files up to date.
#
# `--upgrade` used to pull images and nothing else, which meant a release that
# added a service, changed a healthcheck, or added an environment key never
# reached an existing install: it kept running the compose file from the day it
# was installed. That is the bug this function exists to fix, and it matters
# more once updates happen from the UI, where nobody is looking at the diff.
refresh_bundle() {
  step bundle "Fetching the new stack files"

  local tmp f current recorded changed=0 fetched=0 missing=""
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  require_downloader

  # Best-effort per file: a bundle file that cannot be fetched leaves the
  # current one in place, so fetch() rather than fetch_bundle_file(), which
  # treats a failure as fatal.
  for f in $BUNDLE_FILES install.sh; do
    if fetch "$RAW_BASE/$f" -o "$tmp/$f" 2>/dev/null; then
      fetched=$((fetched + 1))
    else
      rm -f "$tmp/$f"
      missing="$missing $f"
    fi
  done
  # Not one file: that is not "already current", it is a download that did
  # not happen — and the update that follows relies on these files matching
  # the release. An update from the admin UI in particular needs the compose
  # file this bundle ships, because it runs compose from inside a container
  # where the previous file's relative mounts point at paths the host lacks.
  [ "$fetched" -gt 0 ] || fail "could not download the stack files from $RAW_BASE.
        Nothing has been changed. Check that this machine can reach
        raw.githubusercontent.com, then update again."
  [ -z "$missing" ] || warn "could not download:$missing — keeping the current copies"

  for f in $BUNDLE_FILES; do
    [ -f "$tmp/$f" ] || continue
    if [ -f "$f" ]; then
      cmp -s "$f" "$tmp/$f" && continue
      current="$(bundle_hash "$f")"
      # No recorded hash means an install that predates this bookkeeping. We
      # cannot tell an edit from an old file there, and refusing to update
      # every such install is the worse mistake — so it falls through.
      if recorded="$(recorded_hash "$f")" && [ "$current" != "$recorded" ]; then
        fail "$INSTALL_DIR/$f has local edits, and this update needs to replace it.
        Save your changes somewhere, restore the file, and update again.
        Nothing has been changed."
      fi
    fi
    cp "$tmp/$f" "$f"
    changed=1
    say "updated $f"
  done
  [ -x updater.sh ] || chmod +x updater.sh 2>/dev/null || true

  # This script is running right now, and bash reads a script lazily by byte
  # offset — rewriting it mid-run makes it resume at the wrong place. Staged
  # here, moved into place by the last line of do_upgrade.
  if [ -f "$tmp/install.sh" ] && ! cmp -s install.sh "$tmp/install.sh"; then
    cp "$tmp/install.sh" install.sh.new
    chmod +x install.sh.new
    say "a new install.sh will be applied when this finishes"
  fi

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
# in the run — nothing has been pulled yet, so `dangling=true` cannot match an
# image this upgrade is about to need.
check_disk_space() {
  local avail
  avail="$(free_mb)" || return 0
  [ "$avail" -ge "$MIN_FREE_MB" ] && return 0

  say "only ${avail} MB free — reclaiming space before continuing"
  docker image prune -f >/dev/null 2>&1 || true
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

# Drop images no container references any more.
#
# `--filter dangling=true` is the conservative form: it removes only untagged
# layers, which after a `compose pull` is exactly the previous release's web and
# api images and nothing else. It cannot touch an image a container still uses,
# and it cannot touch a tagged image, so a rollback to the tag we came from
# still finds what it needs — which is why this runs only after the health check
# has passed and rollback is off the table.
prune_images() {
  local before after freed
  before="$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null | awk -F'\t' '$1=="Images"{print $2}')"
  docker image prune -f >/dev/null 2>&1 || {
    warn "could not prune old images — not fatal, but disk use will keep growing"
    return 0
  }
  after="$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null | awk -F'\t' '$1=="Images"{print $2}')"
  freed="${before:-?} → ${after:-?}"
  say "removed the previous release's images (reclaimable: $freed)"
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
    fail "the database migrator could not be started. Nothing has been changed.
        Compose said: $(printf '%s' "$up_out" | grep -v '^ *$' | tail -n 3)"
  fi

  local state code
  for _ in $(seq 1 900); do
    state="$(docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' leera-selfhost-migrate 2>/dev/null || true)"
    case "$state" in
      "false "*)
        code="${state#false }"
        [ "$code" = "0" ] || fail "the database update failed (exit $code). Nothing else has been
        changed — this instance is still on its previous version.
        Check: $COMPOSE logs migrate"
        step_done migrate
        return 0
        ;;
    esac
    sleep 2
  done
  fail "the database update is still running after 30 minutes. Check: $COMPOSE logs migrate"
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
  local before before_tag target_tag
  before="$(api_version)"
  before_tag="${LEERA_VERSION:-selfhost}"
  say "current version: ${before:-unknown}"

  # Concrete tags, not the floating `selfhost` one: it is what makes "put the
  # previous version back" mean something specific.
  target_tag="$before_tag"
  if [ -n "$TARGET_VERSION" ]; then
    case "$TARGET_VERSION" in
      *[!0-9.]*) fail "--to expects a version like 1.4.2 (got '$TARGET_VERSION')" ;;
    esac
    target_tag="selfhost-$TARGET_VERSION"
  fi
  check_disk_space
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
      do_backup "$backup_dir"
    else
      do_backup "$backup_dir" >/dev/null
      say "backup written to $backup_dir"
    fi
    # Bound the set immediately: the backup that just landed is the one that
    # pushes the oldest past the retention count.
    prune_backups
    step_done backup
  fi

  [ "$REFRESH_BUNDLE" = "1" ] && refresh_bundle

  if [ "$target_tag" != "$before_tag" ]; then
    env_set LEERA_VERSION "$target_tag"
    export LEERA_VERSION="$target_tag"
  fi

  step pull "Downloading the new version"
  # A locally built image has nothing to pull from; that is not a failure, it
  # just means the new version is whatever you built.
  $COMPOSE pull || warn "could not pull — continuing with the images already on this machine"
  step_done pull

  step verify "Verifying what was downloaded"
  local repo="${LEERA_IMAGE_REPO:-ghcr.io/leera-app}"
  check_digest "$repo/leera-api:$target_tag" "${LEERA_DIGEST_API:-}"
  check_digest "$repo/leera-web:$target_tag" "${LEERA_DIGEST_WEB:-}"
  step_done verify

  run_migrations

  step restart "Restarting"
  # Everything except the updater, which is the container running this script.
  $COMPOSE up -d caddy web api \
    || rollback_to "$before_tag" "$backup_dir"
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
  prune_images
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
POSTGRES_PASSWORD=$(openssl rand -hex 24)
MINIO_ROOT_USER=leera
MINIO_ROOT_PASSWORD=$(openssl rand -hex 24)

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

  Updates arrive in the app: Instance Settings → Updates tells you when
  there is a new version and installs it for you. That is what the
  leera-selfhost-updater container is for — it holds this host's Docker
  socket, so if you would rather it did not exist, set LEERA_UPDATER=off
  in $INSTALL_DIR/.env and update from here instead.

  Update from here any time with:   cd $INSTALL_DIR && ./install.sh --upgrade
EOF
}

usage() {
  sed -n '3,27p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
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
  "")        do_install ;;
esac
