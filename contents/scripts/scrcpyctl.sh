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
  local ok_adb=NO ok_scrcpy=NO ok_coreutils=NO
  have adb && ok_adb=OK
  have scrcpy && ok_scrcpy=OK
  if have base64 && have timeout && have realpath && have sha256sum; then
    ok_coreutils=OK
  fi
  echo "adb=$ok_adb"
  echo "scrcpy=$ok_scrcpy"
  echo "coreutils=$ok_coreutils"
}

CAPTURE_OUTPUT=""
CAPTURE_RC=0

capture() {
  local seconds="$1"
  shift

  set +e
  CAPTURE_OUTPUT="$(timeout --foreground "${seconds}s" "$@" 2>&1)"
  CAPTURE_RC=$?
  set -e
  CAPTURE_OUTPUT="$(printf '%s' "$CAPTURE_OUTPUT" | sed 's/\r$//')"
}

emit_b64() {
  local key="$1"
  local value="${2:-}"
  printf '%s=' "$key"
  printf '%s' "$value" | base64 | tr -d '\n'
  printf '\n'
}

emit_result() {
  local status="$1"
  local code="$2"
  local detail="${3:-}"
  local endpoint="${4:-}"
  local serial="${5:-}"
  local stable_id="${6:-}"

  printf 'status=%s\n' "$status"
  printf 'code=%s\n' "$code"
  emit_b64 detail_b64 "$detail"
  [[ -z "$endpoint" ]] || emit_b64 endpoint_b64 "$endpoint"
  [[ -z "$serial" ]] || emit_b64 serial_b64 "$serial"
  [[ -z "$stable_id" ]] || emit_b64 stable_id_b64 "$stable_id"
}

