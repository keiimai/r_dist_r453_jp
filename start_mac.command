#!/bin/bash
# =============================================================================
# Start the R analysis environment (Mac). In Terminal, type "bash ", drag this file in, and press Enter
# (if you double-click it, macOS blocks it as a downloaded file; see step 3 of HOW_TO_USE_Mac.html)
# -----------------------------------------------------------------------------
#   1. Check that Docker Desktop is running (if it is stopped, start it and wait)
#   2. Build the image (a few minutes to over ten minutes the first time; tens of seconds after that)
#   3. Start RStudio and open it in the browser
#   4. Press Enter in this window to stop
# The names (of the Docker image and container) are made from this folder's name and location, so
# even if you copy the folder and use it for another analysis, they do not conflict with each other.
# To only diagnose the environment, use diagnose_mac.command (it starts nothing; "If something goes wrong" in HOW_TO_USE_Mac.html).
# =============================================================================
set -u
cd "$(dirname "$0")" || exit 1

# --- This file stays ASCII only; the messages are read by name from launcher/start_messages.txt (UTF-8), as start_windows.bat does ---
MESSAGES_FILE="$PWD/launcher/start_messages.txt"
msg() {
  local text
  text="$(/usr/bin/awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$MESSAGES_FILE" 2>/dev/null)"
  if [ -z "$text" ]; then printf '[start_messages.txt: %s] %s' "$1" "${2:-}"; return 0; fi
  printf '%s' "${text//\{0\}/${2:-}}"
}

# --- If the launcher window (Start RStudio.app) is here, open it and finish; the window runs this file with --gui-worker (step 3 of HOW_TO_USE_Mac.html) ---
GUI=""
if [ "${1:-}" = --gui-worker ]; then
  GUI=1
elif [ -d "Start RStudio.app" ]; then
  /usr/bin/xattr -dr com.apple.quarantine "$PWD" 2>/dev/null || :
  exec /usr/bin/open "$PWD/Start RStudio.app"
fi
ui_event() { [ -z "$GUI" ] || printf 'LAUNCHER_UI\t%s\t%s\n' "$1" "${2:-}"; }

# --- Add the progress to outputs/launcher/launch_<launch ID>.jsonl one line at a time (R_LAUNCHER_RECORD=0 turns it off; "If something goes wrong" in HOW_TO_USE_Mac.html) ---
LOG=""
LID="$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%05d' "$RANDOM")"
rec() {
  [ -n "$LOG" ] || return 0
  printf '{"v":1,"id":"%s","t":"%s","sec":%d,"stage":"%s","rc":%s}\n' \
    "$LID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SECONDS" "$1" "${2:-null}" >> "$LOG" 2>/dev/null \
    || { LOG=""; echo "$(msg record_failed)"; }
}

# --- Before stopping, wait so the message can be read ---
fail() {
  printf '\n\033[31m%s\033[0m\n' "$1"
  [ -n "$GUI" ] || read -r -p "$(msg press_enter_close)" _
  rec launch_end 1
  exit 1
}

# --- Find the docker command that Docker Desktop installs ---
PATH="$PATH:/usr/local/bin:$HOME/.docker/bin:/Applications/Docker.app/Contents/Resources/bin"

ask() (
  local limit=$((deadline - SECONDS)) pid end n
  [ "$limit" -gt "$1" ] && limit=$1
  [ "$limit" -gt 0 ] || return 125
  shift
  end=$((SECONDS + limit))
  # Always isolate job control and traps, including direct calls from docker_ready().
  set -m
  "$@" > "$tmp" 2>/dev/null &
  pid=$!
  trap '[ "$(jobs -pr)" != "'"$pid"'" ] || kill -KILL -- "-'"$pid"'" 2>/dev/null' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$end" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || :
      # Give it at most half a second, without extending the global deadline.
      n=0
      while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 5 ] && [ "$SECONDS" -lt "$deadline" ]; do
        sleep 0.1
        n=$((n + 1))
      done
      [ "$(jobs -pr)" != "$pid" ] || kill -KILL -- "-$pid" 2>/dev/null || :
      # Never wait for a process that has not actually ended.
      if ! kill -0 "$pid" 2>/dev/null; then wait "$pid" 2>/dev/null || :; fi
      return 124
    fi
    sleep 0.1
  done
  wait "$pid" 2>/dev/null || return 1
  head -n 1 "$tmp" | tr -cd 'A-Za-z0-9 ._,:+/()|-'
) 2>/dev/null

[ -f docker-compose.yml ] && [ -f Dockerfile ] \
  || fail "$(msg not_project)"
if [ "${R_LAUNCHER_RECORD:-1}" != 0 ]; then
  mkdir -p outputs/launcher 2>/dev/null && LOG="outputs/launcher/launch_$LID.jsonl"
  [ -n "$LOG" ] || echo "$(msg record_failed)"
  rec launch_start
fi
command -v docker >/dev/null 2>&1 \
  || { rec docker_missing; fail "$(msg no_docker)"; }

