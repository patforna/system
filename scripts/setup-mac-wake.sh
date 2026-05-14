#!/usr/bin/env bash
set -euo pipefail

# Schedule a daily macOS wake at 00:00 so dagu's midnight crons (msgvault-sync,
# drift-check) fire even when the laptop lid is closed.
#
# Pairs with `catchup_window: "24h"` in dotfiles/.config/dagu/base.yaml: any
# scheduled runs missed during sleep get replayed when the system next wakes.
#
# pmset only supports one repeat schedule at a time. Re-running this is safe —
# it overwrites the existing schedule. Persists across reboots (stored in NVRAM).
# Verify with: pmset -g sched

sudo pmset repeat wake MTWRFSU 00:00:00
echo "Scheduled wake:"
pmset -g sched
