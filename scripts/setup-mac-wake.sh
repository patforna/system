#!/usr/bin/env bash
set -euo pipefail

# Schedule a daily macOS wake at 03:00 so dagu's 3 AM crons (msgvault-sync,
# tad-daily-code-review daily; jobs/tech-news digests Sat; drift-check Mon)
# fire even when the laptop lid is closed.
#
# NOT covered: tad-pipeline, which moved to 04:30 UTC (06:30 CEST, Tue–Sat) —
# it relies on the machine being awake by then, falling back to the
# `catchup_window: "24h"` in dotfiles/.config/dagu/base.yaml, which replays
# runs missed during sleep when the system next wakes (pmset supports only
# one repeat schedule, so a second wake slot is not an option).
#
# pmset only supports one repeat schedule at a time. Re-running this is safe —
# it overwrites the existing schedule. Persists across reboots (stored in NVRAM).
# Verify with: pmset -g sched

sudo pmset repeat wake MTWRFSU 03:00:00
echo "Scheduled wake:"
pmset -g sched