fail_result() {
  local code="$1"
  local detail="${2:-}"
  local rc="${3:-1}"
  emit_result error "$code" "$detail"
  exit "$rc"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  [[ ${#port} -le 5 ]] || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

ENDPOINT_HOST=""
ENDPOINT_PORT=""
validate_endpoint() {
  local endpoint="$1"
  ENDPOINT_HOST=""
  ENDPOINT_PORT=""

  if [[ "$endpoint" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    ENDPOINT_HOST="[${BASH_REMATCH[1]}]"
    ENDPOINT_PORT="${BASH_REMATCH[2]}"
  elif [[ "$endpoint" =~ ^([A-Za-z0-9._-]+):([0-9]+)$ ]]; then
    ENDPOINT_HOST="${BASH_REMATCH[1]}"
    ENDPOINT_PORT="${BASH_REMATCH[2]}"
  else
    return 1
  fi

  validate_port "$ENDPOINT_PORT"
}

is_ipv4() {
  local value="$1"
  local a b c d extra octet
  IFS=. read -r a b c d extra <<< "$value"
  [[ -z "${extra:-}" && -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
  done
}

adb_online() {
  local serial="$1"
  capture 2 adb -s "$serial" get-state
  [[ $CAPTURE_RC -eq 0 ]] && printf '%s\n' "$CAPTURE_OUTPUT" | grep -qx 'device'
}

wait_for_adb_online() {
  local serial="$1"
  local attempts="${2:-10}"
  local attempt
  for ((attempt = 0; attempt < attempts; attempt++)); do
    if adb_online "$serial"; then
      return 0
    fi
    sleep 0.4
  done
  return 1
}

device_stable_id() {
  local serial="$1"
  local value=""

  capture 3 adb -s "$serial" shell getprop ro.serialno
  if [[ $CAPTURE_RC -eq 0 ]]; then
    value="$(printf '%s\n' "$CAPTURE_OUTPUT" | awk 'NF { value=$0 } END { print value }')"
  fi
  if [[ -z "$value" || "$value" == "unknown" ]]; then
    capture 3 adb -s "$serial" shell getprop ro.boot.serialno
    if [[ $CAPTURE_RC -eq 0 ]]; then
      value="$(printf '%s\n' "$CAPTURE_OUTPUT" | awk 'NF { value=$0 } END { print value }')"
    fi
  fi

  [[ -n "$value" && "$value" != "unknown" ]] && printf '%s\n' "$value" || printf '%s\n' "$serial"
}

device_ipv4() {
  local serial="$1"
  local output=""
  local ip=""

  capture 3 adb -s "$serial" shell ip route
  if [[ $CAPTURE_RC -eq 0 ]]; then
    output="$CAPTURE_OUTPUT"
    ip="$(printf '%s\n' "$output" | awk '
      {
        iface=""; source=""
        for (i=1; i<=NF; i++) {
          if ($i == "dev" && i < NF) iface=$(i+1)
          if ($i == "src" && i < NF) source=$(i+1)
        }
        if (iface ~ /^(wlan|wifi)/ && source != "") { print source; exit }
      }')"
  fi

  if ! is_ipv4 "$ip" 2>/dev/null; then
    capture 3 adb -s "$serial" shell ip -o -4 addr show scope global up
    if [[ $CAPTURE_RC -eq 0 ]]; then
      output="$CAPTURE_OUTPUT"
      ip="$(printf '%s\n' "$output" | awk '$2 ~ /^(wlan|wifi)/ { split($4, address, "/"); print address[1]; exit }')"
    fi
  fi

  if ! is_ipv4 "$ip" 2>/dev/null; then
    capture 3 adb -s "$serial" shell ip -f inet addr show wlan0
    if [[ $CAPTURE_RC -eq 0 ]]; then
      ip="$(printf '%s\n' "$CAPTURE_OUTPUT" | awk '/inet / { split($2, address, "/"); print address[1]; exit }')"
    fi
  fi

  is_ipv4 "$ip" 2>/dev/null || return 1
  printf '%s\n' "$ip"
}

adb_connect() {
  local endpoint="${1:-}"
  [[ -n "$endpoint" ]] || fail_result missing_endpoint "No ADB endpoint was provided." 2
  validate_endpoint "$endpoint" || fail_result invalid_endpoint "Expected host:port or [IPv6]:port with a port from 1 to 65535." 2
  endpoint="${ENDPOINT_HOST}:$((10#$ENDPOINT_PORT))"

  capture 12 adb connect "$endpoint"
  local connect_output="$CAPTURE_OUTPUT"
  local connect_rc=$CAPTURE_RC
  if [[ $connect_rc -eq 124 ]]; then
    fail_result timeout "$connect_output"
  fi

  if wait_for_adb_online "$endpoint" 5; then
    local stable_id
    stable_id="$(device_stable_id "$endpoint")"
    emit_result success connected "$connect_output" "$endpoint" "$endpoint" "$stable_id"
    return
  fi

  [[ $connect_rc -eq 0 ]] || fail_result connect_failed "$connect_output" "$connect_rc"
  fail_result verification_failed "$connect_output"
}

adb_pair() {
  local endpoint="${1:-}"
  local pairing_code="${2:-}"
  [[ -n "$endpoint" ]] || fail_result missing_endpoint "No pairing endpoint was provided." 2
  validate_endpoint "$endpoint" || fail_result invalid_endpoint "Expected host:port or [IPv6]:port with a port from 1 to 65535." 2
  [[ "$pairing_code" =~ ^[0-9]{6}$ ]] || fail_result invalid_pairing_code "The pairing code must contain exactly six digits." 2
  endpoint="${ENDPOINT_HOST}:$((10#$ENDPOINT_PORT))"

  capture 20 adb pair "$endpoint" "$pairing_code"
  local output="$CAPTURE_OUTPUT"
  local rc=$CAPTURE_RC
  pairing_code=""

  if [[ $rc -eq 124 ]]; then
    fail_result timeout "$output"
  fi
  if [[ $rc -eq 0 ]] && printf '%s\n' "$output" | grep -qiE 'successfully paired|already paired'; then
    emit_result success paired "$output" "$endpoint"
    return
  fi

  [[ $rc -ne 0 ]] || rc=1
  fail_result pair_failed "$output" "$rc"
}

adb_identity() {
  local serial="${1:-}"
  [[ -n "$serial" ]] || fail_result missing_serial "No ADB serial was provided." 2
  if ! adb_online "$serial"; then
    fail_result device_unavailable "$CAPTURE_OUTPUT"
  fi

  local stable_id
  stable_id="$(device_stable_id "$serial")"
  emit_result success identity_resolved "" "" "$serial" "$stable_id"
}

adb_legacy_setup() {
  local serial="${1:-}"
  local port="${2:-5555}"
  [[ -n "$serial" ]] || fail_result missing_serial "No USB device was selected." 2
  validate_port "$port" || fail_result invalid_port "The TCP port must be from 1 to 65535." 2
  port="$((10#$port))"

  if ! adb_online "$serial"; then
    fail_result device_unavailable "$CAPTURE_OUTPUT"
  fi

  local ip stable_id
  ip="$(device_ipv4 "$serial" || true)"
  [[ -n "$ip" ]] || fail_result ip_not_found "No active Wi-Fi IPv4 address was found on the selected device."
  stable_id="$(device_stable_id "$serial")"

  capture 8 adb -s "$serial" tcpip "$port"
  local tcpip_output="$CAPTURE_OUTPUT"
  local tcpip_rc=$CAPTURE_RC
  if [[ $tcpip_rc -eq 124 ]]; then
    fail_result timeout "$tcpip_output"
  fi
  [[ $tcpip_rc -eq 0 ]] || fail_result tcpip_failed "$tcpip_output" "$tcpip_rc"

  local endpoint="${ip}:${port}"
  local connect_output=""
  local attempt
  for attempt in 1 2; do
    sleep 0.6
    capture 6 adb connect "$endpoint"
    connect_output="$CAPTURE_OUTPUT"
    if wait_for_adb_online "$endpoint" 3; then
      emit_result success legacy_connected "${tcpip_output}"$'\n'"${connect_output}" "$endpoint" "$endpoint" "$stable_id"
      return
    fi
  done

  fail_result verification_failed "${tcpip_output}"$'\n'"${connect_output}"
}

adb_disconnect() {
  local serial="${1:-}"
  [[ -n "$serial" ]] || fail_result missing_serial "No wireless device was selected." 2

  capture 10 adb disconnect "$serial"
  local output="$CAPTURE_OUTPUT"
  local rc=$CAPTURE_RC
  if [[ $rc -eq 124 ]]; then
    fail_result timeout "$output"
  fi
  [[ $rc -eq 0 ]] || fail_result disconnect_failed "$output" "$rc"
  emit_result success disconnected "$output" "" "$serial"
}

adb_usb_mode() {
  local serial="${1:-}"
  [[ -n "$serial" ]] || fail_result missing_serial "No device was selected." 2

  capture 10 adb -s "$serial" usb
  local output="$CAPTURE_OUTPUT"
  local rc=$CAPTURE_RC
  if [[ $rc -eq 124 ]]; then
    fail_result timeout "$output"
  fi
  [[ $rc -eq 0 ]] || fail_result usb_mode_failed "$output" "$rc"
  emit_result success usb_mode_enabled "$output" "" "$serial"
}

# Kept as small helper commands for scripts using the original interface.
adb_tcpip() {
  local serial="${1:-}"
  local port="${2:-5555}"
  [[ -n "$serial" ]] || fail_result missing_serial "No ADB serial was provided." 2
  validate_port "$port" || fail_result invalid_port "The TCP port must be from 1 to 65535." 2
  capture 12 adb -s "$serial" tcpip "$((10#$port))"
  [[ $CAPTURE_RC -eq 0 ]] || fail_result tcpip_failed "$CAPTURE_OUTPUT" "$CAPTURE_RC"
  emit_result success tcpip_enabled "$CAPTURE_OUTPUT" "" "$serial"
}

adb_device_ip() {
  local serial="${1:-}"
  [[ -n "$serial" ]] || fail_result missing_serial "No ADB serial was provided." 2
  local ip
  ip="$(device_ipv4 "$serial" || true)"
  [[ -n "$ip" ]] || fail_result ip_not_found "No active Wi-Fi IPv4 address was found on the selected device."
  emit_result success ip_detected "" "$ip" "$serial"
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
  pair) adb_pair "$@" ;;
  identity) adb_identity "$@" ;;
  legacy-setup) adb_legacy_setup "$@" ;;
  disconnect) adb_disconnect "$@" ;;
  usb) adb_usb_mode "$@" ;;
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
