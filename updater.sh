#!/usr/bin/env bash
#
# The Leera update service.
#
# Watches for a request file written by the API, runs `install.sh --upgrade`,
# and publishes progress as a static JSON document that Caddy serves. That is
# the entire program.
#
#   /data/update/request.json    written by the API  (admin-authenticated,
#                                license-checked, version verified against a
#                                signed manifest before it lands here)
#   /data/update/current.json    the request being worked on
#   /data/update/result.json     outcome of the last run, read back by the API
#   /data/update/updater.json    heartbeat; how the API knows one-click updates
#                                are actually possible on this install
#   /srv/update/<token>.json     progress, served at /_leera/update/<token>.json
#   /srv/update/index.html       the progress page
#
# Two properties worth preserving if you edit this:
#
#   1. It listens on nothing. This container holds the Docker socket, which is
#      root on the host; the only way in is a file the API writes.
#   2. It runs install.sh and nothing else. Every upgrade — from this UI or
#      from an operator's SSH session — is the same code path, so the one
#      almost nobody exercises cannot rot.
#
# It re-execs itself from the install directory after each update, so a release
# can change this logic without replacing the container performing the update.

set -uo pipefail

INSTALL_DIR="${LEERA_INSTALL_DIR:-/install}"
UPDATE_DIR="${LEERA_UPDATE_DIR:-/data/update}"
DOCROOT="${LEERA_UPDATER_DOCROOT:-/srv/update}"
HEARTBEAT_SECONDS=15
POLL_SECONDS=3

REQUEST_FILE="$UPDATE_DIR/request.json"
CURRENT_FILE="$UPDATE_DIR/current.json"
RESULT_FILE="$UPDATE_DIR/result.json"
HEARTBEAT_FILE="$UPDATE_DIR/updater.json"

log() { printf '[leera-updater] %s\n' "$*" >&2; }

mkdir -p "$UPDATE_DIR" "$DOCROOT"

# Which compose project the stack is filed under.
#
# Asked of Docker, because this container has no way to see the host directory
# compose would otherwise name it after. .env wins when it records the name —
# that is the value install.sh pins and the one an operator can correct — and
# the running containers answer for an install whose .env predates it.
stack_project_name() {
  local name
  name="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$INSTALL_DIR/.env" 2>/dev/null | tail -1)"
  if [ -z "$name" ]; then
    local c
    for c in leera-selfhost-api leera-selfhost-db leera-selfhost-caddy \
             leera-selfhost-web leera-selfhost-updater; do
      name="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' \
        "$c" 2>/dev/null || true)"
      [ -n "$name" ] && break
    done
  fi
  printf '%s' "$name"
}

# ── Progress page ─────────────────────────────────────────────────────────────

# The instance's own product name, for the progress page.
#
# The page is the one thing still answering while the app is down, so it cannot
# fetch this itself — the name is baked in when the page is published, which is
# whenever the updater starts and again just before an update begins. Falls back
# to something unbranded rather than to the vendor's name: a whitelabelled
# instance showing "Updating Leera" mid-update gives the whole thing away.
progress_app_name() {
  local name body url=http://api:8081/api/v1/instance/public_config/
  # Older updater images have no curl; BusyBox wget is always there.
  if command -v curl >/dev/null 2>&1; then
    body="$(curl -fsS --max-time 5 "$url" 2>/dev/null)"
  else
    body="$(wget -q -T 5 -O - "$url" 2>/dev/null)"
  fi
  name="$(jq -r '(.data // .).branding.app_name // empty' 2>/dev/null <<<"$body")"
  # The name lands in HTML, so drop the characters that could close a tag.
  name="$(printf '%s' "$name" | tr -d '<>&"' | cut -c1-60)"
  [ -n "$name" ] && printf '%s' "$name" || printf 'the app'
}

# The bundled copy wins, for the same reason this script's does: it is the one
# `install.sh --refresh-bundle` keeps current.
install_progress_page() {
  local src=/opt/leera/progress.html
  [ -r "$INSTALL_DIR/update-progress.html" ] && src="$INSTALL_DIR/update-progress.html"

  local name
  name="$(progress_app_name)"
  # Literal substitution: `sed s///` would take `/` and `&` in the name as
  # syntax, and even awk's `gsub` treats `&` in the replacement specially.
  if ! awk -v name="$name" '
        { while ((i = index($0, "__APP_NAME__")) > 0)
            $0 = substr($0, 1, i - 1) name substr($0, i + 12)
          print }
      ' "$src" > "$DOCROOT/index.html.tmp" 2>/dev/null \
     || ! mv -f "$DOCROOT/index.html.tmp" "$DOCROOT/index.html" 2>/dev/null; then
    rm -f "$DOCROOT/index.html.tmp"
    cp -f "$src" "$DOCROOT/index.html" 2>/dev/null || log "could not publish the progress page"
  fi
}

