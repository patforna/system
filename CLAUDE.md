# System

Project guidance for working in this repo. Cross-cutting personal context lives in the user-global `~/.claude/CLAUDE.md` (System Maintenance pointer); the details below stay here, where they're scoped to this repo and auto-loaded when you work in it.

**IMPORTANT**: When making system-wide changes, **ALWAYS** make sure it's reflected in the system repo (Brewfile, dotfiles, scripts, etc.), update documentation, run `drift-check`, and push changes.

**IMPORTANT**: Before fixing something in this repo that has broken before, read `private/GOTCHAS.md` first. If a fix doesn't hold, append an entry there (append-only). Never stack another patch on a hypothesis already recorded with "No" under "Did it work?" — escalate instead. Don't go in circles.
