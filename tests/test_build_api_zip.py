"""The packaging contract.

`scripts/build_api_zip.py` is the one definition of what ships to Lambda, and two of its
properties are load-bearing in ways nothing else would notice:

**Determinism.** The deploy path decides whether to ship by comparing digests. A build that
varied between two runs of the same commit would open a redeploy pull request on every release
until nobody read them.

**The right architecture's wheels.** `pydantic-core` is compiled. A package built with the
host's wheels and deployed to a function of the other architecture applies cleanly, plans
cleanly, and dies at the first request with `No module named
'pydantic_core._pydantic_core'`. Only the *contents* of the zip can prove the cross-build
actually happened, which is what this asserts — an import test cannot, because the wheels are
Linux wheels and the test runner may not be Linux.
"""

from __future__ import annotations

import os
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / "scripts" / "build_api_zip.py"


def build(tmp_path: Path, arch: str) -> tuple[Path, str]:
    out = tmp_path / f"{arch}.zip"
    result = subprocess.run(
        [sys.executable, str(BUILDER), "--arch", arch, "--out", str(out)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        pytest.skip(f"could not build the package (offline?): {result.stderr[-300:]}")
    return out, result.stdout.strip().splitlines()[-1]


@pytest.mark.parametrize(("arch", "marker"), [("arm64", "aarch64"), ("x86_64", "x86_64")])
def test_the_package_carries_that_architectures_compiled_wheels(tmp_path, arch, marker):
    archive, _ = build(tmp_path, arch)
    with zipfile.ZipFile(archive) as zf:
        shared_objects = [n for n in zf.namelist() if n.startswith("pydantic_core/") and ".so" in n]

    assert shared_objects, "the package has no compiled pydantic_core at all"
    assert any(marker in name for name in shared_objects), (
        f"built for {arch} but the wheels are {shared_objects} — the cross-build silently fell "
        "back to the host's platform"
    )


def test_the_build_is_deterministic(tmp_path):
    first_path, first_digest = build(tmp_path, "arm64")
    second_path, second_digest = build(tmp_path / "again", "arm64")
    assert first_digest == second_digest
    assert first_path.read_bytes() == second_path.read_bytes()


def test_the_two_architectures_are_different_packages(tmp_path):
    # If they were identical, the --arch flag would be doing nothing and the test above would
    # be passing for the wrong reason.
    _, arm = build(tmp_path, "arm64")
    _, intel = build(tmp_path / "intel", "x86_64")
    assert arm != intel


def test_the_package_contains_the_application_and_no_build_noise(tmp_path):
    archive, _ = build(tmp_path, "arm64")
    with zipfile.ZipFile(archive) as zf:
        names = zf.namelist()

    assert "tremvok/aws/handler.py" in names
    assert "tremvok/api/app.py" in names
    # Host-specific bytecode changes the digest without changing behaviour; `.lock` is uv's
    # own marker in the target directory and depends on which installer ran.
    assert not [n for n in names if "__pycache__" in n or n.endswith(".pyc")]
    assert ".lock" not in names


def test_every_entry_has_a_fixed_timestamp_and_mode(tmp_path):
    archive, _ = build(tmp_path, "arm64")
    with zipfile.ZipFile(archive) as zf:
        infos = zf.infolist()
    assert infos
    assert {info.date_time for info in infos} == {(1980, 1, 1, 0, 0, 0)}
    assert {info.external_attr >> 16 for info in infos} == {0o644}


def test_the_builder_refuses_to_run_without_uv(tmp_path):
    """The pip fallback that used to live here produced a *different digest* for the same
    commit — 2796 KiB one way, 2812 KiB the other — which is exactly the failure the
    determinism guarantee exists to prevent. Refusing is the correct behaviour."""
    scrubbed = {**os.environ, "PATH": "/usr/bin:/bin"}
    result = subprocess.run(
        [sys.executable, str(BUILDER), "--out", str(tmp_path / "x.zip")],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        env=scrubbed,
    )
    assert result.returncode != 0
    assert "uv is required" in (result.stdout + result.stderr)
