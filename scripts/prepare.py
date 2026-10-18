"""Fetch pinned upstream runtime, install pure Python wheels, create icon. macOS build preparation."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = "https://github.com/beeware/Python-Apple-support/releases/download/3.13-b14/Python-3.13-iOS-support.b14.tar.gz"
SHA256 = "8b5cb76ef8d8a2946052479358eeec9d54b4496cb60920e175ec1489b5cf7963"


def main():
    vendor = ROOT / "vendor"
    vendor.mkdir(exist_ok=True)
    archive = vendor / "Python-3.13-iOS-support.b14.tar.gz"
    if not archive.exists():
        urllib.request.urlretrieve(RUNTIME, archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError("Python runtime hash mismatch; stop without extracting")
    if not (vendor / "Python.xcframework").is_dir():
        with tarfile.open(archive) as tar:
            tar.extractall(vendor, filter="data")
    packages = vendor / "packages"
    if packages.exists():
        shutil.rmtree(packages)  # fixed, project-owned generated dependency directory
    subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "--require-hashes",
                    "--only-binary=:all:", "--no-deps", "--target", str(packages),
                    "-r", str(ROOT / "Python/requirements.lock")], check=True)
    notices = ["UTube Music third-party software notices", "\nPython runtime: Python Software Foundation License; bundled license follows.\n"]
    for path in sorted(vendor.glob("Python.xcframework/lib/python3.13/LICENSE*")):
        notices.append(path.read_text(errors="replace"))
    notices.append((ROOT / "THIRD_PARTY_BASE.txt").read_text(encoding="utf-8"))
    for dist in sorted(packages.glob("*.dist-info")):
        notices.append("\n\n=== " + dist.name + " ===\n")
        for path in sorted(dist.rglob("*")):
            if path.is_file() and any(term in path.name.lower() for term in ("license", "copying", "notice")):
                notices.append(path.read_text(errors="replace"))
    # Runtime distribution includes PSF and bundled OpenSSL/libffi/etc notices; preserve them all.
    for path in sorted(vendor.glob("**/LICENSE*")):
        if "packages" not in path.parts and path.is_file():
            text = path.read_text(errors="replace")
            if text not in notices:
                notices.append("\n=== " + str(path.relative_to(vendor)) + " ===\n" + text)
    (vendor / "ThirdPartyNotices.txt").write_text("\n".join(notices), encoding="utf-8")
    from make_icon import create_icon
    create_icon(ROOT / "Sources/Assets.xcassets/AppIcon.appiconset")
    print("Pinned runtime and pure Python dependencies ready")


if __name__ == "__main__":
    main()
