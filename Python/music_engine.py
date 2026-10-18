"""On-device metadata/search only. Swift transfers and validates the audio.

No account, API key, remote helper, subprocess or FFmpeg is used here.
WebKit challenge support is experimental and must be tested on an actual iPhone.
"""
import json
import re
import urllib.parse

VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")


def video_id(value):
    value = value.strip()
    if VIDEO_ID.fullmatch(value):
        return value
    if "://" not in value:
        value = "https://" + value
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme not in ("https", "http") or parsed.username or parsed.password:
        raise ValueError("YouTubeの曲のリンクを入力してください。")
    host = (parsed.hostname or "").lower()
    if host in ("youtu.be", "www.youtu.be"):
        candidate = parsed.path.strip("/").split("/")[0]
    elif host in ("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"):
        parts = parsed.path.strip("/").split("/")
        candidate = parts[1] if len(parts) > 1 and parts[0] in ("shorts", "live", "embed") else urllib.parse.parse_qs(parsed.query).get("v", [""])[0]
    else:
        raise ValueError("YouTubeの曲のリンクを入力してください。")
    if not VIDEO_ID.fullmatch(candidate):
        raise ValueError("曲単体のリンクを入力してください。プレイリストURLには対応していません。")
    return candidate


def song(info):
    ident = str(info.get("id", ""))
    if not VIDEO_ID.fullmatch(ident):
        raise ValueError("曲のIDを取得できませんでした。")
    thumbnails = info.get("thumbnails") or []
    thumbnail = info.get("thumbnail") or next((x["url"] for x in reversed(thumbnails) if x.get("url")), None)
    return {"id": ident, "title": info.get("track") or info.get("title") or "タイトル不明",
            "artist": info.get("artist") or info.get("uploader") or info.get("channel") or "アーティスト不明",
            "duration": info.get("duration") or 0, "thumbnail": thumbnail}


def select_audio(info):
    """Only directly playable AAC in MP4; don't download video or an Opus file as M4A."""
    if info.get("is_live") or info.get("live_status") in ("is_live", "is_upcoming"):
        raise ValueError("配信中・公開前の曲は保存できません。")
    formats = [f for f in info.get("formats", [])
               if f.get("vcodec") == "none" and f.get("ext") == "m4a"
               and (f.get("acodec") or "").startswith("mp4a")
               and f.get("protocol") == "https" and f.get("url") and not f.get("has_drm")]
    if not formats:
        raise ValueError("iPhoneで保存できるAAC音声が見つかりません。取得元の制限や仕様変更の可能性があります。")
    selected = max(formats, key=lambda f: f.get("abr") or f.get("tbr") or 0)
    url = selected["url"]
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or not (parsed.hostname or "").endswith(".googlevideo.com"):
        raise ValueError("安全な音声の保存先を確認できませんでした。")
    headers = dict(info.get("http_headers") or {})
    headers.update(selected.get("http_headers") or {})
    # No account cookies are collected or forwarded by this app.
    headers = {k: str(v) for k, v in headers.items() if k.lower() in ("user-agent", "referer", "origin", "accept", "accept-language")}
    return {"song": song(info), "url": url, "headers": headers,
            "bytes": selected.get("filesize") or 0, "bitrate": selected.get("abr") or 0}


def dispatch(request_json):
    try:
        request = json.loads(request_json)
        import certifi
        from yt_dlp import YoutubeDL
        options = {"quiet": True, "no_warnings": True, "skip_download": True,
                   "cachedir": False, "noplaylist": True, "socket_timeout": 25,
                   "retries": 1, "extractor_retries": 1, "nocheckcertificate": False,
                   "ca_certs": certifi.where()}
        op = request.get("op")
        if op == "search":
            query = str(request.get("query", "")).strip()[:200]
            if not query:
                return json.dumps({"ok": True, "songs": []})
            try:
                ident = video_id(query)
            except ValueError:
                if "://" in query or "youtube.com/" in query or "youtu.be/" in query:
                    raise ValueError("YouTubeの曲単体のリンクを確認してください。")
                ident = None
            options["extract_flat"] = "in_playlist"
            with YoutubeDL(options) as ydl:
                data = ydl.extract_info("https://www.youtube.com/watch?v=" + ident if ident else "ytsearch20:" + query + " 音楽", download=False)
            entries = data.get("entries", []) if data.get("_type") in ("playlist", "multi_video") else [data]
            songs = []
            for entry in entries:
                if not entry or entry.get("is_live"):
                    continue
                try:
                    songs.append(song(entry))
                except ValueError:
                    continue
            return json.dumps({"ok": True, "songs": songs}, ensure_ascii=False)
        if op == "resolve":
            ident = video_id(str(request.get("id", "")))
            with YoutubeDL(options) as ydl:
                info = ydl.extract_info("https://www.youtube.com/watch?v=" + ident, download=False)
            return json.dumps({"ok": True, **select_audio(info)}, ensure_ascii=False)
        raise ValueError("未対応の操作です。")
    except Exception as exc:
        # Do not expose expiring media URLs, tokens or a Python traceback to the UI.
        message = str(exc) if isinstance(exc, ValueError) else "取得元から曲を読み込めませんでした。通信を確認して再試行してください。取得制限や仕様変更が原因の場合もあります。"
        return json.dumps({"ok": False, "error": message}, ensure_ascii=False)
