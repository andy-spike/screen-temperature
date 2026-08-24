#!/usr/bin/env bash
# Copy the repo's plugin files into the installed plugin folder, then
# reload the plugin in the running Omarchy shell.
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
target="$HOME/.config/omarchy/plugins/io.github.andy-spike.screen-temperature"

# Runtime files only; README, LICENSE, and tests are not loaded by the shell.
cp "$repo/manifest.json" \
   "$repo/Panel.qml" \
   "$repo/ScheduleModel.js" \
   "$repo/schedule.py" \
   "$target/"

# Hot-reload on save is automatic; rescan forces plugin re-discovery too.
omarchy-shell -q shell rescanPlugins