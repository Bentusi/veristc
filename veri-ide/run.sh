#!/usr/bin/env bash
# Run VeriIDE, or check why it will not.
#
#   ./run.sh                 # diagnostics: what the next launch will use
#   ./run.sh dev             # desktop shell, hot-reloading (foreground, Ctrl-C ends it)
#   ./run.sh backend         # FastAPI sidecar + Vite only, for a browser at :1420
#   ./run.sh appimage        # the packaged bundle, as an end user would run it
#   ./run.sh stop            # stop what this script started
#
# Background launches are put in their own process group and recorded under .run/
# (log + PID per process), so `stop` takes down the whole tree of exactly what this
# script started -- and nothing else. A desktop shell killed with a plain `kill`
# leaves its sidecar on :8000; that orphan, not the bundle, is what usually makes
# the next launch look broken.
set -euo pipefail

IDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$IDE_DIR/.." && pwd)"
TAURI_DIR="$IDE_DIR/src-tauri"
WEB_DIR="$IDE_DIR/web"
VENV="$IDE_DIR/.venv"
RUN_DIR="$IDE_DIR/.run"
PY="$VENV/bin/python"
TAURI_CLI="$WEB_DIR/node_modules/.bin/tauri"

API_PORT=8000
WEB_PORT=1420
API_URL="http://127.0.0.1:$API_PORT"
WEB_URL="http://localhost:$WEB_PORT"

# The config's frontend hooks and the bundler need pnpm, which this host keeps
# outside the default PATH.
if ! command -v pnpm >/dev/null 2>&1 && [ -x /home/wei/.local/share/pnpm/bin/pnpm ]; then
  PATH="/home/wei/.local/share/pnpm/bin:$PATH"
  export PATH
fi

say() { printf '  %-22s %s\n' "$1" "${2:-—}"; }

listener_pid() {
  ss -ltnp 2>/dev/null | grep -m1 ":$1 " | grep -o 'pid=[0-9]*' | cut -d= -f2 || true
}

listener_cmd() {
  local pid
  pid=$(listener_pid "$1")
  [ -n "$pid" ] && ps -o pid=,args= -p "$pid" || true
}

