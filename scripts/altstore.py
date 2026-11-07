#!/usr/bin/env python3
"""
Writes the AltStore sources (altstore.json for stable releases,
altstore-nightly.json for the nightly) from the repository's GitHub releases,
read as `gh api --paginate repos/OWNER/REPO/releases` prints them on stdin.

    gh api --paginate repos/OWNER/REPO/releases | scripts/altstore.py OWNER/REPO OUTDIR
"""

import json
import re
import sys
from pathlib import Path

BUNDLE_ID = "io.github.aiostreamstv.app"
MIN_OS = "18.0"
ASSET = re.compile(r"^AIOStreamsTV-(\d+\.\d+\.\d+)-(\d+)\.ipa$")


def releases(text: str) -> list:
    # --paginate prints one JSON array per page, back to back.
    found, decoder, at = [], json.JSONDecoder(), 0
    text = text.strip()
    while at < len(text):
        page, at = decoder.raw_decode(text, at)
        found.extend(page)
        while at < len(text) and text[at].isspace():
            at += 1
    return found


def version_of(release: dict):
    for asset in release.get("assets", []):
        match = ASSET.match(asset["name"])
        if match:
            return {
                "version": match.group(1),
                "buildVersion": match.group(2),
                "date": release.get("published_at") or release.get("created_at"),
                "localizedDescription": release.get("name") or release["tag_name"],
                "downloadURL": asset["browser_download_url"],
                "size": asset["size"],
                "minOSVersion": MIN_OS,
            }
    return None


def source(repo: str, name: str, identifier: str, subtitle: str, versions: list) -> dict:
    raw = f"https://raw.githubusercontent.com/{repo}"
    app = {
        "name": "AIOStreams TV",
        "bundleIdentifier": BUNDLE_ID,
        "developerName": repo.split("/")[0],
        "subtitle": subtitle,
        "localizedDescription": (
            "AIOStreams on Apple TV: the AIOStreams web app, with AetherEngine, mpv "
            "and VLC playing the video. Asks for your AIOStreams server's address "
            "on first launch. Unsigned; for personal use."
        ),
        "iconURL": f"{raw}/main/docs/icon.png",
        "tintColor": "#7C5CFF",
        "category": "entertainment",
        "screenshots": [],
        "appPermissions": {"entitlements": [], "privacy": {}},
        "versions": versions,
    }
    if versions:
        # Older stores (AltStore 1.x, SideStore, most TV loaders) read these.
        newest = versions[0]
        app.update(
            version=newest["version"],
            versionDate=newest["date"],
            versionDescription=newest["localizedDescription"],
            downloadURL=newest["downloadURL"],
            size=newest["size"],
        )
    return {
        "name": name,
        "identifier": identifier,
        "subtitle": subtitle,
        "website": f"https://github.com/{repo}",
        "iconURL": f"{raw}/main/docs/icon.png",
        "tintColor": "#7C5CFF",
        "apps": [app],
        "news": [],
    }


def main() -> None:
    repo, out = sys.argv[1], Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    every = releases(sys.stdin.read())

    stable = [
        r for r in every
        if not r.get("draft") and not r.get("prerelease") and r["tag_name"].startswith("v")
    ]
    stable.sort(key=lambda r: r.get("published_at") or "", reverse=True)
    stable_versions = [v for v in map(version_of, stable) if v]

    nightly = [r for r in every if r["tag_name"] == "nightly" and not r.get("draft")]
    nightly_versions = [v for v in map(version_of, nightly) if v]

    files = {
        "altstore.json": source(repo, "AIOStreams TV", "io.github.aiostreamstv.source",
                                "Stable releases", stable_versions),
        "altstore-nightly.json": source(repo, "AIOStreams TV Nightly", "io.github.aiostreamstv.source.nightly",
                                        "Every change, as it's made", nightly_versions),
    }
    for name, content in files.items():
        (out / name).write_text(json.dumps(content, indent=2) + "\n")
        print(f"{name}: {len(content['apps'][0]['versions'])} version(s)")


if __name__ == "__main__":
    main()
