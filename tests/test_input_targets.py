"""The applicability map is what makes a target enum honest, so it must not drift.

`scripts/lib/input-targets.json` is generated from `action.yml`. The runtime validator
reads the JSON; the reference page reads the same parser. If the committed JSON went stale,
an input would be documented as applicable and then refused at runtime — or, worse, refused
when it is perfectly valid.
"""

from __future__ import annotations

import json
import pathlib
import subprocess  # nosec B404
import sys

import gen_action_reference
import gen_input_targets
import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAP = ROOT / "scripts" / "lib" / "input-targets.json"
ACTION = yaml.safe_load((ROOT / "action.yml").read_text(encoding="utf-8"))


def run_generator(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(  # nosec B603
        [sys.executable, str(ROOT / "scripts" / args[0]), *args[1:]],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def test_the_committed_map_matches_action_yml():
    result = run_generator("gen_input_targets.py", "--check")
    assert result.returncode == 0, result.stdout + result.stderr


def test_the_committed_reference_matches_action_yml():
    result = run_generator("gen_action_reference.py", "--check")
    assert result.returncode == 0, result.stdout + result.stderr


def test_every_input_except_the_selector_is_in_the_map():
    mapped = set(json.loads(MAP.read_text())["inputs"])
    declared = set(ACTION["inputs"]) - {"target"}
    assert mapped == declared, f"map and action.yml disagree: {mapped ^ declared}"


def test_defaults_in_the_map_match_the_action():
    """The validator compares a received value against this default to decide whether the
    input was set at all. A stale default here means an input silently stops being checked."""
    data = json.loads(MAP.read_text())["inputs"]
    for name, spec in ACTION["inputs"].items():
        if name == "target":
            continue
        assert data[name]["default"] == str(spec.get("default", "")), name


@pytest.mark.parametrize("target", ["docs", "s3-cloudfront", "lambda-zip", "terragrunt", "ansible"])
def test_every_target_owns_at_least_one_input(target):
    data = json.loads(MAP.read_text())["inputs"]
    owned = [n for n, s in data.items() if s["targets"] == [target]]
    assert owned, f"target {target!r} has no inputs of its own, which cannot be right"


def test_target_specific_inputs_are_named_for_their_target():
    """The prefix is not decoration. It is how a caller reading a workflow file can tell
    which target an input belongs to without opening the reference."""
    prefixes = {
        "docs": ("docs-",),
        "s3-cloudfront": ("s3-", "cloudfront-", "artifact-"),
        "lambda-zip": ("lambda-", "s3-", "artifact-"),
        "terragrunt": ("terragrunt-",),
        "ansible": ("ansible-",),
    }
    data = json.loads(MAP.read_text())["inputs"]
    wrong = []
    for name, spec in data.items():
        if len(spec["targets"]) != 1:
            continue
        target = spec["targets"][0]
        if not name.startswith(prefixes[target]):
            wrong.append(f"{name} is {target}-only but carries no {target} prefix")
    assert not wrong, "\n".join(wrong)


def test_the_selector_itself_is_required_and_has_no_default():
    """There is no sensible default. Guessing `docs` would silently build a site for
    somebody who meant to deploy a Lambda."""
    assert ACTION["inputs"]["target"]["required"] is True
    assert "default" not in ACTION["inputs"]["target"]


# Direct import tests — subprocess calls above do not contribute to coverage measurement.

def test_targets_for_returns_all_when_description_has_no_target_prefix():
    all_targets = gen_input_targets.TARGETS
    assert gen_input_targets.targets_for("Post-deploy: the URL.") == all_targets
    assert gen_input_targets.targets_for("") == all_targets
    assert gen_input_targets.targets_for(None) == all_targets


def test_targets_for_parses_single_target_prefix():
    assert gen_input_targets.targets_for("docs: Cloudflare project name.") == ["docs"]
    assert gen_input_targets.targets_for("ansible: SSH key.") == ["ansible"]


def test_targets_for_parses_multi_target_prefix():
    result = gen_input_targets.targets_for("s3-cloudfront, lambda-zip: the bucket.")
    assert result == ["s3-cloudfront", "lambda-zip"]


def test_targets_for_treats_unknown_prefix_as_prose():
    assert gen_input_targets.targets_for("Post-deploy: something.") == gen_input_targets.TARGETS


def test_build_returns_all_declared_targets():
    data = gen_input_targets.build()
    assert data["targets"] == gen_input_targets.TARGETS


def test_build_excludes_the_selector_input():
    data = gen_input_targets.build()
    assert "target" not in data["inputs"]


def test_render_produces_valid_json():
    import json as _json
    text = gen_input_targets.render()
    parsed = _json.loads(text)
    assert "inputs" in parsed
    assert "targets" in parsed


def test_action_reference_default_formats_value():
    assert gen_action_reference.default("auto") == "`auto`"
    assert gen_action_reference.default("") == "not set"
    assert gen_action_reference.default(None) == "not set"


def test_action_reference_applies_to_selector():
    assert gen_action_reference.applies_to("target", {}) == "the selector"


def test_action_reference_applies_to_single_target():
    result = gen_action_reference.applies_to("docs-site-dir", {"description": "docs: the dir."})
    assert result == "`docs`"


def test_action_reference_applies_to_all():
    result = gen_action_reference.applies_to(
        "environment", {"description": "Logical environment name."}
    )
    assert result == "all"
