#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "requests>=2.31",
# ]
# ///
"""Refresh sidestore/apps.json from duo-latest GitHub Releases + IPA Info.plist.

Usage:
  uv run scripts/update_sidestore_source.py
  uv run scripts/update_sidestore_source.py --dry-run

Manual fallback (no script):
  1. Open each duo-latest Release, note the intended IPA name / size / updated date.
  2. Download the IPA, unzip Payload/*.app/Info.plist, read:
       CFBundleIdentifier / CFBundleShortVersionString / CFBundleVersion / MinimumOSVersion
  3. Edit sidestore/apps.json:
       - versions[0].version          = CFBundleShortVersionString
       - versions[0].buildVersion     = CFBundleVersion
       - versions[0].downloadURL      = release asset URL
       - versions[0].size             = asset size (bytes)
       - versions[0].date             = release/asset date (YYYY-MM-DD)
       - versions[0].sha256           = release asset digest (optional but recommended)
       - also mirror version/versionDate/downloadURL/size on the app object (AltStore v1 compat)
  4. Do NOT add Kazumi_ios_canary_no_sign.ipa or mis-uploaded LiveContainer IPAs from venera-duo.
  5. Commit + push to main so the raw sourceURL updates.
"""

from __future__ import annotations

import argparse
import io
import json
import plistlib
import re
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parents[1]
APPS_JSON = ROOT / "sidestore" / "apps.json"

# Only these assets are allowed into the SideStore source.
APPS = [
    {
        "bundleIdentifier": "com.kdt.livecontainer",
        "repo": "matoujin/LiveContainer-duo",
        "asset_name": "LiveContainer+SideStore_duo_ios27.1.ipa",
        "display_name": "LiveContainer+SideStore",
    },
    {
        "bundleIdentifier": "com.example.kazumi.duo",
        "repo": "matoujin/Kazumi-duo",
        "asset_name": "Kazumi_duo_2.4.2_ios27.1.ipa",
        # Filename may change with version; prefer prefix match below.
        "asset_prefix": "Kazumi_duo_",
        "asset_suffix": "_ios27.1.ipa",
        "asset_exclude": ["canary"],
        "display_name": "Kazumi Duo",
    },
    {
        "bundleIdentifier": "com.github.wgh136.venera.duo",
        "repo": "matoujin/venera-duo",
        "asset_name": "venera_duo_1.6.3_ios27.1.ipa",
        "asset_prefix": "venera_duo_",
        "asset_suffix": "_ios27.1.ipa",
        "asset_exclude": ["LiveContainer"],
        "display_name": "Venera Duo",
    },
]


def github_headers() -> dict[str, str]:
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "duo-sidestore-updater"}
    # Optional: GITHUB_TOKEN improves rate limits.
    import os

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def fetch_duo_latest(repo: str) -> dict:
    url = f"https://api.github.com/repos/{repo}/releases/tags/duo-latest"
    r = requests.get(url, headers=github_headers(), timeout=60)
    r.raise_for_status()
    return r.json()


def pick_asset(release: dict, spec: dict) -> dict:
    assets = release.get("assets") or []
    exact = next((a for a in assets if a.get("name") == spec.get("asset_name")), None)
    if exact:
        return exact

    prefix = spec.get("asset_prefix")
    suffix = spec.get("asset_suffix", "")
    exclude = [x.lower() for x in spec.get("asset_exclude", [])]
    if prefix:
        candidates = []
        for a in assets:
            name = a.get("name") or ""
            low = name.lower()
            if not name.startswith(prefix) or not name.endswith(suffix):
                continue
            if any(x in low for x in exclude):
                continue
            candidates.append(a)
        if len(candidates) == 1:
            return candidates[0]
        if candidates:
            # Prefer newest updated_at
            candidates.sort(key=lambda a: a.get("updated_at") or "", reverse=True)
            return candidates[0]

    names = [a.get("name") for a in assets]
    raise RuntimeError(f"No allowed IPA asset in {spec['repo']}: wanted {spec.get('asset_name')}, have {names}")


def digest_sha256(asset: dict) -> str | None:
    digest = asset.get("digest") or ""
    if digest.startswith("sha256:"):
        return digest.split(":", 1)[1]
    return None


def read_ipa_info(download_url: str) -> dict:
    with requests.get(download_url, headers=github_headers(), stream=True, timeout=300) as r:
        r.raise_for_status()
        data = r.content
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        plist_names = [
            n
            for n in zf.namelist()
            if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)
        ]
        if not plist_names:
            raise RuntimeError(f"Info.plist not found in IPA: {download_url}")
        with zf.open(plist_names[0]) as f:
            return plistlib.load(f)


def iso_date(value: str | None) -> str:
    if not value:
        return datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return value[:10]


def update_app_entry(app: dict, *, plist: dict, asset: dict, release: dict) -> None:
    version = str(plist.get("CFBundleShortVersionString") or "")
    build = str(plist.get("CFBundleVersion") or "")
    min_os = str(plist.get("MinimumOSVersion") or "16.1")
    bundle_id = str(plist.get("CFBundleIdentifier") or "")
    if bundle_id and app.get("bundleIdentifier") and bundle_id != app["bundleIdentifier"]:
        raise RuntimeError(
            f"bundleIdentifier mismatch for {app.get('name')}: "
            f"source={app['bundleIdentifier']} ipa={bundle_id}"
        )

    download_url = asset["browser_download_url"]
    size = int(asset["size"])
    date = iso_date(asset.get("updated_at") or release.get("published_at"))
    sha = digest_sha256(asset)
    desc = f"duo-latest：{app.get('name')} iPhone Duo / iOS 27.1 免签包。"

    version_entry = {
        "version": version,
        "buildVersion": build,
        "date": date,
        "localizedDescription": desc,
        "downloadURL": download_url,
        "size": size,
        "minOSVersion": min_os,
    }
    if sha:
        version_entry["sha256"] = sha

    app["versions"] = [version_entry]
    # AltStore / SideStore v1 compatibility fields
    app["version"] = version
    app["versionDate"] = date
    app["versionDescription"] = desc
    app["downloadURL"] = download_url
    app["size"] = size


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json-path", type=Path, default=APPS_JSON)
    args = parser.parse_args()

    data = json.loads(args.json_path.read_text(encoding="utf-8"))
    by_id = {a["bundleIdentifier"]: a for a in data["apps"]}

    for spec in APPS:
        app = by_id.get(spec["bundleIdentifier"])
        if not app:
            raise RuntimeError(f"Missing app entry for {spec['bundleIdentifier']} in {args.json_path}")
        release = fetch_duo_latest(spec["repo"])
        asset = pick_asset(release, spec)
        print(f"Fetching IPA metadata: {asset['name']} ({asset['size']} bytes) from {spec['repo']}")
        plist = read_ipa_info(asset["browser_download_url"])
        update_app_entry(app, plist=plist, asset=asset, release=release)
        print(
            f"  -> {app['name']}: {app['version']} "
            f"({plist.get('CFBundleIdentifier')}) size={app['size']}"
        )

    text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    if args.dry_run:
        print(text)
        return 0

    args.json_path.write_text(text, encoding="utf-8")
    print(f"Updated {args.json_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
