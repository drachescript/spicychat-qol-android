#!/usr/bin/env python3
"""Check the Android CI toolchain before a long, signed APK build.

This project currently uses a tested Flutter 3.47.x / Gradle 8.x toolchain.
Upgrade Flutter, Gradle, AGP and Kotlin together in an intentional change,
after verifying a complete signed Android build.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {
    "Flutter": "3.47.9",
    "Gradle": "8.14",
    "Android Gradle Plugin": "8.11.1",
    "Kotlin Gradle Plugin": "2.2.20",
}
WORKFLOWS = (
    ".github/workflows/android-release.yml",
    ".github/workflows/android-validate.yml",
)


def require_equal(label: str, actual: str | None, expected: str, errors: list[str]) -> None:
    if actual != expected:
        errors.append(f"{label}: expected {expected}, found {actual or 'not configured'}")


def find_version(text: str, pattern: str) -> str | None:
    match = re.search(pattern, text, flags=re.MULTILINE)
    return match.group(1) if match else None


def check_files(errors: list[str]) -> None:
    wrapper = (ROOT / "android_app/android/gradle/wrapper/gradle-wrapper.properties").read_text(
        encoding="utf-8"
    )
    settings = (ROOT / "android_app/android/settings.gradle.kts").read_text(encoding="utf-8")
    require_equal(
        "Gradle wrapper",
        find_version(wrapper, r"^distributionUrl=.*gradle-([0-9.]+)-(?:bin|all)\.zip\s*$"),
        EXPECTED["Gradle"],
        errors,
    )
    require_equal(
        "Android Gradle Plugin",
        find_version(settings, r'^\s*id\("com\.android\.application"\)\s+version\s+"([0-9.]+)"'),
        EXPECTED["Android Gradle Plugin"],
        errors,
    )
    require_equal(
        "Kotlin Gradle Plugin",
        find_version(settings, r'^\s*id\("org\.jetbrains\.kotlin\.android"\)\s+version\s+"([0-9.]+)"'),
        EXPECTED["Kotlin Gradle Plugin"],
        errors,
    )
    for path in WORKFLOWS:
        workflow = (ROOT / path).read_text(encoding="utf-8")
        version_lines = re.findall(
            r"""^\s+flutter-version:\s*['"]?([0-9]+\.[0-9]+\.[0-9]+)['"]?\s*$""",
            workflow,
            flags=re.MULTILINE,
        )
        if len(version_lines) != 1:
            errors.append(f"{path}: expected exactly one explicit Flutter SDK pin")
        else:
            require_equal(
                f"{path} Flutter pin", version_lines[0], EXPECTED["Flutter"], errors
            )


def check_flutter_runtime(errors: list[str]) -> None:
    try:
        result = subprocess.run(
            ["flutter", "--version"],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        errors.append(f"Unable to determine installed Flutter SDK version: {exc}")
        return
    output = result.stdout + result.stderr
    require_equal(
        "Installed Flutter SDK",
        find_version(output, r"Flutter ([0-9]+\.[0-9]+\.[0-9]+)"),
        EXPECTED["Flutter"],
        errors,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check-flutter",
        action="store_true",
        help="also check the installed flutter executable (used in GitHub Actions)",
    )
    args = parser.parse_args()
    problems: list[str] = []
    check_files(problems)
    if args.check_flutter:
        check_flutter_runtime(problems)
    if problems:
        print("Android toolchain preflight FAILED:", file=sys.stderr)
        for problem in problems:
            print(f" - {problem}", file=sys.stderr)
        print(
            "Update both CI pins and the tested Gradle/AGP/Kotlin matrix together; "
            "never bypass dependency validation to publish an APK.",
            file=sys.stderr,
        )
        return 1
    for tool, version in EXPECTED.items():
        print(f"{tool}: {version} (verified)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
