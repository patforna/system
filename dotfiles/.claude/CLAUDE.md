# Global Claude Code instructions — add preferences here when needed.

## Tools & Preferences

- **Google services**: Always use `gog` CLI (gogcli) for Gmail, Calendar, Chat, Classroom, Drive, Contacts, Tasks, Sheets, Docs, Slides, People, Forms, and App Script — in favour of browser automation or other approaches. The `gog` skill has the full CLI reference.
- **Email access**: A local Gmail archive is available via `msgvault` (DuckDB-backed, full-text search). Use it when searching/reading emails would help answer a question or complete a task. For reading/searching: prefer `msgvault search` (fast, offline, full history). Data may be up to 1 day stale — run `msgvault sync` first. For sending email or real-time operations (labels, drafts): use `gog gmail`.
