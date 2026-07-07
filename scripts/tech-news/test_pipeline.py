#!/usr/bin/env python3
"""Unit tests for the tech-news digest pipeline (pure logic only — no I/O,
no network: the redirect resolver is injected as a fake).

Run: cd scripts/tech-news && /usr/bin/python3 -m unittest test_pipeline -v
"""

import contextlib
import io
import time
import unittest

import pipeline


def msg(mid, body="x", **kw):
    m = {"id": mid, "thread_id": mid, "from": f"N <{mid}@n.io>",
         "subject": "s", "date": "2026-07-01T00:00:00Z", "body": body}
    m.update(kw)
    return m


class ChunkMessagesTest(unittest.TestCase):
    def test_empty_input_yields_no_chunks(self):
        self.assertEqual(pipeline.chunk_messages([], budget=100), [])

    def test_single_message_yields_one_chunk(self):
        m = msg("m1")
        self.assertEqual(pipeline.chunk_messages([m], budget=100), [[m]])

    def test_splits_when_budget_exceeded(self):
        a, b = msg("m1", body="a" * 60), msg("m2", body="b" * 60)
        self.assertEqual(pipeline.chunk_messages([a, b], budget=100),
                         [[a], [b]])

    def test_packs_messages_within_budget_preserving_order(self):
        a, b, c = msg("m1", "a" * 40), msg("m2", "b" * 40), msg("m3", "c" * 40)
        self.assertEqual(pipeline.chunk_messages([a, b, c], budget=100),
                         [[a, b], [c]])

    def test_oversized_message_gets_own_chunk(self):
        a = msg("m1", body="a" * 500)
        b = msg("m2", body="b")
        self.assertEqual(pipeline.chunk_messages([a, b], budget=100),
                         [[a], [b]])


class StripTrackingParamsTest(unittest.TestCase):
    def test_url_without_params_unchanged(self):
        self.assertEqual(pipeline.strip_tracking_params("https://a.io/x"),
                         "https://a.io/x")

    def test_strips_utm_params(self):
        self.assertEqual(
            pipeline.strip_tracking_params(
                "https://a.io/x?utm_source=nl&utm_medium=email"),
            "https://a.io/x")

    def test_strips_ref_and_click_ids_keeps_real_params(self):
        self.assertEqual(
            pipeline.strip_tracking_params(
                "https://a.io/x?id=7&ref=hn&fbclid=1&gclid=2&mc_cid=3&mc_eid=4"),
            "https://a.io/x?id=7")

    def test_non_http_url_unchanged(self):
        self.assertEqual(pipeline.strip_tracking_params("mailto:a@b.c"),
                         "mailto:a@b.c")


class CanonicaliseUrlTest(unittest.TestCase):
    def test_wrapper_host_is_resolved_then_stripped(self):
        resolved = pipeline.canonicalise_url(
            "https://link.mail.beehiiv.com/ss/c/abc",
            resolver=lambda u: "https://real.io/story?utm_source=beehiiv")
        self.assertEqual(resolved, "https://real.io/story")

    def test_non_wrapper_host_is_not_resolved(self):
        def boom(url):
            raise AssertionError("resolver must not be called")
        self.assertEqual(
            pipeline.canonicalise_url("https://real.io/story?utm_source=x",
                                      resolver=boom),
            "https://real.io/story")

    def test_failed_resolution_keeps_wrapped_url_params_stripped(self):
        def fail(url):
            raise OSError("timeout")
        self.assertEqual(
            pipeline.canonicalise_url(
                "https://tracking.tldrnewsletter.com/CL0/x?utm_source=tldr",
                resolver=fail),
            "https://tracking.tldrnewsletter.com/CL0/x")

    def test_known_wrapper_domains_detected(self):
        for host in ["link.mail.beehiiv.com", "substack.com",
                     "us1.list-manage.com", "u123.ct.sendgrid.net",
                     "clicks.mlsend.com", "click.convertkit-mail2.com",
                     "tracking.tldrnewsletter.com", "links.example.com",
                     "click.example.com", "track.example.com"]:
            self.assertTrue(pipeline.is_tracking_wrapper(f"https://{host}/x"),
                            host)

    def test_content_hosts_not_flagged_as_wrappers(self):
        for host in ["go.dev", "github.com", "example.substack.io",
                     "linkedin.com", "news.ycombinator.com"]:
            self.assertFalse(pipeline.is_tracking_wrapper(f"https://{host}/x"),
                             host)


def item(mid="m1", title="T", tldr="D", source="S", url="https://a.io/x",
         band="worth-knowing"):
    return {"title": title, "tldr": tldr, "source": source, "url": url,
            "band": band, "message_id": mid}


