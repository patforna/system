#!/usr/bin/env python3
"""Deterministic phases of the tech-news digest pipeline. The wrapper script
(scripts/tech-news-digest.sh) orchestrates; claude only does judgment
(per-chunk extraction, one ranking call). Everything mechanical lives here:
chunking, response validation, link canonicalisation, exact-duplicate merge,
and the HTML render — stdlib only (requests/jinja2 are not installed under
the pinned $PYTHON3).
"""

import argparse
import glob
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

# Params that only identify the click, never the content. utm_* is matched by
# prefix; the rest exactly.
TRACKING_PARAMS = {"ref", "fbclid", "gclid", "mc_cid", "mc_eid"}

# Hosts that wrap the real target behind a redirect. Suffix-matched ESP
# domains plus generic first-label heuristics (link.*, click.*, ...). Kept
# deliberately conservative — "go"/"news"/"email" style labels are real
# content hosts (go.dev) — since a miss only means the wrapped URL survives
# with params stripped, while a false positive costs one harmless GET.
WRAPPER_DOMAINS = ("beehiiv.com", "substack.com", "list-manage.com",
                   "sendgrid.net", "mlsend.com", "tldrnewsletter.com")
WRAPPER_LABELS = {"link", "links", "click", "clicks", "track", "tracking"}


def strip_tracking_params(url):
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https"):
        return url
    kept = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True)
            if not k.lower().startswith("utm_")
            and k.lower() not in TRACKING_PARAMS]
    return urlunsplit(parts._replace(query=urlencode(kept)))


def is_tracking_wrapper(url):
    host = (urlsplit(url).hostname or "").lower()
    if host.split(".")[0] in WRAPPER_LABELS:
        return True
    return any(host == d or host.endswith("." + d) for d in WRAPPER_DOMAINS)


def canonicalise_url(url, resolver):
    """Resolve a tracking-wrapper URL to its target via the injected resolver
    (network in production, fake in tests), then strip tracking params. Any
    resolution failure keeps the wrapped URL, params stripped — a dead
    redirect must never lose the item."""
    if is_tracking_wrapper(url):
        try:
            url = resolver(url)
        except Exception:
            pass
    return strip_tracking_params(url)


# A no-story newsletter runs a few KB; aggregator bodies run 30-100k chars
# and always carry stories — above this, an empty extraction is under-reading.
EMPTY_EXEMPT_MAX_BODY = 10_000


def validate_extraction(output, chunk_ids, body_chars=0):
    """Semantic checks on top of the JSON schema: structured_output present
    (a refusal/schema miss arrives as null), every message_id one of the
    chunk's own, no blank title/tldr. Zero items is under-extraction, not
    judgment — except from a single small-bodied message (a lone no-story
    newsletter), which may legitimately yield nothing. Raises ValueError so
    the orchestrator can retry the chunk."""
    if not isinstance(output, dict) or not isinstance(output.get("items"), list):
        raise ValueError("structured_output missing or malformed")
    if not output["items"] and (len(chunk_ids) > 1
                                or body_chars > EMPTY_EXEMPT_MAX_BODY):
        raise ValueError(f"no items from a {len(chunk_ids)}-message, "
                         f"{body_chars}-char chunk")
    for it in output["items"]:
        if it["message_id"] not in chunk_ids:
            raise ValueError(f"message_id {it['message_id']!r} not in chunk")
        if not it["title"].strip() or not it["tldr"].strip():
            raise ValueError("blank title or tldr")
    return output["items"]


BAND_RANK = {"must-read": 0, "worth-knowing": 1, "skip": 2}

# Total wall-clock allowance for redirect resolution across a run. Dozens of
# slow wrappers at the per-URL timeout would otherwise stack into the DAG
# window; once spent, remaining URLs keep their wrapped form, params stripped
# — the same fallback as a single failed resolution.
RESOLVE_BUDGET = 600


def resolve_links(items, messages, resolver, budget=RESOLVE_BUDGET):
    """Give every item its final URL: canonicalise real links (resolving
    identical wrapped URLs only once, under a total wall-clock budget); items
    with no usable http(s) link get the Gmail deep-link of their source
    message. link_fallback marks the latter so the merge never collapses two
    distinct stories that share a message's deep-link."""
    threads = {m["id"]: m["thread_id"] for m in messages}
    deadline = time.monotonic() + budget
    cache = {}
    unresolved = 0
    out = []
    for it in items:
        it = dict(it)
        url = it["url"].strip()
        if url.startswith(("http://", "https://")):
            if url not in cache:
                if time.monotonic() > deadline:
                    unresolved += is_tracking_wrapper(url)
                    cache[url] = strip_tracking_params(url)
                else:
                    cache[url] = canonicalise_url(url, resolver)
            it["url"] = cache[url]
            it["link_fallback"] = False
        else:
            tid = threads[it["message_id"]]
            it["url"] = f"https://mail.google.com/mail/u/0/#all/{tid}"
            it["link_fallback"] = True
        out.append(it)
    if unresolved:
        print(f"resolve budget ({budget}s) exhausted — {unresolved} wrapper "
              f"URLs kept unresolved, params stripped", file=sys.stderr)
    return out