# ── Heartbeat ─────────────────────────────────────────────────────────────────

# Presence, not configuration. The admin UI offers one-click updates only while
# this file is fresh, so removing the container makes the button disappear
# instead of failing when pressed.
write_heartbeat() {
  local busy="$1" token="${2:-}"
  jq -n \
    --arg version "${LEERA_UPDATER_VERSION:-bundled}" \
    --arg token "$token" \
    --argjson busy "$busy" \
    '{version: $version, seen_at: (now | floor), busy: $busy,
      token: (if $token == "" then null else $token end)}' \
    > "$HEARTBEAT_FILE.tmp" 2>/dev/null && mv -f "$HEARTBEAT_FILE.tmp" "$HEARTBEAT_FILE"
}

# Runs for the life of the container, including while an update is in flight —
# an instance mid-update must not look like one with no updater.
heartbeat_loop() {
  while true; do
    local busy=false token=""
    if [ -f "$CURRENT_FILE" ]; then
      busy=true
      token="$(jq -r '.token // ""' "$CURRENT_FILE" 2>/dev/null)"
    fi
    write_heartbeat "$busy" "$token"
    sleep "$HEARTBEAT_SECONDS"
  done
}

# ── Progress document ─────────────────────────────────────────────────────────

# The steps the UI draws, in order. Keys match the `step` values install.sh
# emits under --json-progress; a key here with no counterpart there simply
# stays pending, which is the failure mode we want if the two drift.
STEPS_TEMPLATE='[
  {"key":"preflight","label":"Checking this server","status":"pending"},
  {"key":"backup","label":"Backing up","status":"pending"},
  {"key":"bundle","label":"Fetching the new stack files","status":"pending"},
  {"key":"pull","label":"Downloading the new version","status":"pending"},
  {"key":"verify","label":"Verifying what was downloaded","status":"pending"},
  {"key":"migrate","label":"Updating the database","status":"pending"},
  {"key":"restart","label":"Restarting","status":"pending"},
  {"key":"health","label":"Checking it came back","status":"pending"}
]'

JOB_ID=""; TOKEN=""; TARGET=""; FROM_VERSION=""
STATUS="running"; STEP="preflight"; MESSAGE=""
STARTED_AT=0; FINISHED_AT="null"
STEPS_JSON="$STEPS_TEMPLATE"
LOG_FILE=""
STATE_FILE=""

render() {
  [ -n "$STATE_FILE" ] || return 0
  jq -n \
    --arg id "$JOB_ID" \
    --arg target "$TARGET" \
    --arg from "$FROM_VERSION" \
    --arg status "$STATUS" \
    --arg step "$STEP" \
    --arg message "$MESSAGE" \
    --argjson started "$STARTED_AT" \
    --argjson finished "$FINISHED_AT" \
    --argjson steps "$STEPS_JSON" \
    --rawfile logtext "$LOG_FILE" \
    '{id: $id, target_version: $target, from_version: $from,
      status: $status, step: $step, message: $message,
      started_at: $started, finished_at: $finished, updated_at: (now | floor),
      steps: $steps,
      log: ($logtext | split("\n") | map(select(length > 0)) | .[-200:])}' \
    > "$STATE_FILE.tmp" 2>/dev/null && mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

set_step() {
  local key="$1" status="$2"
  STEPS_JSON="$(jq -c --arg k "$key" --arg s "$status" \
    'map(if .key == $k then .status = $s else . end)' <<<"$STEPS_JSON")"
  [ "$status" = "running" ] && STEP="$key"
  # A step that fails leaves everything after it pending rather than pretending
  # those stages were skipped by choice.
  return 0
}

append_log() {
  printf '%s\n' "$1" >> "$LOG_FILE"
}

