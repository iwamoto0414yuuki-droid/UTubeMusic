import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import types
import sys

spec = importlib.util.spec_from_file_location("catalog", Path(__file__).resolve().parents[1] / "Python/music_catalog.py")
catalog = importlib.util.module_from_spec(spec); spec.loader.exec_module(catalog)


class CatalogTests(unittest.TestCase):
    def test_album_browse_id_wins_over_audio_playlist_id(self):
        value = catalog.item({"browseId": "MPREb_album", "playlistId": "OLAK5uy_audio", "title": "Album", "artists": [{"name": "Artist"}]})
        self.assertEqual(value["kind"], "album"); self.assertEqual(value["id"], "MPREb_album")
        self.assertEqual(catalog.item({"browseId": "VLPL12345", "author": "Creator"})["subtitle"], "Creator")
        self.assertIsNone(catalog.item({"browseId": "UCartist"}))

    def test_collection_links_reject_lookalike_hosts_and_private_library(self):
        self.assertEqual(catalog.collection_ref("https://music.youtube.com/playlist?list=OLAK5uy_test"), "OLAK5uy_test")
        self.assertEqual(catalog.collection_ref("https://music.youtube.com/browse/MPREb_album"), "MPREb_album")
        for value in ["https://music.youtube.com.evil.test/playlist?list=PL123", "https://user:pass@youtube.com/playlist?list=PL123", "http://youtube.com/playlist?list=PL123", "LL", "../secret"]:
            with self.subTest(value=value), self.assertRaises(ValueError): catalog.collection_ref(value)

    def fake(self, tracks=None, count=None):
        class Session:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def request(self, *args, **kwargs): pass
        class API:
            def __init__(self, **kwargs): self.language = kwargs["language"]
            def get_home(self, limit):
                return [{"title": "Public", "contents": [{"browseId": "MPREb_album"}, {"browseId": "UCartist"}, {"browseId": "MPREb_album"}]}]
            def search(self, query, filter, limit):
                if self.language != "en": raise AssertionError("Pinned parser needs English filtered-search metadata")
                return [{"browseId": f"VLPL{i:05d}", "title": "Playlist"} for i in range(min(limit, 45))]
            def get_playlist(self, ident, limit):
                return {"title": "Original", "tracks": tracks or [], "trackCount": count or len(tracks or [])}
        return patch.dict(sys.modules, {"requests": types.SimpleNamespace(Session=Session), "certifi": types.SimpleNamespace(where=lambda: "ca.pem"), "ytmusicapi": types.SimpleNamespace(YTMusic=API)})

    def test_public_home_filters_artists_and_deduplicates(self):
        with self.fake(): result = catalog.dispatch({"op": "home"})
        self.assertEqual(len(result["sections"][0]["items"]), 1)

    def test_collection_search_pages(self):
        with self.fake():
            first = catalog.dispatch({"op": "catalog_search", "kind": "playlists", "query": "mix"})
            second = catalog.dispatch({"op": "catalog_search", "kind": "playlists", "query": "mix", "offset": "20"})
            last = catalog.dispatch({"op": "catalog_search", "kind": "playlists", "query": "mix", "offset": "40"})
        self.assertTrue(first["has_more"]); self.assertTrue(second["has_more"]); self.assertFalse(last["has_more"])
        self.assertEqual(second["items"][0]["id"], "PL00020"); self.assertEqual(len(last["items"]), 5)

    def test_collection_preserves_order_filters_unavailable_and_reports_exclusions(self):
        tracks = [{"videoId": f"{i:011d}", "title": str(i), "artists": [{"name": "Artist"}], "isAvailable": i != 1} for i in range(4)]
        tracks += [tracks[0], {"videoId": None}]
        with self.fake(tracks): result = catalog.dispatch({"op": "collection", "id": "PL12345"})
        self.assertEqual([s["title"] for s in result["songs"]], ["0", "2", "3"])
        self.assertEqual(result["unavailable"], 3)

    def test_oversized_collection_fails_instead_of_silent_partial_save(self):
        with self.fake(count=1001), self.assertRaises(ValueError): catalog.dispatch({"op": "collection", "id": "PL12345"})
