#!/usr/bin/env python3
"""Fetch the pinned Temml release (MIT; LaTeX -> MathML) into build/vendor/temml for bundling.

The npm tarball is checked against the sha512 integrity the npm registry publishes for that exact
version before anything is extracted. Only three files are kept: temml.min.js, LICENSE and
Temml-Local.css. Nothing is executed. The result is ignored by git (build/ is in .gitignore).
Usage: python3 scripts/fetch_temml.py [--offline-check]
"""
import base64, hashlib, io, json, pathlib, shutil, subprocess, sys, tarfile, tempfile

VERSION = "0.13.2"
REGISTRY = "https://registry.npmjs.org/temml/" + VERSION
ROOT = pathlib.Path(__file__).resolve().parents[1]
DEST = ROOT / "build" / "vendor" / "temml"
WANTED = {  # destination name -> candidate paths inside the package, first match wins
    "temml.min.js": ["package/dist/temml.min.js", "package/dist/temml.js", "package/dist/temml.cjs"],
    "LICENSE": ["package/LICENSE", "package/LICENSE.md", "package/LICENSE.txt"],
    "Temml-Local.css": ["package/dist/Temml-Local.css"],
}
OPTIONAL = {"Temml-Local.css"}


def curl(url: str) -> bytes:
    # macOS curl uses the system trust store; HTTPS only, no redirects to other protocols.
    out = subprocess.run(["/usr/bin/curl", "-fsSL", "--proto", "=https", "--proto-redir", "=https", "--max-time", "90", url],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if out.returncode:
        raise SystemExit(f"Download failed ({out.returncode}): {url}\n{out.stderr.decode(errors='replace').strip()}")
    return out.stdout


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def current() -> bool:
    record = DEST / "SOURCE.json"
    if not record.exists():
        return False
    try:
        data = json.loads(record.read_text())
        return data.get("version") == VERSION and all(
            (DEST / name).exists() and sha256(DEST / name) == digest for name, digest in data.get("files", {}).items()
        ) and "temml.min.js" in data.get("files", {})
    except (OSError, ValueError):
        return False


def main() -> None:
    if current():
        print(f"Temml {VERSION} already present and unchanged: {DEST}")
        return
    if "--offline-check" in sys.argv:
        raise SystemExit("Temml is missing or changed; run without --offline-check to fetch it.")
    meta = json.loads(curl(REGISTRY))
    dist = meta.get("dist") or {}
    tarball, integrity = dist.get("tarball", ""), dist.get("integrity", "")
    if meta.get("version") != VERSION or not tarball.startswith("https://registry.npmjs.org/temml/-/") or not integrity.startswith("sha512-"):
        raise SystemExit("Unexpected registry metadata; not downloading.")
    data = curl(tarball)
    digest = "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode()
    if digest != integrity:
        raise SystemExit("Checksum mismatch for the Temml tarball; nothing extracted.")
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        members = {m.name: m for m in archive.getmembers() if m.isfile()}
        staged = pathlib.Path(tempfile.mkdtemp(prefix="temml-"))
        for name, candidates in WANTED.items():
            member = next((members[c] for c in candidates if c in members), None)
            if member is None:
                if name in OPTIONAL:
                    continue
                raise SystemExit(f"{name} not found in the Temml package.")
            # Read by member, write to a fixed name: archive paths are never used as destinations.
            (staged / name).write_bytes(archive.extractfile(member).read())
            files[name] = sha256(staged / name)
    js = (staged / "temml.min.js").read_text(encoding="utf-8")
    if "renderToString" not in js or len(js) < 50_000:
        raise SystemExit("Temml script does not look like the expected library.")
    DEST.mkdir(parents=True, exist_ok=True)
    for name in files:
        shutil.copyfile(staged / name, DEST / name)
    shutil.rmtree(staged)
    (DEST / "SOURCE.json").write_text(json.dumps(
        {"package": "temml", "version": VERSION, "license": "MIT", "tarball": tarball, "integrity": integrity, "files": files}, indent=1))
    print(f"Fetched Temml {VERSION} ({integrity[:23]}…) into {DEST}")


if __name__ == "__main__":
    main()