# Translate one line of install.sh output into progress.
handle_line() {
  local line="$1"

  if [[ "$line" == __EXIT__* ]]; then
    EXIT_CODE="${line#__EXIT__ }"
    return 0
  fi

  # Structured events when install.sh runs with --json-progress; anything else
  # (docker compose's own output) is kept as a log line, which is exactly what
  # someone reading a failure needs.
  if [[ "$line" == \{* ]] && jq -e . >/dev/null 2>&1 <<<"$line"; then
    local event
    event="$(jq -r '.event // "log"' <<<"$line")"
    case "$event" in
      step)
        set_step "$(jq -r '.step' <<<"$line")" "$(jq -r '.status' <<<"$line")"
        local msg; msg="$(jq -r '.message // ""' <<<"$line")"
        [ -n "$msg" ] && { MESSAGE="$msg"; append_log "$msg"; }
        ;;
      log)
        local msg; msg="$(jq -r '.message // ""' <<<"$line")"
        [ -n "$msg" ] && { MESSAGE="$msg"; append_log "$msg"; }
        ;;
      *)
        append_log "$(jq -r '.message // empty' <<<"$line")"
        ;;
    esac
  else
    append_log "$line"
  fi
  render
}

# ── Running one update ────────────────────────────────────────────────────────

finish() {
  local status="$1" message="$2"
  STATUS="$status"
  MESSAGE="$message"
  FINISHED_AT="$(date -u +%s)"
  render

  jq -n \
    --arg id "$JOB_ID" --arg target "$TARGET" --arg from "$FROM_VERSION" \
    --arg status "$status" --arg message "$message" \
    --arg backup "${BACKUP_PATH:-}" \
    '{id: $id, target_version: $target, from_version: $from, status: $status,
      finished_at: (now | floor), message: $message,
      backup_path: (if $backup == "" then null else $backup end)}' \
    > "$RESULT_FILE.tmp" && mv -f "$RESULT_FILE.tmp" "$RESULT_FILE"

  rm -f "$CURRENT_FILE"
  log "update $status: ${FROM_VERSION:-?} -> ${TARGET:-?} ($message)"
}

