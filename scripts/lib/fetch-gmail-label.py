#!/usr/bin/env python3
"""Fetch messages with a given Gmail label (last N days) into a JSON file.

Output: array of {id, thread_id, from, subject, date, snippet, body} sorted by date asc.
Body is plaintext (preferred) or HTML stripped to plaintext-ish, truncated at 30k chars.
"""

import argparse, base64, html, json, re, subprocess, sys, time
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime


def parsed_date(msg):
    # RFC-2822 date strings sort alphabetically by weekday name, not in time
    # order — parse to a datetime for the chronological sort the docstring
    # promises. Unparseable/missing dates sort first.
    try:
        dt = parsedate_to_datetime(msg["date"])
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except (KeyError, ValueError, TypeError):
        return datetime.min.replace(tzinfo=timezone.utc)


def gws(args, retries=3, backoff=2.0):
    # gws occasionally returns exit 1 (API error, e.g. 429/5xx) or exit 5
    # (internal) on a single call. One run fans out ~100 sequential gws calls,
    # so retry with backoff — one transient blip mid-fetch shouldn't abort the
    # whole digest.
    for attempt in range(retries + 1):
        try:
            out = subprocess.run(
                ["/opt/homebrew/bin/gws", *args],
                capture_output=True, text=True, check=True,
            )
            return json.loads(out.stdout)
        except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
            if attempt == retries:
                raise
            print(f"gws failed ({e}); retry {attempt + 1}/{retries}",
                  file=sys.stderr)
            time.sleep(backoff * (2 ** attempt))


def list_ids(query):
    ids, page = [], None
    while True:
        params = {"userId": "me", "q": query, "maxResults": 500}
        if page:
            params["pageToken"] = page
        r = gws(["gmail", "users", "messages", "list",
                 "--params", json.dumps(params)])
        ids.extend(m["id"] for m in r.get("messages", []))
        page = r.get("nextPageToken")
        if not page:
            return ids


def fetch(msg_id):
    return gws(["gmail", "users", "messages", "get", "--params",
                json.dumps({"userId": "me", "id": msg_id, "format": "full"})])


def b64d(s):
    s = s.replace("-", "+").replace("_", "/")
    s += "=" * (-len(s) % 4)
    return base64.b64decode(s)


def walk_parts(parts, acc):
    for p in parts or []:
        mt = p.get("mimeType", "")
        data = p.get("body", {}).get("data")
        if data:
            try:
                acc.setdefault(mt, []).append(b64d(data).decode("utf-8", "replace"))
            except Exception:
                pass
        if p.get("parts"):
            walk_parts(p["parts"], acc)


def strip_html(h):
    h = re.sub(r"<style[^>]*>.*?</style>", "", h, flags=re.S | re.I)
    h = re.sub(r"<script[^>]*>.*?</script>", "", h, flags=re.S | re.I)
    h = re.sub(r"<!--.*?-->", "", h, flags=re.S)
    h = re.sub(r'<a [^>]*href="([^"]*)"[^>]*>(.*?)</a>',
               r"[\2](\1)", h, flags=re.S | re.I)
    h = re.sub(r"<br[^>]*>", "\n", h, flags=re.I)
    h = re.sub(r"</(p|div|h[1-6]|li|tr)>", "\n", h, flags=re.I)
    h = re.sub(r"<[^>]+>", "", h)
    h = html.unescape(h)
    h = re.sub(r"[ \t]+", " ", h)
    h = re.sub(r"\n[ \t]*", "\n", h)
    h = re.sub(r"\n{3,}", "\n\n", h)
    return h.strip()


def extract_body(msg):
    acc = {}
    walk_parts([msg["payload"]], acc)
    if "text/plain" in acc:
        return "\n".join(acc["text/plain"])
    if "text/html" in acc:
        return strip_html("\n".join(acc["text/html"]))
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--label", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    ids = list_ids(f"label:{args.label} newer_than:{args.days}d")
    out = []
    skipped = []
    for mid in ids:
        try:
            msg = fetch(mid)
        except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
            # One message exhausting gws retries must not sink the whole
            # digest — skip it and carry on. Missing a few beats missing all.
            print(f"skipping {mid}: fetch failed after retries ({e})",
                  file=sys.stderr)
            skipped.append(mid)
            continue
        headers = {h["name"].lower(): h["value"]
                   for h in msg["payload"].get("headers", [])}
        body = extract_body(msg)
        # Cap only pathological sizes — 30k truncated the densest aggregators
        # mid-list (AINews/The Pulse/The Batch run 34-56k), dropping stories;
        # the full corpus fits the 1M-token context, so 100k is headroom.
        if len(body) > 100_000:
            body = body[:100_000] + "\n…[truncated]"
        out.append({
            "id": msg["id"],
            "thread_id": msg["threadId"],
            "from": headers.get("from", ""),
            "subject": headers.get("subject", ""),
            "date": headers.get("date", ""),
            "snippet": msg.get("snippet", ""),
            "body": body,
        })

    out.sort(key=parsed_date)
    with open(args.output, "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    print(f"wrote {len(out)} messages to {args.output} "
          f"({sum(len(x['body']) for x in out):,} body chars); "
          f"skipped {len(skipped)} after retries", file=sys.stderr)


if __name__ == "__main__":
    main()
