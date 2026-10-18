"""Validate the actual pinned archive and exercise embedding on Windows.

This packages vendor modules in a disposable fixture; it does not compile Swift,
run iOS binaries or create an installable IPA.
"""
from pathlib import Path
import hashlib
import importlib.util
import os
import shutil
import tarfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    work = ROOT / ("build/runtime-layout-check-" + uuid.uuid4().hex[:8])
    source_root = work / "project"
    vendor = source_root / "vendor"
    vendor.mkdir(parents=True)
    archive = ROOT / "vendor/Python-3.13-iOS-support.b14.tar.gz"
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == "8b5cb76ef8d8a2946052479358eeec9d54b4496cb60920e175ec1489b5cf7963"
    with tarfile.open(archive) as tar:
        members = [m for m in tar.getmembers() if m.name == "Python.xcframework/Info.plist"
                   or m.name.startswith("Python.xcframework/lib/")
                   or m.name.startswith("Python.xcframework/ios-arm64/lib-arm64/")]
        tar.extractall(vendor, members=members, filter="data")
    shutil.copytree(ROOT / "vendor/packages", vendor / "packages")
    shutil.copytree(ROOT / "Python", source_root / "Python")
    (vendor / "ThirdPartyNotices.txt").write_text("Fixture only; not a distribution")
    app_parent = work / "products"
    app_parent.mkdir()
    os.environ.update(PROJECT_DIR=str(source_root.resolve()), TARGET_BUILD_DIR=str(app_parent.resolve()), WRAPPER_NAME="UTubeMusic.fixture.app", CURRENT_ARCH="arm64")
    os.environ.pop("EFFECTIVE_PLATFORM_NAME", None)
    spec = importlib.util.spec_from_file_location("embed_python", ROOT / "scripts/embed_python.py")
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    module.main()
    app = app_parent / "UTubeMusic.fixture.app"
    assert (app / "python/lib/python3.13/encodings/__init__.py").is_file()
    markers = list(app.rglob("*.fwork"))
    assert len(markers) >= 40
    assert not list(app.rglob("*.so"))
    assert not list(app.rglob("libpython*.dylib"))
    for marker in markers:
        binary = app / marker.read_text().strip()
        assert binary.is_file(), marker
        origin = binary.with_name(binary.name + ".origin")
        assert origin.read_text().strip() == str(marker.relative_to(app)).replace("\\", "/")
    assert (app / "app/yt_dlp/__init__.py").is_file()
    assert (app / "app/yt_dlp_plugins/extractor/ytjsc.py").is_file()
    print(f"Pinned archive SHA256 and {len(markers)} native module layouts: OK. No native code was executed.")


if __name__ == "__main__": main()
