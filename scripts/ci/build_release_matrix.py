#!/usr/bin/env python3
"""Build immutable tag matrix.json, SHA256SUMS.txt, and merged release-matrix.json."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
from typing import Any
from urllib.parse import quote


PLATFORM_ORDER: list[tuple[str, str, str, str]] = [
    ("macos", "macOS", "macOS", "arm64"),
    ("windows", "Windows", "Windows", "x64"),
    ("linux", "Linux", "Linux", "x64"),
    ("android", "Android", "Android", "universal"),
    ("ios", "iOS", "iOS", "arm64"),
]


@dataclass(frozen=True)
class PackageClassification:
    platform: str
    fmt: str
    arch: str
    primary: bool
    audience: str
    order: int


EXACT_CLASSIFICATIONS: dict[str, PackageClassification] = {
    "xconnect.dmg": PackageClassification("macos", "dmg", "arm64", True, "end_user", 10),
    "xconnect-windows-portable.exe": PackageClassification("windows", "exe", "x64", True, "end_user", 5),
    "xconnect-windows.msi": PackageClassification("windows", "msi", "x64", True, "end_user", 10),
    "xconnect-windows.zip": PackageClassification("windows", "zip", "x64", False, "end_user", 20),
    "xconnect-linux-amd64.deb": PackageClassification("linux", "deb", "amd64", True, "end_user", 10),
    "xconnect-linux.AppImage": PackageClassification("linux", "appimage", "x64", False, "end_user", 20),
    "xconnect-linux-x86_64.rpm": PackageClassification("linux", "rpm", "x86_64", False, "end_user", 30),
    "xconnect-linux-x64.tar.gz": PackageClassification("linux", "tar.gz", "x64", False, "end_user", 35),
    "xconnect-linux.zip": PackageClassification("linux", "zip", "x64", False, "end_user", 40),
    "app-release.apk": PackageClassification("android", "apk", "universal", True, "end_user", 10),
    "xconnect.ipa": PackageClassification("ios", "ipa", "arm64", False, "sideload", 10),
}

SNAPSHOT_DMG_RE = re.compile(r"^xconnect-latest-[0-9a-f]+\.dmg$", re.IGNORECASE)


def classify_artifact(name: str) -> PackageClassification | None:
    """Return classification for end-user/sideload artifacts, or None to exclude."""
    if name in EXACT_CLASSIFICATIONS:
        return EXACT_CLASSIFICATIONS[name]
    lower = name.lower()
    if lower.endswith(".aab") or lower == "xconnect.app.zip" or SNAPSHOT_DMG_RE.match(name):
        return None
    if lower.endswith(".dmg"):
        return PackageClassification("macos", "dmg", "arm64", True, "end_user", 15)
    if lower.endswith(".msi"):
        return PackageClassification("windows", "msi", "x64", True, "end_user", 15)
    if lower.endswith(".deb"):
        return PackageClassification("linux", "deb", "amd64", True, "end_user", 15)
    if lower.endswith(".appimage"):
        return PackageClassification("linux", "appimage", "x64", False, "end_user", 25)
    if lower.endswith(".rpm"):
        return PackageClassification("linux", "rpm", "x86_64", False, "end_user", 35)
    if lower.endswith(".apk"):
        return PackageClassification("android", "apk", "universal", True, "end_user", 15)
    if lower.endswith(".ipa"):
        return PackageClassification("ios", "ipa", "arm64", False, "sideload", 15)
    return None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--repo", default="ai-workspace-xstream/xconnect-app")
    parser.add_argument("--product", default="xconnect")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", default="0")
    parser.add_argument("--msi-version", default="")
    parser.add_argument("--channel", required=True)
    parser.add_argument("--commit-sha", default="")
    parser.add_argument("--published-at", default="")
    parser.add_argument("--workflow-run-url", default="")
    parser.add_argument("--existing-matrix", default="")
    parser.add_argument("--cn-synced", default="true")
    parser.add_argument("--global-synced", default="true")
    parser.add_argument("--history-limit", type=int, default=10)
    return parser.parse_args()


def to_bool(raw: str) -> bool:
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def collect_artifacts(artifacts_dir: Path) -> list[Path]:
    found: dict[str, Path] = {}
    for file_path in sorted(p for p in artifacts_dir.rglob("*") if p.is_file()):
        found.setdefault(file_path.name, file_path)
    return [found[name] for name in sorted(found)]


def load_existing_matrix(path_str: str, product: str) -> dict[str, Any]:
    if path_str:
        path = Path(path_str)
        if path.is_file():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                if (
                    isinstance(data, dict)
                    and data.get("schemaVersion") == 1
                    and data.get("product") == product
                    and isinstance(data.get("channels"), dict)
                ):
                    return data
            except json.JSONDecodeError:
                pass
    return {
        "schemaVersion": 1,
        "product": product,
        "defaultChannel": "latest",
        "channels": {"stable": None, "latest": None},
        "history": [],
    }


def build_release_matrix(args: argparse.Namespace) -> dict[str, Any]:
    artifacts_dir = Path(args.artifacts_dir)
    output_dir = Path(args.output_dir)
    prefix = f"/releases/{args.product}/{args.tag}"
    tag_dir = output_dir / "releases" / args.product / args.tag
    channels_dir = output_dir / "releases" / args.product / "channels"
    tag_dir.mkdir(parents=True, exist_ok=True)
    channels_dir.mkdir(parents=True, exist_ok=True)

    published_at = args.published_at.strip() or datetime.now(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    release_url = f"https://github.com/{args.repo}/releases/tag/{quote(args.tag)}"
    download_base = f"https://github.com/{args.repo}/releases/download/{quote(args.tag)}"

    platform_packages: dict[str, list[tuple[int, dict[str, Any]]]] = {
        pid: [] for pid, *_ in PLATFORM_ORDER
    }
    checksum_lines: list[str] = []

    for src in collect_artifacts(artifacts_dir):
        classification = classify_artifact(src.name)
        if classification is None:
            continue
        dest = tag_dir / src.name
        if src.resolve() != dest.resolve():
            shutil.copy2(src, dest)
        digest = sha256_file(dest)
        size = dest.stat().st_size
        checksum_lines.append(f"{digest}  {src.name}")
        pkg = {
            "name": src.name,
            "format": classification.fmt,
            "arch": classification.arch,
            "path": f"{prefix}/{src.name}",
            "size": size,
            "sha256": digest,
            "primary": classification.primary,
            "audience": classification.audience,
            "githubUrl": f"{download_base}/{quote(src.name)}",
        }
        platform_packages[classification.platform].append((classification.order, pkg))

    (tag_dir / "SHA256SUMS.txt").write_text(
        "\n".join(checksum_lines) + ("\n" if checksum_lines else ""),
        encoding="utf-8",
    )

    platforms: list[dict[str, Any]] = []
    for pid, label, label_zh, default_arch in PLATFORM_ORDER:
        entries = [pkg for _, pkg in sorted(platform_packages[pid], key=lambda item: (item[0], item[1]["name"]))]
        platforms.append(
            {
                "id": pid,
                "label": label,
                "labelZh": label_zh,
                "arch": default_arch,
                "supportStatus": "supported" if entries else "unsupported",
                "packages": entries,
            }
        )

    entry: dict[str, Any] = {
        "tag": args.tag,
        "version": args.version,
        "buildNumber": str(args.build_number),
        "msiVersion": args.msi_version or args.version,
        "channel": args.channel,
        "commitSha": args.commit_sha,
        "publishedAt": published_at,
        "releaseUrl": release_url,
        "workflowRunUrl": args.workflow_run_url,
        "mirrors": {
            "cn": {"synced": to_bool(args.cn_synced)},
            "global": {"synced": to_bool(args.global_synced)},
        },
        "platforms": platforms,
    }

    (tag_dir / "matrix.json").write_text(
        json.dumps(entry, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    existing = load_existing_matrix(args.existing_matrix, args.product)
    channels = {
        "stable": existing.get("channels", {}).get("stable"),
        "latest": existing.get("channels", {}).get("latest"),
    }
    if args.channel == "stable":
        channels["stable"] = entry
        (channels_dir / "stable.json").write_text(
            json.dumps(entry, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    elif args.channel == "latest":
        channels["latest"] = entry
        (channels_dir / "latest.json").write_text(
            json.dumps(entry, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )

    history_item = {
        "tag": args.tag,
        "version": args.version,
        "buildNumber": str(args.build_number),
        "channel": args.channel,
        "publishedAt": published_at,
        "matrixPath": f"{prefix}/matrix.json",
    }
    prev_history = [
        item
        for item in (existing.get("history") or [])
        if isinstance(item, dict) and item.get("tag") and item.get("tag") != args.tag
    ]
    merged_history = [history_item, *prev_history][: max(1, args.history_limit)]

    aggregated = {
        "schemaVersion": 1,
        "product": args.product,
        "generatedAt": published_at,
        "defaultChannel": "stable" if channels.get("stable") else "latest",
        "channels": channels,
        "history": merged_history,
    }
    (output_dir / "releases" / args.product / "release-matrix.json").write_text(
        json.dumps(aggregated, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return aggregated


def main() -> None:
    args = parse_args()
    build_release_matrix(args)


if __name__ == "__main__":
    main()
