#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$project_root/contents/scripts/scrcpyctl.sh"
node "$project_root/tests/logic.test.js"
bash "$project_root/tests/helper.test.sh"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$project_root/contents/scripts/scrcpyctl.sh" "$project_root/tests/"*.sh
fi

if command -v qmllint >/dev/null 2>&1; then
  qmllint "$project_root/contents/ui/"*.qml "$project_root/contents/config/"*.qml
fi

if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool "$project_root/metadata.json" >/dev/null
fi

if command -v msgfmt >/dev/null 2>&1; then
  for language in ru uk; do
    msgfmt --check --check-format -o /dev/null \
      "$project_root/contents/locale/$language/LC_MESSAGES/plasma_applet_org.kde.scrcpycontrol.po"
  done
fi

echo "all tests passed"