class ValidateExtractionTest(unittest.TestCase):
    def test_null_output_is_invalid(self):
        with self.assertRaises(ValueError):
            pipeline.validate_extraction(None, {"m1"})

    def test_unknown_message_id_is_invalid(self):
        with self.assertRaises(ValueError):
            pipeline.validate_extraction({"items": [item(mid="m9")]}, {"m1"})

    def test_blank_title_or_tldr_is_invalid(self):
        for bad in [item(title=" "), item(tldr="")]:
            with self.assertRaises(ValueError):
                pipeline.validate_extraction({"items": [bad]}, {"m1"})

    def test_valid_items_returned(self):
        items = [item(), item(mid="m2", band="skip")]
        self.assertEqual(
            pipeline.validate_extraction({"items": items}, {"m1", "m2"}),
            items)

    def test_empty_items_from_small_single_message_chunk_is_valid(self):
        # A lone no-story/sponsored-only newsletter legitimately yields nothing.
        self.assertEqual(
            pipeline.validate_extraction({"items": []}, {"m1"},
                                         body_chars=4_000),
            [])

    def test_empty_items_from_oversized_single_message_chunk_is_invalid(self):
        # An aggregator-sized body always carries stories.
        with self.assertRaises(ValueError):
            pipeline.validate_extraction({"items": []}, {"m1"},
                                         body_chars=50_000)

    def test_empty_items_from_multi_message_chunk_is_invalid(self):
        # Several messages yielding zero items is under-extraction, not judgment.
        with self.assertRaises(ValueError):
            pipeline.validate_extraction({"items": []}, {"m1", "m2"})


class ResolveLinksTest(unittest.TestCase):
    def test_plain_url_gets_params_stripped_no_fallback(self):
        out = pipeline.resolve_links([item(url="https://a.io/x?utm_source=n")],
                                     [msg("m1")], resolver=None)
        self.assertEqual(out[0]["url"], "https://a.io/x")
        self.assertFalse(out[0]["link_fallback"])

    def test_missing_url_falls_back_to_gmail_deep_link(self):
        out = pipeline.resolve_links([item(url="")],
                                     [msg("m1", thread_id="t42")],
                                     resolver=None)
        self.assertEqual(out[0]["url"],
                         "https://mail.google.com/mail/u/0/#all/t42")
        self.assertTrue(out[0]["link_fallback"])

    def test_relative_or_non_http_url_falls_back(self):
        for bad in ["/x/y", "mailto:a@b.c", "read more"]:
            out = pipeline.resolve_links([item(url=bad)], [msg("m1")],
                                         resolver=None)
            self.assertTrue(out[0]["link_fallback"], bad)

    def test_wrapper_resolved_once_per_unique_url(self):
        calls = []

        def resolver(url):
            calls.append(url)
            return "https://real.io/story"

        wrapped = "https://link.mail.beehiiv.com/ss/c/abc"
        out = pipeline.resolve_links(
            [item(url=wrapped), item(mid="m2", url=wrapped)],
            [msg("m1"), msg("m2")], resolver=resolver)
        self.assertEqual([o["url"] for o in out],
                         ["https://real.io/story"] * 2)
        self.assertEqual(calls, [wrapped])

    def test_exhausted_budget_falls_back_to_stripped_wrapped_urls(self):
        calls = []

        def slow_resolver(url):
            calls.append(url)
            time.sleep(0.05)
            return "https://real.io/story"

        items = [item(url="https://link.a.io/1"),
                 item(mid="m2", url="https://link.b.io/2?utm_source=n"),
                 item(mid="m3", url="https://link.c.io/3")]
        messages = [msg("m1"), msg("m2"), msg("m3")]
        with contextlib.redirect_stderr(io.StringIO()) as err:
            out = pipeline.resolve_links(items, messages,
                                         resolver=slow_resolver, budget=0.01)
        # First URL resolves (budget not yet spent); the rest fall back to
        # the wrapped URL with params stripped, without calling the resolver.
        self.assertEqual(calls, ["https://link.a.io/1"])
        self.assertEqual([o["url"] for o in out],
                         ["https://real.io/story", "https://link.b.io/2",
                          "https://link.c.io/3"])
        self.assertFalse(any(o["link_fallback"] for o in out))
        self.assertIn("2 wrapper URLs kept unresolved", err.getvalue())


class MergeItemsTest(unittest.TestCase):
    def resolved(self, mid="m1", url="https://a.io/x", fallback=False, **kw):
        it = item(mid=mid, url=url, **kw)
        it["link_fallback"] = fallback
        return it

    def test_same_canonical_url_merged_sources_and_ids_unioned(self):
        merged = pipeline.merge_items([
            self.resolved(source="TLDR", band="worth-knowing"),
            self.resolved(mid="m2", source="AINews", band="must-read"),
        ])
        self.assertEqual(len(merged), 1)
        g = merged[0]
        self.assertEqual(g["sources"], ["TLDR", "AINews"])
        self.assertEqual(g["message_ids"], ["m1", "m2"])
        self.assertEqual(g["band"], "must-read")  # best band wins
        self.assertEqual(g["title"], "T")  # first-seen content kept

    def test_duplicate_source_names_not_repeated(self):
        merged = pipeline.merge_items([
            self.resolved(source="TLDR"),
            self.resolved(mid="m2", source="TLDR"),
        ])
        self.assertEqual(merged[0]["sources"], ["TLDR"])

    def test_fallback_links_never_merge(self):
        url = "https://mail.google.com/mail/u/0/#all/t1"
        merged = pipeline.merge_items([
            self.resolved(url=url, fallback=True),
            self.resolved(url=url, fallback=True),
        ])
        self.assertEqual(len(merged), 2)

    def test_distinct_urls_stay_distinct_with_stable_ids(self):
        merged = pipeline.merge_items([
            self.resolved(url="https://a.io/1"),
            self.resolved(mid="m2", url="https://a.io/2"),
        ])
        self.assertEqual([g["id"] for g in merged], ["i1", "i2"])


