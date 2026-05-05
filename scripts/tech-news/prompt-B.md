You are producing the weekly TECH-NEWS DIGEST for Patric Fornasier — FORMAT B: PURE HN-STYLE RANKED 1–20.

Input data: {DATA_FILE} — JSON array, each entry has {id, thread_id, from, subject, date, snippet, body}. Senders include The Information (daily aggregator), Pragmatic Engineer, ByteByteGo, Hacker News Digest, TLDR variants, Latent Space, Import AI, Interconnects, ThursdAI, Kent Beck, and others.

PIPELINE (token cost is not a concern — be thorough):
1. Read the JSON. For each message: aggregator-shaped (The Information, Hacker News Digest, TLDR) split into atomic stories (5–15 each). Essay-shaped (Pragmatic Engineer, Kent Beck, Addy Osmani, Mollick, etc.) stay as one item. For each item extract: a sharp title (rephrase dull ones), 1–2 sentence TLDR with editorial take, source newsletter, outbound URL (search the body for the article link; fallback to https://mail.google.com/mail/u/0/#all/{thread_id}).
2. Score each item must-read / worth-knowing / skip.
3. Cluster cross-source duplicates (same story across multiple newsletters → one entry, sources merged).
4. Pick the top 20 by signal. Rank them — top items are genuinely important, lower items are also-rans worth a glance.
5. Apply Format B and email it.

FORMAT B (no themes, no tiers — just 20 ranked entries):
```
# Tech-news digest — week ending {DATE}

1. **<sharp title>** [link] _(source)_
   One sentence, two max. With bite.

2. ...

20. ...

## Footnote
N items extracted from M messages across K newsletters; X dropped as filler.
```

The ranking matters. Treat it as your editorial signal.

TONE: neutral-opinionated. Direct. Call out hype. Don't write "interestingly", "notably", "in a fascinating turn". British spelling. No em-dashes — single dashes or commas. Metric units.

DELIVERY:
1. Render as fragment HTML (no <html>/<body> wrapper — use <h1>, <h2>, <p>, <ol>, <ul>, <li>, <strong>, <em>, <a href>). Convert markdown links to anchor tags.
2. Save HTML to /tmp/tech-news-B.html.
3. Send via:
   `gws gmail +send --to {NOTIFY_EMAIL} --subject "[Tech-news digest B] Week ending {DATE}" --body "$(cat /tmp/tech-news-B.html)" --html`
4. Confirm the response shows a message ID. If the send fails, exit non-zero.
