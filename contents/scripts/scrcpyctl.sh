#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true

have() { command -v "$1" >/dev/null 2>&1; }
_uid() { id -u; }
_user() { id -un; }
LOG_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/scrcpycontrol/logs"

ensure_log_root() {
  if mkdir -p "$LOG_ROOT" 2>/dev/null; then
    return
  fi

  LOG_ROOT="/tmp/scrcpycontrol-logs-${UID}"
  mkdir -p "$LOG_ROOT"
}

hash_cmdline() {
  local s="$1"
  if have sha256sum; then printf "%s" "$s" | sha256sum | awk '{print $1}'
  elif have md5sum; then printf "%s" "$s" | md5sum | awk '{print $1}'
  else printf "%s" "$s" | wc -c | tr -d ' '
  fi
}

proc_start_ticks() { awk '{print $22}' "/proc/$1/stat"; }
proc_cmdline() { tr '\0' ' ' < "/proc/$1/cmdline" | sed 's/[[:space:]]\+$//'; }
proc_exe_base() {
  local p
  p="$(readlink -f "/proc/$1/exe" 2>/dev/null || true)"
  basename "$p"
}

deps() {
  local ok_adb=NO ok_scrcpy=NO
  have adb && ok_adb=OK
  have scrcpy && ok_scrcpy=OK
  echo "adb=$ok_adb"
  echo "scrcpy=$ok_scrcpy"
}

adb_connect() {
  local ep="${1:-}"
  if [[ -z "$ep" ]]; then
    echo "error=missing_endpoint"
    exit 2
  fi

  # Accept hostname/IPv4 endpoints and bracketed IPv6 endpoints.
  if ! [[ "$ep" =~ ^[A-Za-z0-9._-]+:[0-9]+$ || "$ep" =~ ^\[[^]]+\]:[0-9]+$ ]]; then
    echo "error=invalid_endpoint"
    exit 2
  fi

  local output rc
  set +e
  output="$(adb connect "$ep" 2>&1)"
  rc=$?
  set -e

  printf '%s\n' "$output" | sed 's/\r$//'
  if [[ $rc -eq 0 ]]; then
    echo "ok=1"
  else
    echo "ok=0"
    exit $rc
  fi
}

adb_tcpip() {
  local serial="${1:-}"
  local port="${2:-5555}"
  if [[ -z "$serial" ]]; then
    echo "error=missing_serial"
    exit 2
  fi
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    echo "error=invalid_port"
    exit 2
  fi

  local output rc
  set +e
  output="$(adb -s "$serial" tcpip "$port" 2>&1)"
  rc=$?
  set -e

  printf '%s\n' "$output" | sed 's/\r$//'
  if [[ $rc -eq 0 ]]; then
    echo "ok=1"
  else
    echo "ok=0"
    exit $rc
  fi
}

adb_device_ip() {
  local serial="${1:-}"
  if [[ -z "$serial" ]]; then
    echo "error=missing_serial"
    exit 2
  fi

  local ip=""
  set +e
  ip="$(adb -s "$serial" shell ip -f inet addr show wlan0 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1 | tr -d '\r')"
  if [[ -z "$ip" ]]; then
    ip="$(adb -s "$serial" shell ip route 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' | tr -d '\r')"
  fi
  set -e

  if [[ -n "$ip" ]]; then
    echo "ip=$ip"
    echo "ok=1"
  else
    echo "error=ip_not_found"
    exit 3
  fi
}

start() {
  local serial="${1:-}"; shift || true
  if [[ -z "$serial" ]]; then
    echo "error=missing_serial"
    exit 2
  fi

  ensure_log_root

  local args=()
  args+=( "scrcpy" "--serial" "$serial" )
  while [[ $# -gt 0 ]]; do
    args+=( "$1" ); shift
  done

  local logfile
  logfile="$(mktemp "$LOG_ROOT/scrcpy-XXXXXX.log")"

  "${args[@]}" >> "$logfile" 2>&1 &
  local pid=$!

  for _ in 1 2 3 4 5; do
    [[ -d "/proc/$pid" ]] && break
    sleep 0.02
  done

  if [[ ! -d "/proc/$pid" ]]; then
    echo "error=start_failed"
    exit 3
  fi

  local uid startticks cmdline h exe
  uid="$(_uid)"
  startticks="$(proc_start_ticks "$pid")"
  cmdline="$(proc_cmdline "$pid")"
  h="$(hash_cmdline "$cmdline")"
  exe="$(proc_exe_base "$pid")"

  echo "pid=$pid"
  echo "uid=$uid"
  echo "startticks=$startticks"
  echo "exe=$exe"
  echo "cmdhash=$h"
  echo "cmdline=$cmdline"
  echo "logfile=$logfile"
}

stop() {
  local pid="${1:-}"
  if [[ -z "$pid" ]]; then
    echo "error=missing_pid"
    exit 2
  fi

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    # Allow graceful shutdown before escalating to SIGKILL.
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.10
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  echo "ok=1"
}

scan() {
  local uid user
  uid="$(_uid)"
  user="$(_user)"

  # Enumerate scrcpy processes owned by the current user.
  local pids
  pids="$(ps -u "$user" -o pid=,comm= | awk '$2=="scrcpy"{print $1}')"

  while read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ -d "/proc/$pid" ]] || continue

    local owner exe startticks cmdline h
    owner="$(stat -c %u "/proc/$pid" 2>/dev/null || echo "")"
    [[ "$owner" == "$uid" ]] || continue

    exe="$(proc_exe_base "$pid")"
    cmdline="$(proc_cmdline "$pid")"
    startticks="$(proc_start_ticks "$pid")"
    h="$(hash_cmdline "$cmdline")"

    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$pid" "$uid" "$startticks" "$exe" "$h" "$cmdline"
  done <<< "$pids"
}

show_help() {
  if ! have scrcpy; then
    echo "error=scrcpy_missing"
    exit 2
  fi

  scrcpy --help 2>&1
}

read_log() {
  local path="${1:-}"
  local lines="${2:-400}"

  if [[ -z "$path" ]]; then
    echo "error=missing_log_path"
    exit 2
  fi

  if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
    echo "error=invalid_lines"
    exit 2
  fi

  ensure_log_root

  local real_root real_path
  real_root="$(realpath "$LOG_ROOT")"
  real_path="$(realpath "$path" 2>/dev/null || true)"

  if [[ -z "$real_path" || "${real_path#$real_root/}" == "$real_path" ]]; then
    echo "error=invalid_log_path"
    exit 2
  fi

  if [[ ! -r "$real_path" ]]; then
    echo "error=log_not_readable"
    exit 2
  fi

  tail -n "$lines" "$real_path"
}

case "$cmd" in
  deps) deps ;;
  connect) adb_connect "$@" ;;
  tcpip) adb_tcpip "$@" ;;
  deviceip) adb_device_ip "$@" ;;
  start) start "$@" ;;
  stop) stop "$@" ;;
  scan) scan ;;
  help) show_help ;;
  logread) read_log "$@" ;;
  *)
    echo "error=unknown_command"
    exit 1
    ;;
esac
