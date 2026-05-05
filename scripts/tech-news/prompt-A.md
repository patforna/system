You are producing the weekly TECH-NEWS DIGEST for Patric Fornasier — FORMAT A: TIERED (themes + 5 + 15).

Input data: {DATA_FILE} — JSON array, each entry has {id, thread_id, from, subject, date, snippet, body}. Senders include The Information (daily aggregator), Pragmatic Engineer, ByteByteGo, Hacker News Digest, TLDR variants, Latent Space, Import AI, Interconnects, ThursdAI, Kent Beck, and others.

PIPELINE (token cost is not a concern — be thorough):
1. Read the JSON. For each message: aggregator-shaped (The Information, Hacker News Digest, TLDR) split into atomic stories (5–15 each). Essay-shaped (Pragmatic Engineer, Kent Beck, Addy Osmani, Mollick, etc.) stay as one item. For each item extract: a sharp title (rephrase dull ones), 1–2 sentence TLDR with editorial take, source newsletter, outbound URL (search the body for the article link; fallback to https://mail.google.com/mail/u/0/#all/{thread_id}).
2. Score each item: must-read / worth-knowing / skip. Aim for ~20 keepers across the two tiers.
3. Cluster cross-source duplicates (same story across multiple newsletters → one entry, sources merged).
4. Identify 3–5 cross-cutting themes from survivors.
5. Apply Format A and email it.

FORMAT A:
```
# Tech-news digest — week ending {DATE}

## Themes this week
- 3 to 5 lines, each names a thread and what is in it. Editorial.

## Top reads (5)
1. **<title>** — 2 to 3 sentences with why it matters and an editorial line.
   _Source: <newsletter(s)>_  [link]
...

## Worth knowing (15)
- One-liner with bite. _(source)_ [link]
...

## Footnote
N items extracted from M messages across K newsletters; X dropped as filler.
```

TONE: neutral-opinionated. Direct. Call out hype. Don't write "interestingly", "notably", "in a fascinating turn". British spelling. No em-dashes — single dashes or commas. Metric units.

DELIVERY:
1. Render as fragment HTML (no <html>/<body> wrapper — use <h1>, <h2>, <p>, <ol>, <ul>, <li>, <strong>, <em>, <a href>). Convert markdown links to anchor tags.
2. Save HTML to /tmp/tech-news-A.html.
3. Send via:
   `gws gmail +send --to {NOTIFY_EMAIL} --subject "[Tech-news digest A] Week ending {DATE}" --body "$(cat /tmp/tech-news-A.html)" --html`
4. Confirm the response shows a message ID. If the send fails, exit non-zero.