def merged_item(iid, band="worth-knowing", sources=("S",), title="T",
                tldr="D", url="https://a.io/x", message_ids=("m1",)):
    return {"id": iid, "title": title, "tldr": tldr, "url": url,
            "band": band, "sources": list(sources),
            "message_ids": list(message_ids)}


class RankingInputTest(unittest.TestCase):
    def test_skip_banded_items_excluded(self):
        out = pipeline.ranking_input([merged_item("i1"),
                                      merged_item("i2", band="skip")])
        self.assertEqual([c["id"] for c in out], ["i1"])

    def test_compact_fields_only_sources_joined(self):
        out = pipeline.ranking_input(
            [merged_item("i1", sources=["TLDR", "AINews"])])
        self.assertEqual(out, [{"id": "i1", "title": "T", "tldr": "D",
                                "source": "TLDR, AINews",
                                "band": "worth-knowing"}])


class ValidateRankingTest(unittest.TestCase):
    def valid_ids(self):
        return {"i1", "i2", "i3"}

    def test_null_output_is_invalid(self):
        with self.assertRaises(ValueError):
            pipeline.validate_ranking(None, self.valid_ids())

    def test_unknown_id_is_invalid(self):
        with self.assertRaises(ValueError):
            pipeline.validate_ranking(
                {"ranked": [["i9"]], "biggest_cut": "c"}, self.valid_ids())

    def test_duplicate_id_across_groups_is_invalid(self):
        with self.assertRaises(ValueError):
            pipeline.validate_ranking(
                {"ranked": [["i1", "i2"], ["i2"]], "biggest_cut": "c"},
                self.valid_ids())

    def test_empty_ranking_is_invalid(self):
        with self.assertRaises(ValueError):
            pipeline.validate_ranking({"ranked": [], "biggest_cut": "c"},
                                      self.valid_ids())

    def test_more_than_20_groups_is_invalid(self):
        ids = {f"i{n}" for n in range(1, 22)}
        groups = [[f"i{n}"] for n in range(1, 22)]
        with self.assertRaises(ValueError):
            pipeline.validate_ranking({"ranked": groups, "biggest_cut": "c"},
                                      ids)

    def test_valid_output_returned(self):
        out = {"ranked": [["i2", "i3"], ["i1"]], "biggest_cut": "c"}
        self.assertEqual(pipeline.validate_ranking(out, self.valid_ids()),
                         out)


class ComputeCountsTest(unittest.TestCase):
    def test_counts_items_dropped_and_distinct_newsletters(self):
        messages = [
            msg("m1", **{"from": "TLDR <a@tldr.io>"}),
            msg("m2", **{"from": "TLDR AI <a@tldr.io>"}),   # same sender email
            msg("m3", **{"from": "Kent <kb@beck.io>"}),
            msg("m4", **{"from": "Quiet <q@q.io>"}),        # yielded nothing
        ]
        items = [item(mid="m1"), item(mid="m2"), item(mid="m2", band="skip"),
                 item(mid="m3")]
        self.assertEqual(pipeline.compute_counts(items, messages),
                         {"items": 4, "dropped": 1, "newsletters": 2})


class RenderHtmlTest(unittest.TestCase):
    def test_renders_ranked_list_and_footnote(self):
        merged = [
            merged_item("i1", title="Big <Story>", tldr="Take & why.",
                        url="https://a.io/x?a=1&b=2", sources=["TLDR"]),
            merged_item("i2", title="Other", sources=["AINews"]),
        ]
        ranking = {"ranked": [["i1", "i2"]], "biggest_cut": "Nothing cut."}
        counts = {"items": 5, "dropped": 2, "newsletters": 3}
        html = pipeline.render_html(merged, ranking, counts, fetched=100,
                                    date="2026-07-04")
        self.assertIn("<h1>Tech-news digest — week ending 2026-07-04</h1>",
                      html)
        self.assertIn('<a href="https://a.io/x?a=1&amp;b=2">'
                      "<strong>Big &lt;Story&gt;</strong></a>", html)
        self.assertIn("Take &amp; why.", html)
        # Group of two: sources unioned, secondary item's content not emitted.
        self.assertIn("<em>(TLDR, AINews)</em>", html)
        self.assertNotIn("Other", html)
        self.assertIn("<h2>Footnote</h2>", html)
        self.assertIn("<p>5 items extracted from 100 messages across "
                      "3 newsletters; 2 dropped as filler. Nothing cut.</p>",
                      html)
        self.assertEqual(html.count("<li>"), 1)


if __name__ == "__main__":
    unittest.main()
