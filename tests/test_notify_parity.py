"""The two notification implementations must stay recognisably the same card.

There are deliberately two: `scripts/notify-webhook.sh` posts straight from the runner when the
API is not in use, and `src/tremvok/notify.py` fans out server-side when it is. That is the
same duplication this whole project exists to end — three repositories with three versions of
one PR comment — so it only stays acceptable while something checks that they agree.

These tests assert the *shape and the facts*, not byte equality: the two speak to the same two
sinks, so a field one shows and the other does not is a real difference somebody will notice on
the day the API is switched on.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

from tremvok import notify
from tremvok.models import DeploymentRecord

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "notify-webhook.sh"

RECORD = DeploymentRecord(
    repository="MagmaMoose/website",
    recorded_at="2026-08-19T09:00:00.000Z",
    deployment_id="abc123",
    delivery_id="run-1:1:prod:deploy",
    environment="prod",
    status="success",
    target="s3-cloudfront",
    mode="deploy",
    version="1.4.0",
    url="https://magmamoose.com/",
    commit="0123456789abcdef",
    run_url="https://github.com/MagmaMoose/website/actions/runs/1",
    actor="CalebSargeant",
    verified=True,
)


@pytest.fixture
def shell_payloads(tmp_path):
    """Run the shell notifier with a `curl` that records what it was asked to send."""
    stub_bin = tmp_path / "bin"
    stub_bin.mkdir()
    captured = tmp_path / "captured"
    captured.mkdir()

    (stub_bin / "curl").write_text(
        "#!/usr/bin/env bash\n"
        'prev=""\n'
        'for arg in "$@"; do\n'
        '  if [ "$prev" = "--data" ]; then\n'
        f'    printf \'%s\' "$arg" > "{captured}/$(ls "{captured}" | wc -l | tr -d " ").json"\n'
        "  fi\n"
        '  prev="$arg"\n'
        "done\n"
        "printf '200'\n"
    )
    (stub_bin / "curl").chmod(0o755)

    environment = {
        **os.environ,
        "PATH": f"{stub_bin}:{os.environ['PATH']}",
        "SLACK_WEBHOOK": "https://hooks.slack.test/x",
        "TEAMS_WEBHOOK": "https://outlook.test/y",
        "REPOSITORY": RECORD.repository,
        "ENVIRONMENT": RECORD.environment,
        "STATUS": RECORD.status,
        "MODE": RECORD.mode,
        "TARGET": RECORD.target,
        "VERSION": RECORD.version or "",
        "URL": RECORD.url or "",
        "COMMIT": RECORD.commit or "",
        "RUN_URL": RECORD.run_url or "",
        "ACTOR": RECORD.actor or "",
        "VERIFIED": "true",
    }
    result = subprocess.run(
        ["bash", str(SCRIPT)], env=environment, capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stdout + result.stderr

    sent = [json.loads(p.read_text()) for p in sorted(captured.iterdir())]
    assert len(sent) == 2, f"expected a Slack and a Teams payload, got {len(sent)}"
    return {"slack": sent[0], "teams": sent[1]}


def _labels(payload: dict) -> set[str]:
    """The fact labels a Slack card shows, however the sections are arranged."""
    labels = set()
    for block in payload.get("blocks", []):
        for field in block.get("fields", []):
            labels.add(field["text"].split("\n", 1)[0].strip("*"))
    return labels


def test_slack_cards_carry_the_same_facts(shell_payloads):
    shell = shell_payloads["slack"]
    python = notify.slack_payload(RECORD)

    # Repository and Environment are in the headline of both rather than in the field list, so
    # the comparison is over the fields each one adds beyond that.
    shared = {"Target", "Mode", "Version", "Commit", "Actor", "Verified"}
    assert shared <= _labels(shell), f"the shell card is missing {shared - _labels(shell)}"
    assert shared <= _labels(python), f"the Python card is missing {shared - _labels(python)}"


def test_both_slack_cards_have_a_fallback_text(shell_payloads):
    # Without `text`, the push notification and the screen-reader rendering are both empty.
    for payload in (shell_payloads["slack"], notify.slack_payload(RECORD)):
        assert payload["text"]
        assert RECORD.repository in payload["text"]
        assert RECORD.environment in payload["text"]


def test_both_slack_cards_link_the_deployment_and_the_run(shell_payloads):
    for payload in (shell_payloads["slack"], notify.slack_payload(RECORD)):
        body = json.dumps(payload)
        assert RECORD.url in body
        assert RECORD.run_url in body


def test_teams_cards_are_the_same_adaptive_card(shell_payloads):
    shell = shell_payloads["teams"]["attachments"][0]["content"]
    python = notify.teams_payload(RECORD)["attachments"][0]["content"]

    assert shell["type"] == python["type"] == "AdaptiveCard"
    assert shell["version"] == python["version"]

    def facts(card: dict) -> set[str]:
        return {
            fact["title"]
            for block in card["body"]
            if block["type"] == "FactSet"
            for fact in block["facts"]
        }

    shared = {"Target", "Mode", "Version", "Commit", "Actor", "Verified"}
    assert shared <= facts(shell)
    assert shared <= facts(python)


def test_both_use_the_same_status_emoji(shell_payloads):
    # `ensure_ascii=False`: json.dumps escapes the emoji to \u2705 by default, so the naive
    # assertion passes vacuously against an escaped string it never finds.
    for payload in (shell_payloads["slack"], notify.slack_payload(RECORD)):
        assert notify._EMOJI["success"] in json.dumps(payload, ensure_ascii=False)
