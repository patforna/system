---
title: Restructure jobs digest into script-driven phases
date: 2026-07-07
status: ready-for-dev
type: tech
---

## Restructure Jobs Digest into Script-driven Phases

Apply the task-001 pattern to the weekly jobs digest: the script orchestrates, the model only judges. Replace the prompt-orchestrated Haiku subagent fan-out with a scripted per-chunk structured extraction, dedupe and mechanical hard-filters in code, keep candidate validation+scoring as one agentic Opus call (WebFetch allowed) returning structured JSON, and render the three-bucket HTML email and subject line in-script. Removes the fragile bits: prompt-driven subagent orchestration, model-written HTML behind grep gates, self-reported counts.

### Acceptance Criteria

- Fetch (gws `jobs` label via fetch-gmail-label.py, the count==0 guard), scheduling, and send are unchanged.
- Extraction runs per chunk, structured JSON validated against a schema (company, role_title, location, seniority_signal, comp_signal, posting_url, recruiter_url, message_id validated against the chunk, raw_excerpt). One email yields 0, 1, or many roles; clearly non-job emails yield nothing. A chunk still returning invalid JSON after retries is logged and skipped.
- Coverage is computed by the script; the run aborts without sending if more than 10% of fetched messages fail extraction. The existing count==0 guard stays.
- Exact-duplicate roles are merged in code (same posting_url when present, else same company + case/whitespace-normalised role_title), preserving all sources and links.
- Mechanical hard-filters are applied in code where the signal is unambiguous: rejected titles (Senior EM / Engineering Manager / Senior Engineering Manager / Staff EM), stated base comp clearly below the floor. Judgment filters (tech-as-supporting-function, anti-domain when not explicit) stay in the scoring call.
- Scoring is a single agentic Opus call over the merged candidate list: it may WebFetch top candidates to verify title/level/comp/location/still-open, and returns structured JSON per candidate — score 0-10, bucket (vetted/borderline/rejected), a why-it-fits or conflict line, verified fields, and a link_unverified flag. The scoring rubric and the Anthropic +5 boost live in the scoring prompt. The model emits no HTML.
- The three-bucket HTML email (vetted table, borderline table, rejected list), the footnote, and the subject line are rendered by the script from the scoring JSON. Counts (N vetted, M borderline, K rejected, from X messages) are script-computed. Send is gated on schema-valid scoring output instead of the current grep checks.
- Editorial/criteria behaviour is unchanged — the existing prompt's candidate profile, hard filters, scoring rubric, and tone get redistributed across the extraction and scoring prompts.

### Implementation Plan

#### TLDR

Mirror scripts/tech-news/ for jobs: reuse run_claude_json and the pipeline patterns (chunking, coverage gate, exact-dup merge, script render). The one structural difference from task 001 is the scoring stage stays agentic — it may WebFetch — so it needs a tools-enabled structured-output call, not the `--tools ""` one.

#### Steps

1. Probe first (this decides the scoring-stage shape): does `claude -p --json-schema '<schema>'` still return a valid `.structured_output` when tools are enabled and WebFetch is actually used? Tiny opus probe against a real URL. If structured output composes with tool use → one scoring call. If not → two calls: an agentic validation call (tools on, free-text verified-notes per candidate) feeding a structured scoring call (`--tools ""`, json-schema). Record which path in the task notes.
2. Add a tools-enabled sibling to run_claude_json in scripts/lib/dagu-common.sh (or parameterise it) that permits WebFetch while keeping the clean-stdout JSON-envelope contract and the shared timeout/transient-retry. run_claude and run_claude_json stay behaviour-compatible for their existing callers.
3. Reuse the tech-news pipeline mechanics. Factor the genuinely shared, non-secret helpers (body-char chunking, coverage arithmetic, HTML escaping) into a small shared module under scripts/lib/ rather than copy-paste; keep jobs-specific logic (dedup key, hard-filters, three-bucket render, subject) in the jobs pipeline.
4. Extraction: chunk the fetched messages by body-char budget (naturally 1-3 chunks at ~18 msgs), one Haiku call per chunk against the extraction schema, `--tools ""`. Same semantic validation as tech-news (every item's message_id ∈ chunk) and the same retry-then-skip + empty-chunk rejection for multi-message / oversized chunks.
5. Coverage gate before scoring, same 10% rule as tech-news.
6. Script-side merge (exact-dup key above) then mechanical hard-filters (title blocklist, stated-comp-below-floor). Filtered-out roles are retained with a reason so the rejected bucket and footnote counts are script-computed, not inferred.
7. Scoring call per step 1's path. Render the three-bucket HTML, footnote, and subject in-script from the scoring JSON. Send gated on schema-valid scoring output.
8. Split the prompt into extraction and scoring prompts, redistributing the current prompt's rules. Drop the current prompt's PIPELINE section (subagent fan-out, manual dedupe, WebFetch-orchestration prose) — the script owns orchestration now.
9. Wire jobs-digest.sh between the untouched fetch and send sections; drop the `<h2>`/footnote grep gate.

#### Notes

- Placement: the extraction and scoring prompts carry personal criteria (comp floor, geo tiers, Anthropic boost) so they live under private/scripts/jobs-digest/ (git-crypt), like the current prompt. Keep the jobs pipeline module, schemas, and tests together under private/scripts/jobs-digest/ for cohesion — the only cost is code encrypted at rest on GitHub, acceptable for personal tooling. The shared scripts/lib/ helpers stay public.
- The worktree needs the git-crypt key symlinked into its git dir or private/ won't decrypt (see private/GOTCHAS.md, 07-06 entry) — already handled by whoever set up the worktree.
- Do not send email, run msgvault sync, or hit the live mailbox. Verify with fixture JSON (fake recruiter emails) and few/cheap real model calls (haiku extraction probes, at most one opus scoring probe). WebFetch against one real careers URL in a probe is fine.
- Out of scope: the item-archive line and cross-week dedup (deferred to observation first).
