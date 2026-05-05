You are producing the weekly JOBS DIGEST for Patric Fornasier.

Input data: {DATA_FILE} — JSON array of last 7 days of mail under the `jobs` label, each entry has {id, thread_id, from, subject, date, snippet, body}. Senders include direct recruiters, hiring managers, LinkedIn InMail forwards, and job-board newsletters.

CANDIDATE PROFILE — Patric is filtering for:
- **Role shape (preferred)**: Principal / Distinguished / Staff+ IC, Founding Engineer, ≤10-person CTO, small Head-of-X (Eng/Platform/AI). Open to larger Head-of / VP / Dir / CTO seats but those are deprioritised — judge on org-design drag and people-mgmt overhead.
- **Comp**: floor CHF 250k base. No upper limit.
- **Domain test**: "Tech is the product, not a supporting function." Anti-pattern is brand/CPG/retail companies where engineering is plumbing for marketing.
- **Anti-domains (HARD reject)**: defence/weapons, gambling/betting.
- **Geo tiers**:
  1. Zurich in-person (top tier)
  2. London in-person + frequent travel (acceptable)
  3. Anthropic anywhere — would relocate to UK (special flag — surface prominently)
  4. Remote worldwide (acceptable)
  5. Anything else (deprioritise)
- **Deprioritised titles**: "Senior EM" / "Engineering Manager" / "Senior Engineering Manager" — too low for current career stage.
- **Timing**: 6-12 month horizon, quality over speed. Bias toward fewer high-quality fits over volume.

PIPELINE:

1. **Parallel extraction (Haiku subagents)**. Read the JSON. Split the messages into chunks of ~10. For each chunk, spawn a Haiku subagent via the Task tool with subagent_type="general-purpose" and model="haiku". Brief each subagent: extract role candidates from each email — for each role return JSON `{message_id, company, role_title, location (city/remote), seniority_signal, comp_signal_if_stated, posting_url_if_present, recruiter_contact_url_if_present, raw_excerpt}`. Skip emails that are clearly not job-related (e.g. newsletters with no role, generic networking). One email may yield 0, 1, or many roles. Return JSON array. Subagents run in parallel — fire them in a single message with multiple Task calls.

2. **Dedupe**. Same role contacted via multiple emails / recruiters → merge into one entry, preserve all sources and links.

3. **Hard filter** — auto-reject:
   - defence/weapons, gambling/betting domains
   - stated base comp clearly <CHF 250k
   - "Senior EM" / "Engineering Manager" / "Senior Engineering Manager" / "Staff EM" titles
   - clear "tech as supporting function" companies (brand/CPG/retail/hospitality where engineering is not the product)
   - obvious noise (job-board mass-blast, "we're hiring" newsletters with no specific role for him)

4. **WebFetch validation** — for the top ~15 candidates that survived hard filters and look like decent matches, WebFetch the posting URL (or company careers page if posting URL absent). Pull: confirmed title/level, location, comp range if listed, key responsibilities, "people management?" signal, team size, recency (still open?). If WebFetch fails or 404s, keep the candidate but mark `link_unverified`.

5. **Score** each surviving candidate on a 0-10 fit scale:
   - +3 for role-shape match (IC / founding eng / small CTO)
   - +2 for domain match (AI-native, modern fintech, dev tools, AI infra, deep-tech where tech is product)
   - +2 for geo tier 1-3
   - +1 for low people-mgmt drag signal
   - +1 for high-agency / low-bureaucracy culture signals (small org, technical leadership, no slide-deck culture mentions)
   - +1 for prestige / quality signal (named AI lab, top fintech, well-known for engineering excellence)
   - **+5 BOOST if Anthropic** (auto-surface to top regardless of other dimensions)
   - -2 for any borderline anti-domain signal not already auto-rejected
   - -2 for "tech as supporting function" company smell

6. **Sort** into three buckets:
   - **Vetted shortlist** (score ≥7) — strong matches
   - **Borderline** (score 4-6) — mixed signals, judge yourself
   - **Rejected** (score <4 OR hard-rejected) — one-line reason each

FORMAT (HTML email):

```
<h1>Jobs digest — week ending {DATE}</h1>
<p><em>N vetted · M borderline · K rejected · from X messages</em></p>

<h2>Vetted shortlist</h2>
<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse">
  <tr><th>Company</th><th>Role</th><th>Location</th><th>Comp</th><th>Score</th><th>Why it fits</th><th>Link</th></tr>
  <tr>...one per candidate, sorted by score desc...</tr>
</table>

<h2>Borderline</h2>
<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse">
  <tr><th>Company</th><th>Role</th><th>Location</th><th>Score</th><th>Conflict / question</th><th>Link</th></tr>
</table>

<h2>Rejected</h2>
<ul>
  <li><strong>Company — Role:</strong> reason (one line)</li>
  ...
</ul>

<h2>Footnote</h2>
<p>Extracted N roles from M messages. K rejected: A defence/gambling, B sub-floor comp, C wrong title, D tech-as-supporting-function, E noise.</p>
```

TONE: direct, terse, opinionated. British spelling. No em-dashes — single dashes or commas. Metric units. Don't write "exciting opportunity", "great fit", or recruiter-speak. Editorial-line "Why it fits" should call out the *specific* signal that makes this a fit (e.g. "Founding eng seat at AI-infra Series A, Zurich office, no direct reports").

DELIVERY:

1. Render as fragment HTML (no `<html>`/`<body>` wrapper).
2. Save HTML to /tmp/jobs-digest.html.
3. Send via:
   `gws gmail +send --to {NOTIFY_EMAIL} --subject "[Jobs digest] Week ending {DATE} — N vetted, M borderline, K rejected" --body "$(cat /tmp/jobs-digest.html)" --html`
   (substitute N/M/K with actual counts in the subject)
4. Confirm the response shows a message ID. If the send fails, exit non-zero.
