---
title: Restructure tech-news digest into script-driven phases
date: 2026-07-06
status: done
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

## Implementation Plan

### TLDR

Replace the single Opus render call in tech-news-digest.sh with a script-owned pipeline: chunked Haiku extraction (schema-bound JSON), coverage gate, link canonicalisation + exact-URL merge in code, one Opus ranking call over compact item ids, and a code-rendered HTML template. Fetch (through the count<30 guard), the dagu DAG, and the gws send stay untouched.

### Steps

1. Add a structured-output invocation function to scripts/lib/dagu-common.sh alongside run_claude (which stays untouched — jobs-digest, tad-daily-code-review, and dagu-autofix depend on its current contract). It takes a model and a JSON schema, reuses the existing _run_with_timeout cap and transient-retry policy, and prints the claude JSON envelope on a clean stdout (stderr kept separate — the retry grep must key on exit code/stderr, never a 2>&1 merge, or it corrupts the JSON). Verified mechanics: `claude -p "<prompt>" --model <id> --output-format json --json-schema '<inline-json>' --tools "" </dev/null`; the positional prompt MUST precede the variadic --tools/--allowedTools flags (they swallow a following positional); parse .structured_output from stdout; a refusal/schema-miss exits 0 with structured_output == null — that null check, not the exit code, is the validity signal.
2. Split the fetched DATA_FILE array into chunks by a body-character budget (aggregator bodies run 30-100k chars, essays a few KB — fixed-N chunking would produce wildly uneven prompts), each chunk carrying its messages' ids. Sequential calls, no parallelism (each claude process is heavy; bounded runtime and readable dagu logs win).
3. Extraction: one Haiku (claude-haiku-4-5-20251001) call per chunk against the extraction schema. Script-side semantic validation on top of the schema: every item's message id must be one of the chunk's ids. On invalid response (structured_output null, bad ids): retry up to 2 times, then mark the chunk failed and continue. Sponsored/advertorial content is never emitted — not as skip, not counted anywhere.
4. Coverage gate, before any network or ranking work: messages in failed chunks count as unextracted; abort without sending if unextracted/fetched > 10%.
5. Canonicalise item URLs in code (stdlib urllib only — requests is not installed under the pinned $PYTHON3): follow redirects on tracking wrappers (beehiiv, substack, mailchimp, etc.) with a short per-URL timeout; strip utm_*, ref, fbclid, gclid, mc_cid, mc_eid params. Resolution failure → keep wrapped URL, params stripped. No URL at all → Gmail deep-link https://mail.google.com/mail/u/0/#all/{thread_id}, resolved by the script from the item's source message (the msgvault fetcher sets thread_id = Gmail message id).
6. Merge exact duplicates (same canonical URL) in code, unioning sources and message ids; assign each merged item a stable script-owned id. Canonicalise strictly before merging or wrapper variants of the same target won't collapse. Judgment clustering stays in ranking.
7. Ranking: one Opus (claude-opus-4-8) call over the non-skip merged items — {id, title, tldr, source, band} only, no bodies. Output schema: ranked = ordered array of ≤20 groups (each an array of item ids, primary first; length >1 = same story across newsletters) + biggest_cut string. Validate all ids exist, no duplicates. Same 2-retry loop; on final failure abort without sending — this replaces the grep sanity checks.
8. Render the HTML in code (python stdlib string building — no jinja2 available): resolve each group's primary id to title/tldr/canonical URL, join group sources for the (source) label, escape &, <, >; same structure as today (h1, one ol, h2 Footnote, p). Footnote counts script-computed: items = all extracted items, messages = fetched count, newsletters = distinct from-senders among messages that yielded items, dropped = skip-banded count. Drop the coverage HTML marker — coverage now lives in the script's logs.
9. Split scripts/tech-news/prompt.md into an extraction prompt (reader profile, aggregator-vs-essay splitting, sponsored exclusion, sharp titles, 1-2 sentence tldr with take, banding, tone) and a ranking prompt (cross-newsletter clustering, stale-retrospective demotion, source-prior tie-breaks, top-20 ordering, biggest-cut line — must handle "nothing notable cut" without inventing one; compact tone rules). Both prompts forbid tool/web use; the URL-unwrapping and deep-link-fallback instructions disappear (script's job now).
10. Wire it into tech-news-digest.sh between the untouched fetch and send sections, replacing the render step, the grep gates, and the soft coverage block with the phases above.

### Notes

- Two distinct retry layers — don't conflate: the transient/timeout retry inside the invocation function (API blips, hangs) vs the orchestrator's 2 retries on semantically invalid responses (schema-null, bad ids).
- Runtime math: retries compound across dozens of calls and the whole run must fit the DAG's 5400s timeout; a smaller process-local CLAUDE_TIMEOUT for extraction calls (env export in this script only) plus the chunk budget are the levers.
- Live-verified during planning: the --json-schema/--tools ""/structured_output mechanics incl. the flag-order gotcha (probe: haiku, 4s, clean stderr); requests and jinja2 both absent under /usr/bin/python3.
- Per private/GOTCHAS.md convention this counts as unproven until the first clean scheduled Saturday 03:10 run.

## Implementation notes

- Deviations from the plan, all small:
  - Gmail deep-link fallback URLs are excluded from the exact-duplicate merge key — two linkless stories extracted from the same message share a deep-link and would otherwise wrongly collapse into one item.
  - run_claude_json drops `--permission-mode bypassPermissions` (tool-less call, nothing to permit; matches the live-verified probe shape).
  - The ranking phase also lowers CLAUDE_TIMEOUT (900s) — the plan only called out extraction, but ranking is a far smaller job than the old whole-corpus render the 1500s default was sized for.
  - Ranking prompt gained one guard the fixture run exposed: biggest_cut must name stories, never item ids (opus wrote "i2 and i6" into the printed footnote).
- Verification, no email sent and no live-mailbox access:
  - 40 stdlib unit tests, `scripts/tech-news/test_pipeline.py` (pure logic only; redirect resolver injected as a fake). First tests in this repo — run via `cd scripts/tech-news && /usr/bin/python3 -m unittest test_pipeline`.
  - Live probes: haiku structured-output round-trip through run_claude_json (also confirmed nested arrays with maxItems/minItems are accepted by --json-schema); real redirect resolution via httpbin.
  - Full end-to-end run of tech-news-digest.sh against a stub msgvault (32 fixture messages → 3 chunks at a 1500-char budget) and a stub gws: real haiku ×3 + opus ×1, exit 0. Confirmed sponsored exclusion, skip banding, utm/ref stripping, cross-chunk exact-URL merge (8→7 items), dead-wrapper fallback (params stripped), Gmail deep-link fallback, opus judgment-clustering (grouped the same story from two newsletters), script-computed footnote counts, and the stubbed send receiving the rendered fragment.
- Surprise worth knowing: for no-story filler newsletters the model emits nothing rather than skip items, so the footnote's "newsletters" figure counts only sources that yielded items — consistent with the old footnote's meaning.
- Runtime observed: haiku calls 30-71s each on tiny chunks (mostly fixed session overhead), opus ranking 42s on 6 candidates. A real week at the 80k default budget is ~18 chunks ⇒ roughly 20-60 min, inside the 5400s DAG window; TECH_NEWS_CHUNK_BUDGET is the tuning lever (must stay well under ARG_MAX — chunks travel inline in the prompt argument since the calls are tool-less).
- The first real Saturday 03:10 run both proves this restructure and discharges the open msgvault watch item (the "fetched via msgvault" check).
