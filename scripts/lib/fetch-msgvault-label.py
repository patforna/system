#!/usr/bin/env python3
"""Fetch messages with a given label (last N days) from the local msgvault
archive into a JSON file — same output shape as fetch-gmail-label.py, so the
digest prompts are unchanged.

Why this exists: the gws path makes ~100 sequential `gws gmail messages get`
API calls per run and intermittently exits 5 under that load (see
private/GOTCHAS.md). msgvault is a local SQLite mirror of the same mailbox, so
the per-message reads are local — the entire exit-5 surface is gone.

Freshness: a best-effort incremental `msgvault sync` runs first (one bulk
History-API pull, NOT the ~100 per-message gets that trip exit-5) so the digest
reads current mail even if the daily sync DAG hasn't run or finished. The sync
is non-fatal — on error/timeout it reads the existing archive (a sub-day lag is
fine for a 7-day digest). Pass --no-sync to skip it.

Output: array of {id, thread_id, from, subject, date, snippet, body} sorted by
date asc. Body is msgvault's plaintext (body_text), or HTML stripped to
plaintext-ish when only body_html exists, truncated at 100k chars.

The caller (tech-news-digest.sh) falls back to fetch-gmail-label.py if this
returns too few messages, so a stale/empty archive never loses a digest.
"""

import argparse, json, os, re, shutil, subprocess, sys
from datetime import datetime, timezone

# msgvault is a standalone binary in ~/.local/bin (not Homebrew). dagu's base
# env puts that on PATH; resolve robustly for both cron and interactive runs.
MSGVAULT = (os.environ.get("MSGVAULT") or shutil.which("msgvault")
            or os.path.expanduser("~/.local/bin/msgvault"))


def sync_archive(timeout=300):
    # Best-effort incremental refresh before reading, so the digest sees current
    # mail even if the daily sync DAG hasn't run/finished. One bulk History-API
    # pull (same mechanism as the daily job), NOT the per-message gets that
    # cause gws exit-5. Never fatal: on error/timeout we read the existing
    # archive. No-arg `sync` matches dagu/msgvault-sync.yaml.
    try:
        r = subprocess.run([MSGVAULT, "sync"], capture_output=True,
                           text=True, timeout=timeout)
        tail = next((l for l in reversed((r.stdout + r.stderr).splitlines())
                     if l.strip()), "")
        status = "ok" if r.returncode == 0 else f"rc={r.returncode}"
        print(f"msgvault sync: {status} — {tail}".rstrip(" —"), file=sys.stderr)
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f"msgvault sync skipped ({e}); using existing archive",
              file=sys.stderr)


def mv(args):
    # msgvault prints a "Using keyring backend: keyring" banner and/or a
    # "Searching..." progress prefix before the JSON — slice from the first
    # bracket/brace rather than try to strip every preamble variant.
    out = subprocess.run([MSGVAULT, *args, "--json"],
                         capture_output=True, text=True, check=True).stdout
    start = min((i for i in (out.find("["), out.find("{")) if i != -1),
                default=-1)
    if start == -1:
        raise ValueError(f"no JSON in msgvault output for {args}")
    return json.loads(out[start:])


def parsed_date(iso):
    # msgvault sent_at is ISO-8601 Z; parse for the chronological sort.
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except (ValueError, TypeError, AttributeError):
        return datetime.min.replace(tzinfo=timezone.utc)


def strip_html(h):
    h = re.sub(r"<style[^>]*>.*?</style>", "", h, flags=re.S | re.I)
    h = re.sub(r"<script[^>]*>.*?</script>", "", h, flags=re.S | re.I)
    h = re.sub(r"<!--.*?-->", "", h, flags=re.S)
    h = re.sub(r'<a [^>]*href="([^"]*)"[^>]*>(.*?)</a>',
               r"[\2](\1)", h, flags=re.S | re.I)
    h = re.sub(r"<br[^>]*>", "\n", h, flags=re.I)
    h = re.sub(r"</(p|div|h[1-6]|li|tr)>", "\n", h, flags=re.I)
    h = re.sub(r"<[^>]+>", "", h)
    import html as _html
    h = _html.unescape(h)
    h = re.sub(r"[ \t]+", " ", h)
    h = re.sub(r"\n[ \t]*", "\n", h)
    h = re.sub(r"\n{3,}", "\n\n", h)
    return h.strip()


def header_from(msg):
    # msgvault `from` is [{email, name}] — render to the raw-header form the
    # gws fetcher emits ("Name <email>") so sender matching is identical.
    f = (msg.get("from") or [{}])[0]
    name, email = f.get("name", ""), f.get("email", "")
    return f"{name} <{email}>".strip() if name else email


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--label", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--no-sync", action="store_true",
                    help="skip the pre-fetch msgvault sync (use existing archive)")
    # See fetch-gmail-label.py: a digest's own output carries the label it
    # reads, so without this each run re-ingests its previous email. Filtered
    # here rather than in the search query — msgvault's negation syntax is not
    # guaranteed to match Gmail's.
    ap.add_argument("--exclude-subject", action="append", default=[],
                    help="skip messages whose subject contains this "
                         "(case-insensitive); repeatable")
    args = ap.parse_args()

    if not args.no_sync:
        sync_archive()

    hits = mv(["search", f"label:{args.label} newer_than:{args.days}d",
               "-n", "500"])
    out, skipped = [], 0
    for h in hits:
        mid = h.get("id")
        try:
            msg = mv(["show-message", str(mid)])
        except (subprocess.CalledProcessError, ValueError,
                json.JSONDecodeError) as e:
            print(f"skipping {mid}: {e}", file=sys.stderr)
            skipped += 1
            continue
        subject = msg.get("subject", "")
        if any(x.lower() in subject.lower() for x in args.exclude_subject):
            print(f"skipping {mid}: excluded subject {subject!r}",
                  file=sys.stderr)
            continue
        body = (msg.get("body_text") or "").strip()
        if not body and msg.get("body_html"):
            body = strip_html(msg["body_html"])
        # Cap only pathological sizes. 30k truncated the densest aggregators
        # (AINews, The Pulse, The Batch — 34-56k) mid-list, dropping stories
        # from high-signal sources; with a 1M-token context window the whole
        # uncapped corpus (~350k tokens) fits easily, so 100k is pure headroom.
        if len(body) > 100_000:
            body = body[:100_000] + "\n…[truncated]"
        gmail_id = msg.get("source_message_id") or str(mid)
        out.append({
            "id": gmail_id,
            # msgvault has no Gmail threadId; the Gmail message id deep-links
            # the message, which is all the prompt's fallback URL needs.
            "thread_id": gmail_id,
            "from": header_from(msg),
            "subject": msg.get("subject", ""),
            "date": msg.get("sent_at", ""),
            "snippet": msg.get("snippet", ""),
            "body": body,
        })

    out.sort(key=lambda x: parsed_date(x["date"]))
    with open(args.output, "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    print(f"wrote {len(out)} messages to {args.output} "
          f"({sum(len(x['body']) for x in out):,} body chars) from msgvault; "
          f"skipped {skipped}", file=sys.stderr)


if __name__ == "__main__":
    main()
