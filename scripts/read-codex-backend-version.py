#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import PurePosixPath


BACKEND_VERSION_RE = re.compile(r"(?im)^\s*(?:codex-cli\s+)?([0-9]+\.[0-9]+\.[0-9][0-9A-Za-z._+-]*)\s*$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MACOS_BACKEND_PATH = ("Contents", "Resources", "codex")
WINDOWS_BACKEND_PATH = "app/resources/codex.exe"
PREPARED_INPUT_MANIFEST = "backend-input.json"
PREPARED_INPUT_SCHEMA_VERSION = 1
BACKEND_FILE_NAMES = {
    "macos": "codex",
    "windows": "codex.exe",
}


def die(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def parse_version(output):
    match = BACKEND_VERSION_RE.search(output)
    return match.group(1) if match else ""


def normalized_path(path):
    return PurePosixPath(path.replace("\\", "/")).as_posix().lower()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def isolated_env(tmp_dir):
    env = os.environ.copy()
    home = os.path.join(tmp_dir, "home")
    os.makedirs(home, exist_ok=True)
    paths = {
        "HOME": home,
        "USERPROFILE": home,
        "APPDATA": os.path.join(tmp_dir, "appdata"),
        "LOCALAPPDATA": os.path.join(tmp_dir, "localappdata"),
        "XDG_CONFIG_HOME": os.path.join(tmp_dir, "xdg-config"),
        "XDG_CACHE_HOME": os.path.join(tmp_dir, "xdg-cache"),
        "CODEX_HOME": os.path.join(tmp_dir, "codex-home"),
    }
    for key, value in paths.items():
        os.makedirs(value, exist_ok=True)
        env[key] = value
    return env


def run_backend(binary_path):
    with tempfile.TemporaryDirectory(prefix="codex-backend-version-") as tmp_dir:
        env = isolated_env(tmp_dir)
        try:
            completed = subprocess.run(
                [binary_path, "--version"],
                cwd=tmp_dir,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=20,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return ""

    if completed.returncode != 0:
        return ""
    return parse_version((completed.stdout or "") + "\n" + (completed.stderr or ""))


def iter_backend_paths(root):
    root = os.path.abspath(root)
    if os.path.isfile(root):
        yield root
        return

    candidate = os.path.join(root, *MACOS_BACKEND_PATH)
    if os.path.isfile(candidate):
        yield candidate


def ensure_executable(path):
    if os.name == "nt":
        return
    try:
        current = os.stat(path).st_mode
        os.chmod(path, current | stat.S_IXUSR)
    except OSError:
        pass


def zip_backend_entries(zip_file):
    entries = [
        info
        for info in zip_file.infolist()
        if normalized_path(info.filename) == WINDOWS_BACKEND_PATH
    ]
    entries.sort(key=lambda info: normalized_path(info.filename))
    return entries


def copy_windows_backend(path, target):
    with zipfile.ZipFile(path) as zip_file:
        entries = zip_backend_entries(zip_file)
        if len(entries) != 1 or entries[0].is_dir():
            return False
        with zip_file.open(entries[0]) as source, open(target, "wb") as output:
            shutil.copyfileobj(source, output)
    return True


def copy_macos_backend(path, target):
    candidate = os.path.join(os.path.abspath(path), *MACOS_BACKEND_PATH)
    if not os.path.isfile(candidate) or os.path.islink(candidate):
        return False
    shutil.copyfile(candidate, target)
    return True


def copy_packaged_backend(path, platform, target):
    if platform == "windows":
        if not os.path.isfile(path) or not zipfile.is_zipfile(path):
            return False
        return copy_windows_backend(path, target)
    if platform == "macos":
        return copy_macos_backend(path, target)
    return False


def read_backend_version_from_zip(path):
    with tempfile.TemporaryDirectory(prefix="codex-backend-msix-") as tmp_dir:
        target = os.path.join(tmp_dir, BACKEND_FILE_NAMES["windows"])
        if copy_windows_backend(path, target):
            ensure_executable(target)
            return run_backend(target)
    return ""


def read_backend_version(path):
    if os.path.isfile(path) and zipfile.is_zipfile(path):
        return read_backend_version_from_zip(path)

    for candidate in iter_backend_paths(path):
        ensure_executable(candidate)
        version = run_backend(candidate)
        if version:
            return version
    return ""


def remove_known_prepared_files(output_dir):
    for name in (PREPARED_INPUT_MANIFEST, *BACKEND_FILE_NAMES.values()):
        path = os.path.join(output_dir, name)
        try:
            if os.path.isfile(path) or os.path.islink(path):
                os.remove(path)
        except OSError:
            pass


def write_json(path, payload):
    tmp_path = f"{path}.tmp"
    try:
        with open(tmp_path, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)


def prepare_backend_input(path, output_dir, source_package, source_sha256, platform, architecture):
    output_dir = os.path.abspath(output_dir)
    os.makedirs(output_dir, exist_ok=True)
    remove_known_prepared_files(output_dir)

    payload = {
        "architecture": architecture,
        "platform": platform,
        "schemaVersion": PREPARED_INPUT_SCHEMA_VERSION,
        "status": "unavailable",
    }
    source_sha256 = source_sha256.strip().lower()
    try:
        if not os.path.isfile(source_package):
            raise ValueError("source package is missing")
        if not source_sha256:
            source_sha256 = sha256_file(source_package)
        if not SHA256_RE.fullmatch(source_sha256):
            raise ValueError("source package SHA256 is invalid")

        payload["sourcePackageFileName"] = os.path.basename(source_package)
        payload["sourcePackageSha256"] = source_sha256
        backend_file_name = BACKEND_FILE_NAMES[platform]
        backend_path = os.path.join(output_dir, backend_file_name)
        backend_tmp_path = f"{backend_path}.tmp"
        try:
            if not copy_packaged_backend(path, platform, backend_tmp_path):
                raise ValueError("fixed-path backend is unavailable")
            backend_sha256 = sha256_file(backend_tmp_path)
            os.replace(backend_tmp_path, backend_path)
        finally:
            if os.path.exists(backend_tmp_path):
                os.remove(backend_tmp_path)

        payload.update(
            {
                "backendFileName": backend_file_name,
                "backendSha256": backend_sha256,
                "status": "ready",
            }
        )
    except (OSError, ValueError, zipfile.BadZipFile):
        remove_known_prepared_files(output_dir)

    manifest_path = os.path.join(output_dir, PREPARED_INPUT_MANIFEST)
    write_json(manifest_path, payload)
    return payload


def read_prepared_backend_version(manifest_path, platform, architecture):
    try:
        with open(manifest_path, encoding="utf-8-sig") as handle:
            payload = json.load(handle)
        if not isinstance(payload, dict) or payload.get("status") != "ready":
            return ""
        if payload.get("schemaVersion") != PREPARED_INPUT_SCHEMA_VERSION:
            return ""

        prepared_platform = payload.get("platform")
        prepared_architecture = payload.get("architecture")
        if prepared_platform not in BACKEND_FILE_NAMES:
            return ""
        if platform and prepared_platform != platform:
            return ""
        if architecture and prepared_architecture != architecture:
            return ""

        source_file_name = payload.get("sourcePackageFileName")
        source_sha256 = payload.get("sourcePackageSha256")
        backend_file_name = payload.get("backendFileName")
        backend_sha256 = payload.get("backendSha256")
        if (
            not isinstance(source_file_name, str)
            or not source_file_name
            or os.path.basename(source_file_name) != source_file_name
            or not isinstance(source_sha256, str)
            or not SHA256_RE.fullmatch(source_sha256.lower())
            or backend_file_name != BACKEND_FILE_NAMES[prepared_platform]
            or not isinstance(backend_sha256, str)
            or not SHA256_RE.fullmatch(backend_sha256.lower())
        ):
            return ""

        backend_path = os.path.join(os.path.dirname(os.path.abspath(manifest_path)), backend_file_name)
        if not os.path.isfile(backend_path) or os.path.islink(backend_path):
            return ""
        if sha256_file(backend_path) != backend_sha256.lower():
            return ""
        ensure_executable(backend_path)
        return run_backend(backend_path)
    except (OSError, TypeError, ValueError, json.JSONDecodeError):
        return ""


def main(argv):
    parser = argparse.ArgumentParser(description="Read the bundled Codex backend version by running the packaged backend binary.")
    parser.add_argument("path", help="MSIX/ZIP, backend executable, mounted Codex.app, or prepared input manifest")
    parser.add_argument("--json", action="store_true", help="Always emit a JSON metadata object and exit 0")
    parser.add_argument("--platform", default="", help="Platform label for --json output")
    parser.add_argument("--architecture", default="", help="Architecture label for --json output")
    parser.add_argument("--prepare-input-dir", default="", help="Extract a fixed-path backend into a small native-job input directory")
    parser.add_argument("--prepared-input", action="store_true", help="Validate and run a backend from a prepared input manifest")
    parser.add_argument("--source-package", default="", help="Source package recorded by --prepare-input-dir")
    parser.add_argument("--source-package-sha256", default="", help="Known source package SHA256 for --prepare-input-dir")
    args = parser.parse_args(argv[1:])

    if args.prepare_input_dir and args.prepared_input:
        die("--prepare-input-dir and --prepared-input are mutually exclusive.")
    if args.prepare_input_dir:
        if args.platform not in BACKEND_FILE_NAMES:
            die("--prepare-input-dir requires --platform windows or macos.")
        if not args.architecture:
            die("--prepare-input-dir requires --architecture.")
        if not args.source_package:
            die("--prepare-input-dir requires --source-package.")
        payload = prepare_backend_input(
            args.path,
            args.prepare_input_dir,
            args.source_package,
            args.source_package_sha256,
            args.platform,
            args.architecture,
        )
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return

    if args.prepared_input:
        version = read_prepared_backend_version(args.path, args.platform, args.architecture)
    else:
        version = read_backend_version(args.path)
    if args.json:
        payload = {
            "status": "found" if version else "unavailable",
        }
        if args.platform:
            payload["platform"] = args.platform
        if args.architecture:
            payload["architecture"] = args.architecture
        if version:
            payload["backendVersion"] = version
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return

    if version:
        print(version)
        return
    die("Could not read Codex backend version by running the packaged backend binary.")


if __name__ == "__main__":
    main(sys.argv)
