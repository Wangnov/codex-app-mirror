import importlib.util
import json
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("install-windows-app.py")


def load_module():
    spec = importlib.util.spec_from_file_location("install_windows_app", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class InstallWindowsAppTests(unittest.TestCase):
    def test_load_config_expands_environment_variables(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temp_root:
            temp_path = Path(temp_root)
            config_path = temp_path / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "github_repo": "Wangnov/codex-app-mirror",
                        "target_app_dir": "%CODEX_TEST_ROOT%\\Codex-Windows-x64\\app",
                        "download_dir": "%CODEX_TEST_ROOT%\\downloads",
                    }
                ),
                encoding="utf-8",
            )

            old_value = os.environ.get("CODEX_TEST_ROOT")
            os.environ["CODEX_TEST_ROOT"] = temp_root
            try:
                config = module.load_config(config_path)
            finally:
                if old_value is None:
                    os.environ.pop("CODEX_TEST_ROOT", None)
                else:
                    os.environ["CODEX_TEST_ROOT"] = old_value

            self.assertEqual(config.github_repo, "Wangnov/codex-app-mirror")
            self.assertEqual(config.target_app_dir, temp_path / "Codex-Windows-x64" / "app")
            self.assertEqual(config.download_dir, temp_path / "downloads")

    def test_select_msix_asset_prefers_configured_patterns(self):
        module = load_module()
        assets = [
            {
                "name": "Codex-mac-arm64.dmg",
                "browser_download_url": "https://example.test/mac.dmg",
            },
            {
                "name": "OpenAI.Codex_26.1.2.0_x64__2p2nqsd0c76g0.Msix",
                "browser_download_url": "https://example.test/codex.msix",
            },
        ]

        asset = module.select_msix_asset(assets, ["OpenAI.Codex_*_x64__*.Msix"])

        self.assertEqual(asset["name"], "OpenAI.Codex_26.1.2.0_x64__2p2nqsd0c76g0.Msix")

    def test_extract_app_folder_copies_only_inner_app_contents(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temp_root:
            temp_path = Path(temp_root)
            archive_path = temp_path / "codex.msix"
            destination = temp_path / "staging"

            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("app/Codex.exe", "binary")
                archive.writestr("app/resources/config.json", "{}")
                archive.writestr("metadata/not-installed.txt", "skip")

            module.extract_app_folder(archive_path, destination)

            self.assertEqual((destination / "Codex.exe").read_text(encoding="utf-8"), "binary")
            self.assertEqual(
                (destination / "resources" / "config.json").read_text(encoding="utf-8"),
                "{}",
            )
            self.assertFalse((destination / "metadata").exists())

    def test_extract_app_folder_rejects_path_traversal(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temp_root:
            temp_path = Path(temp_root)
            archive_path = temp_path / "codex.msix"

            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("app/../escape.txt", "bad")

            with self.assertRaisesRegex(ValueError, "unsafe path"):
                module.extract_app_folder(archive_path, temp_path / "staging")


if __name__ == "__main__":
    unittest.main()
