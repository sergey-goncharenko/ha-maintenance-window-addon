#!/usr/bin/env python3
"""Validate the Maintenance Window add-on repository metadata."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "maintenance_window"
CONFIG = ADDON / "config.json"
TRANSLATIONS = ADDON / "translations" / "en.yaml"


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def load_config() -> dict:
    try:
        return json.loads(CONFIG.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        fail(f"{CONFIG.relative_to(ROOT)} is not valid JSON: {error}")


def top_level_translation_keys() -> set[str]:
    keys: set[str] = set()
    in_configuration = False

    for line in TRANSLATIONS.read_text(encoding="utf-8").splitlines():
        if line == "configuration:":
            in_configuration = True
            continue
        if in_configuration and line and not line.startswith(" "):
            break

        match = re.match(r"^  ([A-Za-z0-9_]+):\s*$", line)
        if in_configuration and match:
            keys.add(match.group(1))

    return keys


def translation_field_keys(section: str) -> set[str]:
    keys: set[str] = set()
    lines = TRANSLATIONS.read_text(encoding="utf-8").splitlines()
    in_section = False
    in_fields = False

    for line in lines:
        if re.match(rf"^  {re.escape(section)}:\s*$", line):
            in_section = True
            continue
        if in_section and re.match(r"^  [A-Za-z0-9_]+:\s*$", line):
            break
        if in_section and line == "    fields:":
            in_fields = True
            continue
        if in_fields:
            match = re.match(r"^      ([A-Za-z0-9_]+):\s*$", line)
            if match:
                keys.add(match.group(1))

    return keys


def require_keys(config: dict) -> None:
    required = {
        "name",
        "version",
        "slug",
        "description",
        "url",
        "arch",
        "init",
        "startup",
        "boot",
        "hassio_api",
        "hassio_role",
        "options",
        "schema",
    }
    missing = sorted(required - set(config))
    if missing:
        fail(f"config.json is missing required keys: {', '.join(missing)}")


def validate_image_metadata(config: dict) -> None:
    expected_arches = {"aarch64", "amd64"}
    actual_arches = set(config.get("arch", []))
    if actual_arches != expected_arches:
        fail(f"arch must be exactly {sorted(expected_arches)}, got {sorted(actual_arches)}")

    expected_image = "ghcr.io/sergey-goncharenko/maintenance-window-addon"
    if config.get("image") != expected_image:
        fail(f"image must be {expected_image!r}, got {config.get('image')!r}")

    if (ADDON / "build.yaml").exists():
        fail("maintenance_window/build.yaml is deprecated and should not exist")


def validate_options_schema(config: dict) -> None:
    option_keys = set(config["options"])
    schema_keys = set(config["schema"])

    missing_schema = sorted(option_keys - schema_keys)
    missing_defaults = sorted(schema_keys - option_keys)
    if missing_schema:
        fail(f"options without schema entries: {', '.join(missing_schema)}")
    if missing_defaults:
        fail(f"schema entries without defaults: {', '.join(missing_defaults)}")

    translation_keys = top_level_translation_keys()
    missing_translations = sorted(option_keys - translation_keys)
    if missing_translations:
        fail(f"options without English translations: {', '.join(missing_translations)}")

    window_schema = config["schema"].get("windows", [{}])[0]
    window_fields = set(window_schema)
    translated_window_fields = translation_field_keys("windows")
    missing_window_translations = sorted(window_fields - translated_window_fields)
    if missing_window_translations:
        fail(
            "window fields without English translations: "
            + ", ".join(missing_window_translations)
        )


def validate_safety_defaults(config: dict) -> None:
    options = config["options"]
    expected = {
        "dry_run": True,
        "restart_core": False,
        "core_stop_confirmation": "",
        "startup_grace_seconds": 300,
        "max_core_stop_minutes": 60,
    }

    for key, value in expected.items():
        if options.get(key) != value:
            fail(f"unsafe default for {key!r}: expected {value!r}, got {options.get(key)!r}")


def validate_apparmor(config: dict) -> None:
    apparmor_file = ADDON / "apparmor.txt"
    apparmor_setting = config.get("apparmor", True)

    if apparmor_setting is False and apparmor_file.exists():
        fail("apparmor is disabled but maintenance_window/apparmor.txt still exists")
    if apparmor_setting is not False and not apparmor_file.exists():
        fail("apparmor is enabled/default but maintenance_window/apparmor.txt is missing")


def validate_line_endings() -> None:
    checked_paths = [
        ADDON / "run.sh",
        ADDON / "rootfs" / "usr" / "lib" / "maintenance-window" / "scheduler.sh",
        ADDON / "rootfs" / "etc" / "s6-overlay" / "s6-rc.d" / "maintenance_window" / "run",
        ADDON / "rootfs" / "etc" / "s6-overlay" / "s6-rc.d" / "maintenance_window" / "finish",
    ]
    apparmor_file = ADDON / "apparmor.txt"
    if apparmor_file.exists():
        checked_paths.append(apparmor_file)

    for path in checked_paths:
        data = path.read_bytes()
        if b"\r\n" in data:
            fail(f"{path.relative_to(ROOT)} contains CRLF line endings")


def main() -> None:
    config = load_config()
    require_keys(config)
    validate_image_metadata(config)
    validate_options_schema(config)
    validate_safety_defaults(config)
    validate_apparmor(config)
    validate_line_endings()
    print("Add-on metadata validation passed.")


if __name__ == "__main__":
    main()