# --- If Docker Desktop is not running, start it and wait until it is ready (up to 2 minutes) ---
docker_ready() {
  local info
  ask 5 docker info --format '{{.ServerVersion}}|{{.OSType}}|{{.NCPU}}|{{.MemTotal}}' >/dev/null || return 1
  info="$(head -c 512 "$tmp")"
  local pattern='^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\|linux\|[1-9][0-9]{0,8}\|[1-9][0-9]{0,17}$'
  [[ "$info" =~ $pattern ]]
}
rec docker_check
deadline=$((SECONDS + 120))
tmp="$(mktemp -t launcher_engine)" || fail "$(msg tmp_failed)"
if ! docker_ready; then
  echo "$(msg starting_docker)"
  rec docker_starting
  open -a Docker 2>/dev/null
  ready=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 2
    if docker_ready; then ready=1; break; fi
  done
  if [ "$ready" -ne 1 ]; then
    rm -f "$tmp"
    rec docker_timeout 1
    fail "$(msg docker_not_ready)"
  fi
fi
rm -f "$tmp"
rec docker_ready 0

# --- Name: folder name (lowercase letters and digits only) + 6 digits made from the location ---
base="$(basename "$PWD" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
hash="$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"
NAME="${base:-r}-$(printf '%06d' $((hash % 1000000)))"

# --- Match the CPU (arm64 for Apple Silicon, amd64 for Intel) ---
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
  PLATFORM=linux/arm64
else
  PLATFORM=linux/amd64
fi
TMPDIR_L="$(mktemp -d -t rlauncher)"
OVERRIDE="$TMPDIR_L/override.yml"
printf 'services:\n  dev:\n    platform: %s\n  lock:\n    platform: %s\n' "$PLATFORM" "$PLATFORM" > "$OVERRIDE"
compose() { docker compose -p "$NAME" -f docker-compose.yml -f "$OVERRIDE" "$@"; }

# --- Build the image (if nothing changed, the cached build is reused, so it is fast) ---
echo "$(msg preparing)"
# Pass the git commit if there is git, otherwise the version stamp (the template line of TEMPLATE_VERSION.txt), to the image's vcs_ref
vcs_ref=""
[ -e .git ] && vcs_ref="$(git describe --always --dirty --abbrev=40 --exclude='*' 2>/dev/null)"
[ -n "$vcs_ref" ] || vcs_ref="$(awk '$1 == "template" {print $3; exit}' TEMPLATE_VERSION.txt 2>/dev/null)"
[ -n "$vcs_ref" ] || vcs_ref=unknown
build_dev() {
  rec build_start
  docker build --platform "$PLATFORM" --target dev \
    --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --build-arg VCS_REF="$vcs_ref" --build-arg IMAGE_NAME="$NAME" \
    -t "$NAME:dev" .
  local rc=$?
  rec build_end "$rc"
  return "$rc"
}

# --- If packages were added to DESCRIPTION, rebuild the package list (renv.lock) and rebuild the image too ---
# (if an added package is not in renv.lock, the final check of the image stops the build; even if it does not stop, check for a mismatch)
relock() {
  echo "$(msg relocking)"
  rec relock_start
  docker build --platform "$PLATFORM" --target bootstrap -t "$NAME:bootstrap" . \
    && compose run --rm --user rstudio -v renv-cache:/opt/renv/cache lock Rscript --vanilla tools/make_lockfile.R
  local rc=$?
  rec relock_end "$rc"
  [ "$rc" -eq 0 ] || fail "$(msg relock_failed)"
  build_dev || fail "$(msg build_failed)"
}
if ! build_dev; then
  relock
else
  compose run --rm --user rstudio dev Rscript --vanilla tools/make_lockfile.R --check >/dev/null 2>&1
  rc=$?
  rec lock_check_end "$rc"
  [ "$rc" -eq 0 ] || relock
fi

# --- Start RStudio, and when it responds, open it in the browser ---
compose up -d dev
rc=$?
rec up_end "$rc"
[ "$rc" -eq 0 ] || fail "$(msg up_failed)"
trap 'echo; echo "$(msg stopping)"; rec interrupt; compose down; rc=$?; rec down_end "$rc"; rm -rf "$TMPDIR_L"; rec launch_end "$rc"; exit "$rc"' INT TERM
url=""
for _ in $(seq 1 90); do
  sleep 1
  port="$(compose port dev 8787 2>/dev/null)"
  [ -n "$port" ] || continue
  curl -fs --max-time 2 -o /dev/null "http://$port/" || continue
  url="http://localhost:${port##*:}"
  break
done
[ -n "$url" ] || { rec ui_timeout 1; compose down; rec down_end $?; rm -rf "$TMPDIR_L"; fail "$(msg no_response)"; }
rec ui_ready 0
printf '\n\033[36m%s\033[0m\n' "$(msg ready "$url")"
if [ -n "$GUI" ]; then
  # --- Wait for "Stop" (a stop line) from the window; if stopping fails, tell the window and wait again. If the window closes, stop below and finish ---
  ui_event READY "$url"
  while IFS= read -r action; do
    [ "$action" = stop ] || continue
    rec stop_requested
    echo "$(msg stopping)"
    compose down
    rc=$?
    rec down_end "$rc"
    if [ "$rc" -eq 0 ]; then rm -rf "$TMPDIR_L"; echo "$(msg stopped)"; rec launch_end 0; exit 0; fi
    ui_event STOP_FAILED
  done
  rec stop_requested
else
  open "$url"
  printf '%s\n\n' "$(msg browser_hint)"
  read -r -p "$(msg enter_to_stop)" _
  rec stop_requested
fi

# --- Stop and clean up (the built image is kept, so the next start is fast) ---
echo "$(msg stopping)"
compose down
rc=$?
rec down_end "$rc"
rm -rf "$TMPDIR_L"
[ "$rc" -eq 0 ] || fail "$(msg stop_failed)"
echo "$(msg stopped)"
rec launch_end 0
exit 0
