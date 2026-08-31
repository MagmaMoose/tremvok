#!/usr/bin/env python3
"""Build the Lambda package for the Tremvok API. The one definition of what ships.

Two properties this script exists to guarantee:

**Deterministic.** Fixed timestamps, fixed modes, sorted entry order, pinned dependency
versions from `requirements-lambda.txt`, and exactly one installer. The deploy path compares
digests to decide whether anything changed, so a build that varied byte-for-byte between two
runs of the same commit would open a redeploy pull request on every release until nobody read
them.

**Cross-architecture.** Lambda runs the function on the architecture Terraform declares, not
the one that built the zip. `pydantic-core` is a compiled wheel, so a package built on an Apple
Silicon laptop and deployed to an x86_64 function imports fine locally and dies with
`No module named 'pydantic_core._pydantic_core'` on the first request. `--arch` picks the wheel
platform explicitly and defaults to arm64, which is both the cheaper Lambda architecture and
what a LocalStack run on an ARM laptop needs.

    python3 scripts/build_api_zip.py                     # -> dist/tremvok-api.zip, prints sha256
    python3 scripts/build_api_zip.py --arch x86_64
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess  # nosec B404
import tempfile
import zipfile
from pathlib import Path

# The REPOSITORY root, not the action root: this file lives at deploy/scripts/, but the
# package it zips (src/tremvok) and requirements-lambda.txt are both repo-level. Counted
# explicitly so a future move breaks loudly here rather than silently zipping nothing.
ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "src" / "tremvok"
REQUIREMENTS = ROOT / "requirements-lambda.txt"

# Zip entries carry a timestamp and a mode. Both are inputs to the digest, and both would
# otherwise be "whenever this ran, as whoever ran it". 1980-01-01 is the zip epoch: the
# earliest value the format can represent, so it can never be mistaken for a real build time.
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)
FILE_MODE = 0o644
DIR_MODE = 0o755

ARCH_PLATFORM = {
    # uv/pip wheel platform tags. manylinux2014 is the oldest tag the Lambda Python runtimes
    # accept and the widest match, so it resolves for every dependency that publishes wheels.
    "arm64": "aarch64-manylinux2014",
    "x86_64": "x86_64-manylinux2014",
}

# Never ship these. `__pycache__` is host-specific bytecode that changes the digest without
# changing behaviour; the rest is packaging metadata or test baggage the runtime never reads.
EXCLUDE_DIRS = {"__pycache__", "tests", "test"}
EXCLUDE_SUFFIXES = {".pyc", ".pyo", ".so.dbg"}
# `.lock` is uv's own target-directory lock file — zero bytes, no runtime meaning, and its
# presence depends on which installer ran.
EXCLUDE_NAMES = {"RECORD", "INSTALLER", "REQUESTED", "direct_url.json", ".lock"}


def _install_dependencies(target: Path, arch: str, python_version: str) -> None:
    if not REQUIREMENTS.exists():
        raise SystemExit(f"missing {REQUIREMENTS} — regenerate it with `make lock`")
    platform = ARCH_PLATFORM[arch]

    # uv, and only uv. There WAS a pip fallback here, and it was a bug: pip and uv lay the
    # target directory out slightly differently, so the same commit produced two different
    # digests depending on which happened to be installed — 2796 KiB one way and 2812 KiB the
    # other. That is precisely the "a local run and a released artifact built differently"
    # failure this script exists to prevent, and a fallback that silently changes the artifact
    # is worse than no fallback at all.
    if not shutil.which("uv"):
        raise SystemExit(
            "uv is required to build the Lambda package, so that every build of a commit "
            "produces the same bytes. Install it: https://docs.astral.sh/uv/"
        )

    command = [
        "uv",
        "pip",
        "install",
        "--target",
        str(target),
        # Not optional. Without an explicit platform uv resolves for the HOST, and a package
        # built on a laptop imports fine there and dies on the function with
        # `No module named 'pydantic_core._pydantic_core'`.
        "--python-platform",
        platform,
        "--python-version",
        python_version,
        "--no-installer-metadata",
        "--requirement",
        str(REQUIREMENTS),
    ]
    subprocess.run(command, check=True, cwd=ROOT)  # nosec B603


def _collect(root: Path) -> list[tuple[str, Path]]:
    """(archive name, source path) pairs, sorted, with the excluded set removed."""
    entries: list[tuple[str, Path]] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if any(part in EXCLUDE_DIRS for part in relative.parts):
            continue
        if path.suffix in EXCLUDE_SUFFIXES or path.name in EXCLUDE_NAMES:
            continue
        entries.append((relative.as_posix(), path))
    return sorted(entries, key=lambda item: item[0])


def build(output: Path, arch: str, python_version: str) -> str:
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as staging_name:
        staging = Path(staging_name)
        _install_dependencies(staging, arch, python_version)

        # The package itself is copied last so it always wins over anything a dependency
        # installed under the same name.
        shutil.copytree(PACKAGE, staging / "tremvok", dirs_exist_ok=True)

        entries = _collect(staging)
        if not any(name.startswith("tremvok/") for name, _ in entries):
            raise SystemExit("built package contains no tremvok/ — refusing to write it")

        # ZIP_DEFLATED at a fixed level: the compressor is deterministic, the level is not a
        # default that could change under us with a Python upgrade.
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, source in entries:
                info = zipfile.ZipInfo(name, date_time=ZIP_EPOCH)
                info.external_attr = FILE_MODE << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, source.read_bytes())

    return hashlib.sha256(output.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="dist/tremvok-api.zip", type=Path)
    parser.add_argument(
        "--arch", default=os.environ.get("TREMVOK_ARCH", "arm64"), choices=sorted(ARCH_PLATFORM)
    )
    parser.add_argument("--python-version", default="3.12")
    args = parser.parse_args()

    output = args.out if args.out.is_absolute() else ROOT / args.out
    digest = build(output, args.arch, args.python_version)
    size = output.stat().st_size
    print(f"{output} ({size / 1024:.0f} KiB, {args.arch})")
    print(digest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
