#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$project_root/contents/scripts/scrcpyctl.sh"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "$test_tmp"' EXIT

cp "$project_root/tests/fake-adb.sh" "$test_tmp/adb"
chmod +x "$test_tmp/adb"
test_path="$test_tmp:$PATH"

run_helper() {
  local scenario="$1"
  shift
  PATH="$test_path" FAKE_ADB_SCENARIO="$scenario" bash "$helper" "$@"
}

output="$(run_helper connect_success connect phone.local:5555)"
grep -qx 'status=success' <<< "$output"
grep -qx 'code=connected' <<< "$output"
grep -qx "endpoint_b64=$(printf '%s' 'phone.local:5555' | base64 | tr -d '\n')" <<< "$output"
grep -qx "stable_id_b64=$(printf '%s' 'USB123' | base64 | tr -d '\n')" <<< "$output"

if output="$(run_helper connect_text_failure connect phone.local:5555 2>&1)"; then
  echo "textual adb failure was incorrectly accepted" >&2
  exit 1
fi
grep -qx 'status=error' <<< "$output"
grep -qx 'code=verification_failed' <<< "$output"

output="$(run_helper pair_success pair phone.local:37123 123456)"
grep -qx 'status=success' <<< "$output"
grep -qx 'code=paired' <<< "$output"

if output="$(run_helper pair_failure pair phone.local:37123 123456 2>&1)"; then
  echo "failed pairing was incorrectly accepted" >&2
  exit 1
fi
grep -qx 'code=pair_failed' <<< "$output"

if output="$(run_helper connect_success connect phone.local:0 2>&1)"; then
  echo "invalid port was incorrectly accepted" >&2
  exit 1
fi
grep -qx 'code=invalid_endpoint' <<< "$output"

output="$(run_helper legacy_success legacy-setup USB123 5555)"
grep -qx 'status=success' <<< "$output"
grep -qx 'code=legacy_connected' <<< "$output"
grep -qx "endpoint_b64=$(printf '%s' '192.168.1.20:5555' | base64 | tr -d '\n')" <<< "$output"

output="$(run_helper disconnect_success disconnect phone.local:5555)"
grep -qx 'code=disconnected' <<< "$output"

output="$(run_helper usb_success usb phone.local:5555)"
grep -qx 'code=usb_mode_enabled' <<< "$output"

echo "helper tests passed"