def merge_items(items):
    """Merge exact duplicates (same canonical URL) into one item, unioning
    sources and message ids and keeping the best band; first-seen title/tldr
    wins. Judgment clustering (same story, different URLs) stays in the
    ranking call. Ids are script-owned and stable within the run."""
    merged, by_url = [], {}
    for it in items:
        g = None if it["link_fallback"] else by_url.get(it["url"])
        if g is None:
            g = {"title": it["title"], "tldr": it["tldr"], "url": it["url"],
                 "band": it["band"], "sources": [it["source"]],
                 "message_ids": [it["message_id"]]}
            merged.append(g)
            if not it["link_fallback"]:
                by_url[it["url"]] = g
            continue
        if it["source"] not in g["sources"]:
            g["sources"].append(it["source"])
        if it["message_id"] not in g["message_ids"]:
            g["message_ids"].append(it["message_id"])
        if BAND_RANK[it["band"]] < BAND_RANK[g["band"]]:
            g["band"] = it["band"]
    for n, g in enumerate(merged, 1):
        g["id"] = f"i{n}"
    return merged


def ranking_input(merged):
    """Compact candidate list for the single ranking call: judgment fields
    only, no bodies, skip-banded items excluded."""
    return [{"id": g["id"], "title": g["title"], "tldr": g["tldr"],
             "source": ", ".join(g["sources"]), "band": g["band"]}
            for g in merged if g["band"] != "skip"]


def validate_ranking(output, valid_ids):
    """Semantic checks on the ranking response: every id must exist among the
    candidates, no id twice, 1-20 non-empty groups. Raises ValueError so the
    orchestrator can retry; final failure aborts the send — this replaces the
    old grep sanity checks."""
    if not isinstance(output, dict) or not isinstance(output.get("ranked"), list):
        raise ValueError("structured_output missing or malformed")
    groups = output["ranked"]
    if not 1 <= len(groups) <= 20:
        raise ValueError(f"{len(groups)} groups (expected 1-20)")
    seen = set()
    for group in groups:
        if not group:
            raise ValueError("empty group")
        for iid in group:
            if iid not in valid_ids:
                raise ValueError(f"unknown item id {iid!r}")
            if iid in seen:
                raise ValueError(f"duplicate item id {iid!r}")
            seen.add(iid)
    return output


def _sender(from_header):
    m = re.search(r"<([^>]+)>", from_header)
    return (m.group(1) if m else from_header).strip().lower()


def compute_counts(items, messages):
    """Footnote figures, script-computed: raw extracted items, skip-banded
    ("dropped as filler"), and distinct senders among messages that actually
    yielded items."""
    yielded = {it["message_id"] for it in items}
    senders = {_sender(m["from"]) for m in messages if m["id"] in yielded}
    return {"items": len(items),
            "dropped": sum(1 for it in items if it["band"] == "skip"),
            "newsletters": len(senders)}


def render_html(merged, ranking, counts, fetched, date):
    """Fragment HTML, same shape the model used to emit: h1, one ol of ranked
    entries, h2 Footnote, p. Each group renders its primary item's content;
    the other members only contribute their source names."""
    esc = lambda s: html.escape(s, quote=False)
    by_id = {g["id"]: g for g in merged}
    lines = [f"<h1>Tech-news digest — week ending {esc(date)}</h1>", "<ol>"]
    for group in ranking["ranked"]:
        primary = by_id[group[0]]
        sources = []
        for g in (by_id[iid] for iid in group):
            sources += [s for s in g["sources"] if s not in sources]
        lines.append(
            f'<li><a href="{html.escape(primary["url"])}">'
            f'<strong>{esc(primary["title"])}</strong></a>'
            f' <em>({esc(", ".join(sources))})</em><br>'
            f'{esc(primary["tldr"])}</li>')
    lines += ["</ol>", "<h2>Footnote</h2>",
              f'<p>{counts["items"]} items extracted from {fetched} messages '
              f'across {counts["newsletters"]} newsletters; '
              f'{counts["dropped"]} dropped as filler. '
              f'{esc(ranking["biggest_cut"])}</p>']
    return "\n".join(lines) + "\n"


def chunk_messages(messages, budget):
    """Split messages into chunks by a body-character budget. Fixed-N chunking
    would produce wildly uneven prompts (aggregator bodies run 30-100k chars,
    essays a few KB); a char budget keeps per-call size predictable. A single
    oversized message still gets its own chunk — never dropped."""
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


# --- CLI (wiring around the functions above; exercised end-to-end, not unit
# --- tested). Validation subcommands exit 1 with the reason on stderr so the
# --- wrapper script can drive its retry loops off the exit code.

