"""Notification payloads, and the rule that a sink failure is never an exception."""

from __future__ import annotations

import json
import urllib.error

import pytest

from tremvok import notify
from tremvok.models import DeploymentRecord

RECORD = DeploymentRecord(
    repository="MagmaMoose/website",
    recorded_at="2026-08-18T09:00:00.000Z",
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


def test_slack_payload_has_a_fallback_text():
    # Without `text` the push notification and the screen-reader rendering are both empty.
    payload = notify.slack_payload(RECORD)
    assert "MagmaMoose/website" in payload["text"]
    assert payload["blocks"][0]["text"]["type"] == "mrkdwn"


def test_slack_payload_never_exceeds_the_ten_field_limit():
    payload = notify.slack_payload(RECORD)
    for block in payload["blocks"]:
        assert len(block.get("fields", [])) <= 10


def test_slack_payload_escapes_mrkdwn_control_characters():
    record = RECORD.model_copy(update={"version": "1.0.0 <script>&"})
    body = json.dumps(notify.slack_payload(record))
    assert "&lt;script&gt;&amp;" in body
    assert "<script>" not in body


def test_teams_payload_is_an_adaptive_card():
    payload = notify.teams_payload(RECORD)
    content = payload["attachments"][0]["content"]
    assert content["type"] == "AdaptiveCard"
    # Repository and environment are the heading, not fact rows — see `_facts`.
    assert RECORD.environment in content["body"][0]["text"]
    assert any(fact["title"] == "Mode" for fact in content["body"][1]["facts"])


def test_a_sink_outage_is_a_false_not_an_exception(monkeypatch):
    def explode(*_args, **_kwargs):
        raise urllib.error.URLError("slack is down")

    monkeypatch.setattr(notify.urllib.request, "urlopen", explode)
    assert notify.post_webhook("https://hooks.slack.test/x", {"text": "hi"}) is False


def test_non_https_webhooks_are_refused():
    assert notify.post_webhook("http://hooks.slack.test/x", {}) is False
    assert notify.post_webhook("file:///etc/passwd", {}) is False


def test_fan_out_omits_unconfigured_sinks(monkeypatch):
    monkeypatch.setattr(notify, "post_webhook", lambda *_a, **_k: True)
    assert notify.fan_out(RECORD, slack_url="https://x.test/a") == {"slack": True}
    assert notify.fan_out(RECORD) == {}


@pytest.mark.parametrize(
    ("policy", "status", "expected"),
    [
        ("always", "success", True),
        ("always", "failure", True),
        ("on-success", "success", True),
        ("on-success", "failure", False),
        ("on-failure", "failure", True),
        ("on-failure", "rolled-back", True),
        ("on-failure", "success", False),
    ],
)
def test_notify_policy(policy, status, expected):
    assert notify.should_notify(policy, status) is expected
