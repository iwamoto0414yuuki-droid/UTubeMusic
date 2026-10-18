"""Silent generated media solely for the CI simulator screenshot; never bundled."""
from pathlib import Path
import json
import sys
import uuid
import wave

root = Path(sys.argv[1]).resolve()
assert "CoreSimulator" in root.parts and root.parts[-2:] == ("Documents", "UTubeMusic")
root.mkdir(parents=True, exist_ok=True)
audio = root / "preview-silence.wav"
with wave.open(str(audio), "wb") as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(22050)
    output.writeframes(b"\x00\x00" * 22050 * 60)
song = {"id": "local-preview", "title": "UTube Music 再生テスト", "artist": "画面確認用の無音データ",
        "duration": 60, "thumbnail": None, "fileName": audio.name, "artworkName": None,
        "bytes": audio.stat().st_size, "favorite": True, "addedAt": 0}
snapshot = {"version": 1, "songs": [song], "playlists": [{"id": str(uuid.uuid4()), "name": "再生テスト", "songIDs": [song["id"]], "createdAt": 0}]}
(root / "library.json").write_text(json.dumps(snapshot, ensure_ascii=False), encoding="utf-8")
