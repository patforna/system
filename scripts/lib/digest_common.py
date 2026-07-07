#!/usr/bin/env python3
"""Helpers shared by the digest pipelines (tech-news and jobs). Only the
genuinely identical, non-secret mechanics live here — body-char chunking and
HTML escaping — so both pipelines stay in step without copy-drift. Pipeline
logic that differs (dedup keys, filters, render shape) stays in each pipeline.
Stdlib only (the pinned $PYTHON3 has no requests/jinja2).
"""

import html


def chunk_messages(messages, budget):
    """Split messages into chunks by a body-character budget. Fixed-N chunking
    would produce wildly uneven prompts (aggregator bodies run 30-100k chars,
    a lone recruiter email a few hundred); a char budget keeps per-call size
    predictable. A single oversized message still gets its own chunk — never
    dropped."""
    chunks, cur, cur_size = [], [], 0
    for m in messages:
        size = len(m.get("body", ""))
        if cur and cur_size + size > budget:
            chunks.append(cur)
            cur, cur_size = [], 0
        cur.append(m)
        cur_size += size
    if cur:
        chunks.append(cur)
    return chunks


def esc(s, quote=False):
    """HTML-escape body text (quote=False) or an attribute value like a URL
    (quote=True, which also escapes quotes)."""
    return html.escape(s, quote=quote)
