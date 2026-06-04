#!/usr/bin/env python3
"""Download the latest Windows MSIX release and install its app/ payload."""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import shutil
import sys
import tempfile
import time
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any


DEFAULT_CONFIG = {
    "github_repo": "Wangnov/codex-app-mirror",
    "asset_patterns": ["OpenAI.Codex_*_x64__*.Msix", "*.msix"],
    "target_app_dir": "%USERPROFILE%\\Documents\\Codex-Windows-x64\\app",
    "download_dir": "%TEMP%\\codex-app-mirror-installer",
    "backup_existing": True,
    "keep_download": True,
    "github_token_env": "GITHUB_TOKEN",
}


@dataclass(frozen=True)
class Config:
    github_repo: str
    asset_patterns: list[str]
    target_app_dir: Path
    download_dir: Path
    backup_existing: bool
    keep_download: bool
    github_token_env: str


def expand_path(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value))).resolve()


def load_config(path: Path) -> Config:
    raw = DEFAULT_CONFIG.copy()
    if path.exists():
        with path.open("r", encoding="utf-8") as handle:
            loaded = json.load(handle)
        if not isinstance(loaded, dict):
            raise ValueError(f"Config must be a JSON object: {path}")
        raw.update(loaded)

    patterns = raw["asset_patterns"]
    if not isinstance(patterns, list) or not all(isinstance(item, str) for item in patterns):
        raise ValueError("asset_patterns must be a list of strings")

    return Config(
        github_repo=str(raw["github_repo"]),
        asset_patterns=patterns,
        target_app_dir=expand_path(str(raw["target_app_dir"])),
        download_dir=expand_path(str(raw["download_dir"])),
        backup_existing=bool(raw["backup_existing"]),
        keep_download=bool(raw["keep_download"]),
        github_token_env=str(raw["github_token_env"]),
    )


def build_request(url: str, token_env: str) -> urllib.request.Request:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "codex-app-mirror-local-installer",
    }
    token = os.environ.get(token_env)
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.Request(url, headers=headers)


def fetch_json(url: str, token_env: str) -> dict[str, Any]:
    with urllib.request.urlopen(build_request(url, token_env), timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def latest_release(config: Config) -> dict[str, Any]:
    url = f"https://api.github.com/repos/{config.github_repo}/releases/latest"
    release = fetch_json(url, config.github_token_env)
    if "assets" not in release or not isinstance(release["assets"], list):
        raise ValueError("Latest release response does not contain an assets list")
    return release


def select_msix_asset(assets: list[dict[str, Any]], patterns: list[str]) -> dict[str, Any]:
    for pattern in patterns:
        for asset in assets:
            name = str(asset.get("name", ""))
            if name.lower().endswith(".msix") and fnmatch.fnmatchcase(name, pattern):
                return asset
    raise ValueError(f"No MSIX asset matched configured patterns: {', '.join(patterns)}")


def download_file(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(
        urllib.request.Request(url, headers={"User-Agent": "codex-app-mirror-local-installer"}),
        timeout=120,
    ) as response:
        with destination.open("wb") as handle:
            shutil.copyfileobj(response, handle)


def safe_member_path(member_name: str) -> PurePosixPath | None:
    normalized = PurePosixPath(member_name.replace("\\", "/"))
    parts = normalized.parts
    if len(parts) < 2 or parts[0] != "app":
        return None
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"Archive contains unsafe path: {member_name}")
    return PurePosixPath(*parts[1:])


def extract_app_folder(archive_path: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    extracted_any = False

    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            relative_path = safe_member_path(member.filename)
            if relative_path is None:
                continue

            target = destination.joinpath(*relative_path.parts)
            resolved_target = target.resolve()
            resolved_destination = destination.resolve()
            if resolved_destination not in resolved_target.parents and resolved_target != resolved_destination:
                raise ValueError(f"Archive contains unsafe path: {member.filename}")

            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue

            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            extracted_any = True

    if not extracted_any:
        raise ValueError(f"No app/ files were found in {archive_path}")


def replace_app_folder(staged_app_dir: Path, target_app_dir: Path, backup_existing: bool) -> Path | None:
    target_app_dir.parent.mkdir(parents=True, exist_ok=True)
    backup_path = None

    if target_app_dir.exists():
        if backup_existing:
            timestamp = time.strftime("%Y%m%d-%H%M%S")
            backup_path = target_app_dir.with_name(f"{target_app_dir.name}.backup-{timestamp}")
            target_app_dir.replace(backup_path)
        else:
            shutil.rmtree(target_app_dir)

    try:
        staged_app_dir.replace(target_app_dir)
    except Exception:
        if backup_path and backup_path.exists() and not target_app_dir.exists():
            backup_path.replace(target_app_dir)
        raise

    return backup_path


def install_latest(config: Config) -> None:
    release = latest_release(config)
    asset = select_msix_asset(release["assets"], config.asset_patterns)
    asset_name = str(asset["name"])
    download_url = str(asset["browser_download_url"])
    archive_path = config.download_dir / asset_name

    print(f"Release: {release.get('tag_name', 'latest')}")
    print(f"Downloading: {asset_name}")
    download_file(download_url, archive_path)

    with tempfile.TemporaryDirectory(prefix="codex-app-msix-") as temp_root:
        staged_app_dir = Path(temp_root) / "app"
        extract_app_folder(archive_path, staged_app_dir)
        backup_path = replace_app_folder(staged_app_dir, config.target_app_dir, config.backup_existing)

    if not config.keep_download:
        archive_path.unlink(missing_ok=True)

    print(f"Installed app folder: {config.target_app_dir}")
    if backup_path:
        print(f"Previous app backup: {backup_path}")
    if config.keep_download:
        print(f"Downloaded MSIX kept at: {archive_path}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Install the app/ folder from the latest Windows MSIX release."
    )
    parser.add_argument(
        "--config",
        default=str(Path(__file__).with_name("install-windows-app.config.json")),
        help="Path to a JSON config file.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    config = load_config(Path(args.config))
    install_latest(config)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
