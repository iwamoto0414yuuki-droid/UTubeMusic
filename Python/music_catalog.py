"""Public YouTube Music metadata. No Google login, cookies from users, or paid API."""
import re
import urllib.parse


def thumbnail(value):
    return next((t["url"] for t in reversed(value.get("thumbnails") or [])
                 if str(t.get("url", "")).startswith("https://")), None)


def names(value):
    if isinstance(value, str):
        return value
    return " / ".join(v.get("name", "") for v in (value or []) if isinstance(v, dict))


def item(value):
    browse = value.get("browseId", "") or ""
    ident = browse if browse.startswith("MPRE") else value.get("playlistId") or browse
    if ident.startswith("VL"):
        ident = ident[2:]
    kind = "album" if ident.startswith("MPRE") else "playlist"
    if not re.fullmatch(r"[A-Za-z0-9_-]{5,200}", ident) or (kind == "playlist" and not ident.startswith(("PL", "OLAK", "RD"))):
        return None
    return {"id": ident, "kind": kind, "title": value.get("title") or "タイトル不明",
            "subtitle": names(value.get("artists") or value.get("author")) or ("アルバム" if kind == "album" else "プレイリスト"),
            "thumbnail": thumbnail(value)}


def collection_ref(value):
    if not isinstance(value, str):
        raise ValueError("プレイリストのリンクを確認してください。")
    if "://" in value or "/" in value:
        parsed = urllib.parse.urlparse(value if "://" in value else "https://" + value)
        if parsed.scheme != "https" or parsed.username or parsed.password or parsed.hostname not in ("music.youtube.com", "www.youtube.com", "youtube.com", "m.youtube.com"):
            raise ValueError("YouTubeの公開プレイリスト・アルバムのリンクを入力してください。")
        value = parsed.path.removeprefix("/browse/") if parsed.path.startswith("/browse/") else urllib.parse.parse_qs(parsed.query).get("list", [""])[0]
    if value.startswith("VL"):
        value = value[2:]
    if not re.fullmatch(r"(?:MPRE|PL|OLAK|RD)[A-Za-z0-9_-]{1,196}", value):
        raise ValueError("公開プレイリスト・アルバムのリンクを確認してください。")
    return value


def dispatch(request):
    from ytmusicapi import YTMusic
    import certifi
    import requests
    from functools import partial
    with requests.Session() as session:
        session.trust_env = False
        session.verify = certifi.where()
        session.request = partial(session.request, timeout=20)
        op = request["op"]
        # The pinned parser currently misses filtered search shelves in Japanese.
        # Keep home headings Japanese; English metadata parsing preserves song titles.
        api = YTMusic(requests_session=session, language="ja" if op == "home" else "en", location="JP")
        if op == "home":
            sections = []
            seen = set()
            for index, row in enumerate(api.get_home(limit=6)):
                values = []
                for raw in row.get("contents", []):
                    entry = item(raw)
                    if entry and entry["id"] not in seen:
                        values.append(entry); seen.add(entry["id"])
                if values:
                    sections.append({"id": str(index), "title": row.get("title") or "見つける", "items": values[:20]})
            return {"ok": True, "sections": sections}
        if op == "catalog_search":
            kind = request.get("kind")
            if kind not in ("albums", "playlists"):
                raise ValueError("アルバムかプレイリストを選んでください。")
            offset = int(request.get("offset", 0))
            if not 0 <= offset < 200:
                raise ValueError("検索条件を変えて探してください。")
            values = [v for raw in api.search(str(request.get("query", ""))[:200], filter=kind, limit=offset + 21) if (v := item(raw))]
            return {"ok": True, "items": values[offset:offset + 20], "has_more": len(values) > offset + 20 and offset + 20 < 200, "next_offset": offset + 20}
        if op == "collection":
            ident = collection_ref(request.get("id", ""))
            album = ident.startswith("MPRE")
            data = api.get_album(ident) if album else api.get_playlist(ident, limit=1001)
            tracks = data.get("tracks") or []
            if len(tracks) > 1000 or int(data.get("trackCount") or len(tracks)) > 1000:
                raise ValueError("1000曲を超えるリストです。小さいプレイリストに分けてください。")
            songs, seen = [], set()
            for track in tracks:
                video = track.get("videoId", "") or ""
                if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video) or track.get("isAvailable") is False or video in seen:
                    continue
                seen.add(video)
                songs.append({"id": video, "title": track.get("title") or "タイトル不明",
                              "artist": names(track.get("artists") or data.get("artists")) or "アーティスト不明",
                              "duration": track.get("duration_seconds") or 0, "thumbnail": thumbnail(track) or thumbnail(data)})
            return {"ok": True, "collection": {"id": ident, "kind": "album" if album else "playlist",
                    "title": data.get("title") or "プレイリスト", "subtitle": names(data.get("artists") or data.get("author")),
                    "thumbnail": thumbnail(data)}, "songs": songs, "unavailable": max(0, len(tracks) - len(songs))}
    raise ValueError("未対応の操作です。")