run_update() {
  JOB_ID="$(jq -r '.id // ""' "$CURRENT_FILE")"
  TOKEN="$(jq -r '.token // ""' "$CURRENT_FILE")"
  TARGET="$(jq -r '.target_version // ""' "$CURRENT_FILE")"
  FROM_VERSION="$(jq -r '.from_version // ""' "$CURRENT_FILE")"
  local skip_backup digest_api digest_web
  skip_backup="$(jq -r '.skip_backup // false' "$CURRENT_FILE")"
  digest_api="$(jq -r '.digests.api // ""' "$CURRENT_FILE")"
  digest_web="$(jq -r '.digests.web // ""' "$CURRENT_FILE")"

  # The token is a path segment in a URL Caddy serves. Anything but hex here
  # would be a directory-traversal write into the docroot.
  if [ -z "$TOKEN" ] || [[ ! "$TOKEN" =~ ^[0-9a-f]{8,64}$ ]]; then
    log "refusing a request with a malformed token"
    rm -f "$CURRENT_FILE"
    return 0
  fi
  if [ -z "$TARGET" ]; then
    log "refusing a request with no target version"
    rm -f "$CURRENT_FILE"
    return 0
  fi

  # Re-publish while the API is still up: the instance may have been renamed
  # since this container started, and the page is about to be the only thing
  # anyone can see.
  install_progress_page

  STATE_FILE="$DOCROOT/$TOKEN.json"
  LOG_FILE="$(mktemp)"
  STATUS="running"; STEP="preflight"; MESSAGE="Starting"
  STEPS_JSON="$STEPS_TEMPLATE"
  STARTED_AT="$(date -u +%s)"; FINISHED_AT="null"
  BACKUP_PATH=""
  EXIT_CODE=1
  render

  log "starting update ${FROM_VERSION:-?} -> $TARGET"

  local args=(--upgrade --to "$TARGET" --json-progress --refresh-bundle)
  [ "$skip_backup" = "true" ] && args+=(--skip-backup)

  # LEERA_HOME points install.sh at the bind-mounted install directory.
  # LEERA_DIGEST_* are checked after the pull: a tag that moved between the
  # signed manifest and the registry fails the update instead of quietly
  # installing something else.
  # COMPOSE_PROJECT_NAME is the one thing this container cannot let compose
  # work out for itself. Compose derives the project from the directory it runs
  # in, and here that is /install — not the host directory the stack was
  # created from. Left alone it addresses an empty project, so `up` collides
  # with the running containers by name and the update dies at the migrator.
  # install.sh pins this in .env, and this is the belt to that pair of braces:
  # it also covers an install whose .env predates that key.
  # Passed as an array so an unanswerable project name stays *unset* rather
  # than set-to-empty: an empty COMPOSE_PROJECT_NAME in the environment would
  # take precedence over the correct one in .env.
  local env_args=("LEERA_HOME=$INSTALL_DIR"
                  "LEERA_DIGEST_API=$digest_api"
                  "LEERA_DIGEST_WEB=$digest_web")
  local project
  project="$(stack_project_name)"
  [ -n "$project" ] && env_args+=("COMPOSE_PROJECT_NAME=$project")

  while IFS= read -r line; do
    handle_line "$line"
  done < <(
    cd "$INSTALL_DIR" || exit 1
    env "${env_args[@]}" bash ./install.sh "${args[@]}" 2>&1
    printf '__EXIT__ %s\n' "$?"
  )

  BACKUP_PATH="$(grep -o '/[^ ]*backups/[^ ]*' "$LOG_FILE" | tail -1 || true)"

  if [ "${EXIT_CODE:-1}" = "0" ]; then
    for k in preflight backup bundle pull verify migrate restart health; do
      STEPS_JSON="$(jq -c --arg k "$k" \
        'map(if .key == $k and .status == "running" then .status = "done" else . end)' \
        <<<"$STEPS_JSON")"
    done
    finish "success" "Updated to $TARGET"
  else
    set_step "$STEP" "failed"
    # install.sh reverts the version tag and restarts on a failed health check;
    # its own output says which happened, and that output is in the log the
    # page shows.
    finish "failed" "The update did not complete. The site is running the version it was on before."
  fi

  rm -f "$LOG_FILE"

  # Old progress documents are the only thing that accumulates here. Keep the
  # last few so a finished update can still be reviewed.
  ls -1t "$DOCROOT"/*.json 2>/dev/null | tail -n +6 | xargs -r rm -f
}

# ── Main loop ─────────────────────────────────────────────────────────────────

install_progress_page
write_heartbeat false
heartbeat_loop &
HEARTBEAT_PID=$!
trap 'kill "$HEARTBEAT_PID" 2>/dev/null' EXIT

# A request left claimed but unfinished means the container died mid-update.
# Resuming would re-run migrations against a database in an unknown state, so
# it is reported instead — the operator has the log and the pre-update backup.
if [ -f "$CURRENT_FILE" ]; then
  JOB_ID="$(jq -r '.id // ""' "$CURRENT_FILE")"
  TOKEN="$(jq -r '.token // ""' "$CURRENT_FILE")"
  TARGET="$(jq -r '.target_version // ""' "$CURRENT_FILE")"
  FROM_VERSION="$(jq -r '.from_version // ""' "$CURRENT_FILE")"
  if [[ "$TOKEN" =~ ^[0-9a-f]{8,64}$ ]]; then
    STATE_FILE="$DOCROOT/$TOKEN.json"
    LOG_FILE="$(mktemp)"
    append_log "The update service restarted while this update was running."
    set_step "$STEP" "failed"
    finish "failed" "The update was interrupted. Check the server before retrying."
    rm -f "$LOG_FILE"
  else
    rm -f "$CURRENT_FILE"
  fi
fi

log "watching for update requests (install dir: $INSTALL_DIR)"

while true; do
  if [ -f "$REQUEST_FILE" ]; then
    # Claim by rename: the API writes with write-then-rename, and this makes
    # the hand-off atomic from both ends.
    if mv -f "$REQUEST_FILE" "$CURRENT_FILE" 2>/dev/null; then
      run_update
      # Re-exec so a bundle refreshed by the update we just ran takes effect.
      # Nothing is in flight at this point, and the heartbeat resumes within a
      # second of the new process starting.
      if [ -r "$INSTALL_DIR/updater.sh" ]; then
        log "reloading the update service"
        kill "$HEARTBEAT_PID" 2>/dev/null
        exec bash "$INSTALL_DIR/updater.sh"
      fi
    fi
  fi
  sleep "$POLL_SECONDS"
done
