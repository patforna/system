#!/usr/bin/env bash
set -euo pipefail

# Schedule a daily macOS wake at 03:00 so dagu's 3 AM crons (tad-pipeline,
# msgvault-sync, drift-check) fire even when the laptop lid is closed.
# 3 AM lands after US market data fully settles in Massive (8 PM ET / 2 AM CET),
# so the TAD pipeline gets the prior trading day's complete OHLCV.
#
# Pairs with `catchup_window: "24h"` in dotfiles/.config/dagu/base.yaml: any
# scheduled runs missed during sleep get replayed when the system next wakes.
#
# pmset only supports one repeat schedule at a time. Re-running this is safe —
# it overwrites the existing schedule. Persists across reboots (stored in NVRAM).
# Verify with: pmset -g sched

sudo pmset repeat wake MTWRFSU 03:00:00
echo "Scheduled wake:"
pmset -g sched
