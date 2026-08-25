#!/usr/bin/env bash
# Copy the repo's plugin files into the installed plugin folder, then restart
# the Omarchy shell so the new QML is actually loaded.
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
target="$HOME/.config/omarchy/plugins/io.github.andy-spike.screen-temperature"

# Runtime files only; README, LICENSE, and tests are not loaded by the shell.
cp "$repo/manifest.json" \
   "$repo/Panel.qml" \
   "$repo/TemperatureSteps.js" \
   "$target/"

# A restart, not a rescan: rescanPlugins re-discovers plugins but leaves an
# already-instantiated panel running its old QML, so edits appear to do nothing.
omarchy-restart-shell