wait_api() {
  local tries=${1:-40}
  for _ in $(seq 1 "$tries"); do
    curl -s -m 2 "$API_URL/health" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

start_group() {
  # start_group <name> <cwd> <command...>
  local name="$1" cwd="$2"
  shift 2
  mkdir -p "$RUN_DIR"
  setsid bash -c 'cd "$1"; shift; exec "$@"' _ "$cwd" "$@" >"$RUN_DIR/$name.log" 2>&1 &
  local pid=$!
  echo "$pid" >"$RUN_DIR/$name.pid"
  say "started $name" "pid $pid, log .run/$name.log"
}

stop_group() {
  local name="$1"
  local pidfile="$RUN_DIR/$name.pid"
  [ -f "$pidfile" ] || return 0
  local pid
  pid=$(cat "$pidfile")
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    say "stopped $name" "pid $pid"
  else
    say "$name" "already gone (pid $pid)"
  fi
  rm -f "$pidfile"
}

check() {
  echo "== workspace"
  say "component" "$IDE_DIR"
  say "venv" "$([ -x "$PY" ] && echo "$PY" || echo "MISSING -- python3 -m venv .venv && .venv/bin/pip install -e .")"
  say "pnpm" "$(command -v pnpm || echo 'MISSING -- pnpm not on PATH')"
  say "tauri CLI" "$([ -x "$TAURI_CLI" ] && echo yes || echo "MISSING -- pnpm install in web/")"

  echo
  echo "== runtime tools"
  for tool in veristc sim; do
    say "$tool" "$([ -x "$REPO_ROOT/build/bin/$tool" ] && echo "$REPO_ROOT/build/bin/$tool" || echo "MISSING -- make -C .. all")"
  done
  if [ -x "$PY" ]; then
    echo "  as the backend itself resolves them:"
    (cd "$IDE_DIR" && "$PY" -c '
from veri_ide.backend.build.service import find_veristc_binary
from veri_ide.backend.sim.session import find_sim_binary
for label, finder in (("veristc", find_veristc_binary), ("sim", find_sim_binary)):
    try:
        print("    %-10s %s" % (label, finder()))
    except FileNotFoundError as exc:
        print("    %-10s MISSING: %s" % (label, exc))')
  fi

  echo
  echo "== bundle"
  local image
  image=$(ls -t "$TAURI_DIR"/target/release/bundle/*/*.AppImage 2>/dev/null | head -1 || true)
  say "AppImage" "${image:-none -- ./package.sh}"
  say "payload" "$([ -d "$TAURI_DIR/payload/python" ] && echo "assembled, $(du -sh "$TAURI_DIR/payload/python" | cut -f1)" || echo "not assembled -- ./package.sh")"

  echo
  echo "== ports"
  say "$API_PORT" "$(listener_cmd $API_PORT)"
  say "$WEB_PORT" "$(listener_cmd $WEB_PORT)"
  if [ -n "$(listener_pid $API_PORT)" ]; then
    echo "  $API_PORT is held: the sidecar cannot bind it and the UI will report a"
    echo "  dead backend. If that is a VeriIDE leftover, ./run.sh stop or kill the PID above."
  fi
}

require_dev_env() {
  [ -x "$PY" ] || { echo "!! $VENV missing -- python3 -m venv .venv && .venv/bin/pip install -e ."; exit 1; }
  [ -x "$TAURI_CLI" ] || { echo "!! $TAURI_CLI missing -- pnpm install in web/"; exit 1; }
  for tool in veristc sim; do
    [ -x "$REPO_ROOT/build/bin/$tool" ] \
      || { echo "!! build/bin/$tool missing -- make -C .. all in $REPO_ROOT"; exit 1; }
  done
}

require_free_ports() {
  local port
  for port in "$@"; do
    if [ -n "$(listener_pid "$port")" ]; then
      echo "!! :$port already in use: $(listener_cmd "$port")"
      echo "   ./run.sh stop, or kill that PID."
      exit 1
    fi
  done
}

dev() {
  require_dev_env
  # A dev-mode sidecar from a previous run is the usual reason for a blank window.
  require_free_ports "$API_PORT"
  echo "== tauri dev"
  say "sidecar" "$PY (override with PYTHON=...)"
  say "tools" "$REPO_ROOT/build/bin/{veristc,sim}"
  say "frontend" "Vite on $WEB_URL, started by the config hook"
  echo "  Ctrl-C ends the shell, Vite and the sidecar together."
  # The CLI only searches downward for tauri.conf.json, so run it from src-tauri.
  cd "$TAURI_DIR"
  exec "$TAURI_CLI" dev
}

backend() {
  require_dev_env
  require_free_ports "$API_PORT" "$WEB_PORT"
  # The venv's own interpreter, so the sidecar imports the checkout, not a bundle.
  start_group api "$IDE_DIR" env -u PYTHONHOME -u PYTHONPATH "$PY" \
    -m uvicorn veri_ide.api.server:app --host 127.0.0.1 --port "$API_PORT"
  start_group web "$WEB_DIR" pnpm dev
  if wait_api; then
    echo "== ready"
    say "health" "$(curl -s -m 2 "$API_URL/health")"
    say "open" "$WEB_URL"
    echo "  ./run.sh stop ends both."
  else
    echo "!! the sidecar did not answer on $API_URL -- .run/api.log:"
    tail -10 "$RUN_DIR/api.log" || true
    exit 1
  fi
}

appimage() {
  local image
  image=$(ls -t "$TAURI_DIR"/target/release/bundle/*/*.AppImage 2>/dev/null | head -1 || true)
  [ -n "$image" ] || { echo "!! no AppImage yet -- ./package.sh"; exit 1; }
  require_free_ports "$API_PORT"
  echo "== launching the bundle from /tmp"
  echo "  Outside the repository on purpose: a bundle that only works from this"
  echo "  checkout is not a bundle."
  # `unset PYTHON` so the development override cannot point the shell at the checkout.
  start_group appimage /tmp env -u PYTHON "$image"
  if wait_api 60; then
    echo "== ready, and it came from the bundle:"
    grep -m1 "Starting sidecar" "$RUN_DIR/appimage.log" | sed 's/^/  /'
    say "health" "$(curl -s -m 2 "$API_URL/health")"
    echo "  window is open; log: .run/appimage.log -- ./run.sh stop closes it"
  else
    echo "!! the packaged sidecar did not answer -- .run/appimage.log:"
    tail -20 "$RUN_DIR/appimage.log" || true
    exit 1
  fi
}

stop() {
  echo "== stopping what run.sh started"
  stop_group appimage
  stop_group api
  stop_group web
  # SIGTERM is asynchronous and uvicorn takes a moment to release the port, so
  # reporting immediately would blame a stranger for a port we just freed.
  for _ in $(seq 1 12); do
    [ -z "$(listener_pid $API_PORT)" ] && break
    sleep 0.5
  done
  if [ -n "$(listener_pid $API_PORT)" ]; then
    echo "  :$API_PORT is still held by: $(listener_cmd $API_PORT)"
    echo "  That is not one of ours -- kill it yourself if you want the port free."
  else
    say "ports" "$API_PORT and $WEB_PORT free"
  fi
}

case "${1:-check}" in
  check)                check ;;
  dev)                  dev ;;
  backend)              backend ;;
  appimage | packaged)  appimage ;;
  stop)                 stop ;;
  -h | --help | help)   sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *)                    echo "unknown command: $1 (try ./run.sh --help)"; exit 1 ;;
esac
