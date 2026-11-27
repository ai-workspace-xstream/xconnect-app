#!/usr/bin/env python3
"""Unit tests for build_release_matrix.py and update_readme_downloads.py."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import build_release_matrix  # noqa: E402
import update_readme_downloads  # noqa: E402


class BuildReleaseMatrixTests(unittest.TestCase):
    SAMPLE_FILES = (
        "xconnect.dmg",
        "xconnect-macos-x64.dmg",
        "xconnect-latest-33947f3.dmg",
        "xconnect-windows.msi",
        "xconnect-windows.zip",
        "xconnect-linux-amd64.deb",
        "xconnect-linux-x86_64.rpm",
        "xconnect-linux.AppImage",
        "xconnect-linux.zip",
        "app-release.apk",
        "app-release.aab",
        "xconnect.ipa",
        "xconnect.app.zip",
    )

    def _create_sample_artifacts(self, root: Path) -> None:
        for index, name in enumerate(self.SAMPLE_FILES, start=1):
            sub = root / f"job-{index % 5}"
            sub.mkdir(parents=True, exist_ok=True)
            (sub / name).write_bytes(f"payload-{name}-{index}".encode("utf-8"))

    def test_classifies_12_artifacts_excludes_internal_and_merges_channels(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            artifacts = tmp_path / "artifacts"
            out_dir = tmp_path / "out"
            self._create_sample_artifacts(artifacts)

            # 1. Publish stable v1.1.8
            subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).parent / "build_release_matrix.py"),
                    "--artifacts-dir",
                    str(artifacts),
                    "--output-dir",
                    str(out_dir),
                    "--tag",
                    "v1.1.8",
                    "--version",
                    "1.1.1",
                    "--build-number",
                    "8",
                    "--msi-version",
                    "1.1.8",
                    "--channel",
                    "stable",
                    "--commit-sha",
                    "aaaa111",
                    "--published-at",
                    "2026-11-20T00:00:00Z",
                ],
                check=True,
            )

            matrix_path = out_dir / "releases/xconnect/release-matrix.json"
            stable_doc = json.loads(matrix_path.read_text(encoding="utf-8"))
            self.assertEqual(stable_doc["defaultChannel"], "stable")
            self.assertEqual(stable_doc["channels"]["stable"]["tag"], "v1.1.8")
            self.assertIsNone(stable_doc["channels"]["latest"])

            tag_dir = out_dir / "releases/xconnect/v1.1.8"
            staged_names = {p.name for p in tag_dir.iterdir() if p.is_file()}
            self.assertNotIn("app-release.aab", staged_names)
            self.assertNotIn("xconnect.app.zip", staged_names)
            self.assertNotIn("xconnect-latest-33947f3.dmg", staged_names)
            self.assertIn("SHA256SUMS.txt", staged_names)
            self.assertIn("matrix.json", staged_names)

            # Verify SHA256SUMS matches staged dmg
            expected_dmg_sha = hashlib.sha256((tag_dir / "xconnect.dmg").read_bytes()).hexdigest()
            sums = (tag_dir / "SHA256SUMS.txt").read_text(encoding="utf-8")
            self.assertIn(f"{expected_dmg_sha}  xconnect.dmg", sums)

            # Verify platform package classifications
            platforms = {p["id"]: p for p in stable_doc["channels"]["stable"]["platforms"]}
            self.assertEqual(
                [pkg["name"] for pkg in platforms["macos"]["packages"]],
                ["xconnect.dmg", "xconnect-macos-x64.dmg"],
            )
            self.assertEqual(
                [pkg["arch"] for pkg in platforms["macos"]["packages"]],
                ["arm64", "x64"],
            )
            self.assertEqual([pkg["name"] for pkg in platforms["windows"]["packages"]], ["xconnect-windows.msi", "xconnect-windows.zip"])
            self.assertEqual(len(platforms["linux"]["packages"]), 4)
            self.assertEqual(platforms["ios"]["packages"][0]["audience"], "sideload")
            self.assertEqual([pkg["name"] for pkg in platforms["android"]["packages"]], ["app-release.apk"])

            # 2. Publish latest on top of existing matrix -> must preserve channels.stable
            existing_copy = tmp_path / "existing.json"
            existing_copy.write_text(matrix_path.read_text(encoding="utf-8"), encoding="utf-8")
            subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).parent / "build_release_matrix.py"),
                    "--artifacts-dir",
                    str(artifacts),
                    "--output-dir",
                    str(out_dir),
                    "--tag",
                    "latest-999-33947f3",
                    "--version",
                    "1.1.1",
                    "--build-number",
                    "8",
                    "--msi-version",
                    "1.1.8",
                    "--channel",
                    "latest",
                    "--commit-sha",
                    "33947f3",
                    "--published-at",
                    "2026-11-23T08:00:00Z",
                    "--existing-matrix",
                    str(existing_copy),
                    "--history-limit",
                    "2",
                ],
                check=True,
            )

            merged = json.loads(matrix_path.read_text(encoding="utf-8"))
            self.assertEqual(merged["defaultChannel"], "stable")
            self.assertEqual(merged["channels"]["stable"]["tag"], "v1.1.8")
            self.assertEqual(merged["channels"]["latest"]["tag"], "latest-999-33947f3")
            self.assertEqual([h["tag"] for h in merged["history"]], ["latest-999-33947f3", "v1.1.8"])

            # 3. Verify update_readme_downloads.py consumes --matrix-json cleanly
            tag_matrix = json.loads((out_dir / "releases/xconnect/latest-999-33947f3/matrix.json").read_text(encoding="utf-8"))
            assets = update_readme_downloads.build_asset_map_from_matrix(
                tag_matrix, "ai-workspace-xstream/xconnect-app", "latest-999-33947f3"
            )
            table = update_readme_downloads.build_table(
                "ai-workspace-xstream/xconnect-app", "latest-999-33947f3", assets
            )
            self.assertIn("xconnect-windows.msi", table)
            self.assertIn("xconnect-linux-amd64.deb", table)
            self.assertIn("app-release.apk", table)
            self.assertIn("xconnect.ipa", table)
            self.assertIn("| macOS | x64 |", table)
            self.assertIn("xconnect-macos-x64.dmg", table)


if __name__ == "__main__":
    unittest.main()
