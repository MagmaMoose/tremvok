"""The contract between `action.yml`, `scripts/` and the README.

`action.yml` is glue: it maps inputs to environment variables and runs a script. Every joint in
that chain can be wrong in a way nothing else notices — an env var spelled one way in the YAML
and another in the script silently disables an input, and the run is green. These tests are the
thing that notices.
"""

from __future__ import annotations

import pathlib
import re

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
ACTION_TEXT = (ROOT / "deploy" / "action.yml").read_text()
ACTION = yaml.safe_load(ACTION_TEXT)
STEPS = ACTION["runs"]["steps"]

# Environment variables a step sets for something other than the script it runs. Each needs a
# reason, because the default assumption — "set but never read" — is a bug.
PASS_THROUGH = {
    # Read by the AWS CLI and SDK inside the script's own subprocesses, never by the script.
    "AWS_REGION",
}


def steps_running_scripts() -> list[tuple[dict, list[pathlib.Path]]]:
    out = []
    for step in STEPS:
        names = re.findall(r"scripts/([A-Za-z0-9_.-]+\.sh)", step.get("run", ""))
        if names:
            out.append((step, [ROOT / "deploy" / "scripts" / n for n in names]))
    return out


def test_every_script_the_action_names_exists():
    for step, scripts in steps_running_scripts():
        for script in scripts:
            assert script.is_file(), f"{step.get('name')} runs a missing {script.name}"


def test_every_output_points_at_a_real_step():
    ids = {step["id"] for step in STEPS if "id" in step}
    for key, spec in ACTION["outputs"].items():
        for referenced in re.findall(r"steps\.([A-Za-z0-9_-]+)\.outputs", spec["value"]):
            assert referenced in ids, f"output {key} references unknown step id {referenced!r}"


def test_every_env_var_a_step_sets_is_actually_read():
    """The silent-failure joint: `KEY_PREFIX` in the YAML and `KEYPREFIX` in the script is a
    green run in which an input does nothing at all."""
    unread = []
    for step, scripts in steps_running_scripts():
        body = "\n".join(s.read_text() for s in scripts) + step.get("run", "")
        for name in step.get("env", {}):
            if name in PASS_THROUGH:
                continue
            if not re.search(rf"\$\{{?{re.escape(name)}\b|\$\{{{re.escape(name)}[:#%/-]", body):
                unread.append(f"{step.get('name')!r} sets {name}, which nothing reads")
    assert not unread, "\n".join(unread)


def test_every_declared_input_is_used():
    for name in ACTION["inputs"]:
        assert f"inputs.{name}" in ACTION_TEXT, f"input {name!r} is declared and never used"


def test_every_step_that_runs_a_script_declares_bash():
    # A composite action step without `shell:` fails at load time on some runners and defaults
    # differently on others; the scripts are bash and rely on it.
    for step, _ in steps_running_scripts():
        assert step.get("shell") == "bash", f"{step.get('name')} does not declare shell: bash"


def test_every_input_and_output_is_documented_in_the_reference():
    """The deploy action's reference is docs/action.md, NOT the README.

    The README is rendered verbatim on the Marketplace with no nav and no search, so
    scripts/lint_docs.py holds it to an action profile that bans a full `## Inputs` table
    and caps it at 120 lines — a full table for a second action would break both. The
    README carries the most-used inputs and links out; this file is where every input has
    to appear, and this test is what keeps that true.
    """
    reference = (ROOT / "docs" / "action.md").read_text()
    undocumented = [n for n in ACTION["inputs"] if f"`{n}`" not in reference]
    assert not undocumented, f"inputs missing from docs/action.md: {undocumented}"
    missing_outputs = [n for n in ACTION["outputs"] if f"`{n}`" not in reference]
    assert not missing_outputs, f"outputs missing from docs/action.md: {missing_outputs}"


def test_notification_steps_run_even_when_the_deploy_failed():
    """A deploy that failed is exactly when the humans most need telling. A notification step
    without `always()` is skipped the moment anything upstream goes red."""
    for step in STEPS:
        name = step.get("name", "")
        if name.startswith("Notify") or name.startswith("Record"):
            assert "always()" in step.get("if", ""), f"{name} is not gated on always()"


@pytest.mark.parametrize("script", sorted((ROOT / "deploy" / "scripts").glob("*.sh")))
def test_every_script_fails_closed_and_is_executable(script):
    assert script.stat().st_mode & 0o111, f"{script.name} is not executable"
    text = script.read_text()
    assert "set -euo pipefail" in text, f"{script.name} does not set -euo pipefail"
    if script.name != "lib":
        assert text.startswith("#!/usr/bin/env bash"), f"{script.name} has no bash shebang"