def _http_resolver(url, timeout=5):
    """Follow a wrapper's redirect chain and return the final URL. GET, not
    HEAD (many trackers 405 HEAD); the body is never read. Default python UA
    gets blocked by some trackers, hence the explicit one."""
    req = urllib.request.Request(
        url, headers={"User-Agent": "Mozilla/5.0 (compatible; tech-news-digest)"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.url
    except urllib.error.HTTPError as e:
        return e.url  # 4xx/5xx on the TARGET — the redirect chain still resolved


def _load(path):
    with open(path) as f:
        return json.load(f)


def _dump(obj, path):
    with open(path, "w") as f:
        json.dump(obj, f, ensure_ascii=False)


def _structured_output(envelope_path):
    return _load(envelope_path).get("structured_output")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("chunk", help="split fetched messages into chunk files")
    p.add_argument("--input", required=True)
    p.add_argument("--outdir", required=True)
    p.add_argument("--budget", type=int, required=True)

    p = sub.add_parser("extract-validate",
                       help="validate one extraction envelope against its chunk")
    p.add_argument("--chunk", required=True)
    p.add_argument("--envelope", required=True)
    p.add_argument("--output", required=True)

    p = sub.add_parser("merge",
                       help="canonicalise links, merge exact duplicates, count")
    p.add_argument("--items-dir", required=True)
    p.add_argument("--data", required=True)
    p.add_argument("--output", required=True)

    p = sub.add_parser("ranking-input",
                       help="print the compact candidate list for ranking")
    p.add_argument("--merged", required=True)

    p = sub.add_parser("rank-validate",
                       help="validate the ranking envelope against merged items")
    p.add_argument("--merged", required=True)
    p.add_argument("--envelope", required=True)
    p.add_argument("--output", required=True)

    p = sub.add_parser("render", help="render the digest HTML")
    p.add_argument("--merged", required=True)
    p.add_argument("--ranking", required=True)
    p.add_argument("--fetched", type=int, required=True)
    p.add_argument("--date", required=True)
    p.add_argument("--output", required=True)

    args = ap.parse_args()

    if args.cmd == "chunk":
        messages = _load(args.input)
        os.makedirs(args.outdir, exist_ok=True)
        chunks = chunk_messages(messages, args.budget)
        for n, chunk in enumerate(chunks, 1):
            # Only what extraction needs — thread_id/snippet stay out of the
            # prompt (the deep-link fallback reads thread_id from DATA_FILE).
            pruned = [{k: m.get(k, "") for k in
                       ("id", "from", "subject", "date", "body")}
                      for m in chunk]
            _dump(pruned, os.path.join(args.outdir, f"chunk-{n:03d}.json"))
        print(f"chunked {len(messages)} messages into {len(chunks)} chunks",
              file=sys.stderr)

    elif args.cmd == "extract-validate":
        chunk = _load(args.chunk)
        try:
            items = validate_extraction(_structured_output(args.envelope),
                                        {m["id"] for m in chunk},
                                        sum(len(m.get("body", ""))
                                            for m in chunk))
        except (ValueError, KeyError, TypeError, json.JSONDecodeError) as e:
            print(f"invalid extraction for {os.path.basename(args.chunk)}: {e}",
                  file=sys.stderr)
            sys.exit(1)
        _dump(items, args.output)
        print(f"{os.path.basename(args.chunk)}: {len(items)} items",
              file=sys.stderr)

    elif args.cmd == "merge":
        data = _load(args.data)
        items = []
        for path in sorted(glob.glob(os.path.join(args.items_dir, "*.json"))):
            items += _load(path)
        resolved = resolve_links(items, data, _http_resolver)
        merged = merge_items(resolved)
        _dump({"items": merged, "counts": compute_counts(items, data)},
              args.output)
        fallbacks = sum(1 for it in resolved if it["link_fallback"])
        print(f"merged {len(items)} items into {len(merged)} "
              f"({fallbacks} deep-link fallbacks)", file=sys.stderr)

    elif args.cmd == "ranking-input":
        print(json.dumps(ranking_input(_load(args.merged)["items"]),
                         ensure_ascii=False))

    elif args.cmd == "rank-validate":
        merged = _load(args.merged)
        valid = {g["id"] for g in merged["items"] if g["band"] != "skip"}
        try:
            out = validate_ranking(_structured_output(args.envelope), valid)
        except (ValueError, KeyError, TypeError, json.JSONDecodeError) as e:
            print(f"invalid ranking: {e}", file=sys.stderr)
            sys.exit(1)
        _dump(out, args.output)
        print(f"ranking: {len(out['ranked'])} groups", file=sys.stderr)

    elif args.cmd == "render":
        merged = _load(args.merged)
        with open(args.output, "w") as f:
            f.write(render_html(merged["items"], _load(args.ranking),
                                merged["counts"], args.fetched, args.date))


if __name__ == "__main__":
    main()
