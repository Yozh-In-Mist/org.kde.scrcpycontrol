#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -u

scenario="${FAKE_ADB_SCENARIO:-}"
command_line="$*"

case "$scenario:$command_line" in
  connect_success:"connect phone.local:5555")
    echo "connected to phone.local:5555"
    ;;
  connect_success:"-s phone.local:5555 get-state")
    echo "device"
    ;;
  connect_success:"-s phone.local:5555 shell getprop ro.serialno")
    echo "USB123"
    ;;
  connect_success:"-s phone.local:5555 shell getprop ro.boot.serialno")
    echo "USB123"
    ;;

  connect_text_failure:"connect phone.local:5555")
    echo "failed to connect to phone.local:5555"
    ;;
  connect_text_failure:"-s phone.local:5555 get-state")
    echo "unknown"
    exit 1
    ;;

  pair_success:"pair phone.local:37123 123456")
    echo "Successfully paired to phone.local:37123"
    ;;
  pair_failure:"pair phone.local:37123 123456")
    echo "Failed: Wrong password"
    exit 1
    ;;

  legacy_success:"-s USB123 get-state")
    echo "device"
    ;;
  legacy_success:"-s USB123 shell ip route")
    echo "192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.20"
    ;;
  legacy_success:"-s USB123 shell getprop ro.serialno")
    echo "USB123"
    ;;
  legacy_success:"-s USB123 shell getprop ro.boot.serialno")
    echo "USB123"
    ;;
  legacy_success:"-s USB123 tcpip 5555")
    echo "restarting in TCP mode port: 5555"
    ;;
  legacy_success:"connect 192.168.1.20:5555")
    echo "connected to 192.168.1.20:5555"
    ;;
  legacy_success:"-s 192.168.1.20:5555 get-state")
    echo "device"
    ;;

  disconnect_success:"disconnect phone.local:5555")
    echo "disconnected phone.local:5555"
    ;;
  usb_success:"-s phone.local:5555 usb")
    echo "restarting in USB mode"
    ;;

  *)
    echo "unexpected fake adb invocation: $command_line" >&2
    exit 97
    ;;
esac
