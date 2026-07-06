---
title: Restructure tech-news digest into script-driven phases
date: 2026-07-06
status: ready-for-dev
type: tech
---

## Restructure Tech-news Digest into Script-driven Phases

Make the tech-news digest script orchestrate the pipeline, with the model only doing judgment: per-chunk extraction of stories as structured JSON, merge and link canonicalisation in code, one ranking call over the compact item list, and a templated HTML render. This removes the pipeline's main silent-failure modes.

### Acceptance Criteria

- Fetch, scheduling, and send are unchanged.
- Extraction runs per message (or small chunk of messages), never over the whole corpus. Each call returns items as JSON validated against a schema: title, tldr, source, url, importance band (incl. skip for filler), and source message id (validated against the chunk). Sponsored/advertorial content is excluded and uncounted. A call still returning invalid JSON after 2 retries is logged and skipped.
- Coverage is computed by the script (messages extracted vs fetched); a failed chunk counts all its messages as unextracted. The run aborts without sending if more than 10% of fetched messages fail extraction.
- Links are canonicalised by the script, network allowed: tracking wrappers (beehiiv, substack, mailchimp, etc.) resolved by following redirects with a short timeout, tracking params (utm_*, ref) stripped. If resolution fails, keep the wrapped URL with params stripped; items with no link at all fall back to the Gmail deep-link, as today.
- Exact duplicates (same canonical URL) are merged in code; judgment clustering (same story across newsletters) stays in the ranking call.
- Ranking is a single LLM call that sees only the merged item list (skip-banded items excluded), not raw email bodies. It returns ordered item ids (with source-merge groups) plus the biggest-cut-and-why line — no re-emitted item content. Top 20 max.
- The HTML email is rendered by a template in code, resolving titles, tldrs, and urls from the extracted items; the model emits no HTML. Footnote counts (items, messages, newsletters, dropped) are script-computed, with dropped = skip-banded. Send is gated on schema-valid ranking output instead of the current grep checks.
- Editorial behaviour is unchanged — the existing prompt's rules get redistributed across the extraction and ranking prompts.

### Notes

- Stay on claude -p (Max plan). Extraction on Haiku, ranking on Opus.
- Total runtime must stay inside the existing DAG timeout; chunk size is the lever.
- Out of scope, likely follow-ups: persisting items for cross-week dedup and archive; applying the same restructure to the jobs digest.
