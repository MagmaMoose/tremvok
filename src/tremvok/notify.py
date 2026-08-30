"""Human-channel notifications, and the rule that they can never fail a deployment.

Every function here returns a bool and swallows its own errors. A Slack outage must not turn a
successful production deploy red — the deploy already happened, and failing the job would
invite a re-run that deploys again to fix a chat message. This is Diatreme's visibility-first
rule for its security sinks, applied to the same class of problem.

The payloads are plain `urllib` POSTs rather than an SDK. Both sinks are one unauthenticated
webhook URL and a JSON body, so a dependency here would buy nothing and cost a wheel in the
Lambda package.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request

from .models import DeploymentRecord

_TIMEOUT_SECONDS = 6

_EMOJI = {
    "success": "✅",
    "failure": "❌",
    "skipped": "⏭️",
    "rolled-back": "⏪",
}


def _mrkdwn_escape(value: str) -> str:
    """Slack mrkdwn is not Markdown; `&`, `<` and `>` are the only characters it eats."""
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _facts(record: DeploymentRecord) -> list[tuple[str, str]]:
    """The fact rows, in the order both notifiers show them.

    Deliberately the same set and order as `scripts/notify-webhook.sh`, which posts the same two
    cards when the API is not in use. `tests/test_notify_parity.py` asserts they agree — the two
    implementations existing at all is the duplication this project exists to end, and it is
    only acceptable while something checks. **Mode** used to be missing here, so a card from the
    API could not tell a deploy from a rollback while one from the runner could.

    Repository and Environment are not rows: both notifiers put them in the headline, and
    repeating them costs two of Slack's ten permitted fields.
    """
    facts = [
        ("Status", record.status),
        ("Target", record.target),
        ("Mode", record.mode),
    ]
    facts.append(("Version", record.version or "—"))
    facts.append(("Commit", record.commit[:12] if record.commit else "—"))
    facts.append(("Actor", record.actor or "—"))
    facts.append(("Verified", "true" if record.verified else "false"))
    return facts


def slack_payload(record: DeploymentRecord) -> dict:
    emoji = _EMOJI.get(record.status, "•")
    headline = (
        f"{emoji} *{_mrkdwn_escape(record.repository)}* → "
        f"*{_mrkdwn_escape(record.environment)}* — {record.status}"
    )
    fields = [
        {"type": "mrkdwn", "text": f"*{label}*\n{_mrkdwn_escape(value)}"}
        for label, value in _facts(record)
    ]
    blocks: list[dict] = [
        {"type": "section", "text": {"type": "mrkdwn", "text": headline}},
        # Slack rejects a section with more than 10 fields with a 400, which the
        # failure-isolated caller would log as an unexplained false. Slice rather than trust
        # that `_facts` never grows.
        {"type": "section", "fields": fields[:10]},
    ]
    links = []
    if record.url:
        links.append(f"<{record.url}|Open the deployment>")
    if record.run_url:
        links.append(f"<{record.run_url}|Workflow run>")
    if links:
        blocks.append(
            {"type": "context", "elements": [{"type": "mrkdwn", "text": " · ".join(links)}]}
        )
    # `text` is the notification/fallback string: without it the push notification and the
    # accessibility reading of the message are both empty.
    return {
        "text": f"{record.repository} → {record.environment}: {record.status}",
        "blocks": blocks,
    }


def teams_payload(record: DeploymentRecord) -> dict:
    """An Adaptive Card in the `message`/`attachments` envelope Workflows and connectors take."""
    actions = []
    if record.url:
        actions.append({"type": "Action.OpenUrl", "title": "Open deployment", "url": record.url})
    if record.run_url:
        actions.append({"type": "Action.OpenUrl", "title": "Workflow run", "url": record.run_url})
    return {
        "type": "message",
        "attachments": [
            {
                "contentType": "application/vnd.microsoft.card.adaptive",
                "content": {
                    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",  # DevSkim: ignore DS137138 - Adaptive Cards schema URI requires http://  # noqa: E501
                    "type": "AdaptiveCard",
                    "version": "1.4",
                    "body": [
                        {
                            "type": "TextBlock",
                            "text": (
                                f"{_EMOJI.get(record.status, '•')} {record.repository} → "
                                f"{record.environment}"
                            ),
                            "style": "heading",
                            "wrap": True,
                        },
                        {
                            "type": "FactSet",
                            "facts": [
                                {"title": label, "value": value} for label, value in _facts(record)
                            ],
                        },
                    ],
                    "actions": actions,
                },
            }
        ],
    }


def post_webhook(url: str, payload: dict, *, timeout: int = _TIMEOUT_SECONDS) -> bool:
    """POST JSON to a webhook. Returns success; never raises, never logs the URL."""
    if not url or not url.startswith("https://"):
        return False
    body = json.dumps(payload).encode("utf-8")
    # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
    request = urllib.request.Request(  # noqa: S310  # nosec B310 - https enforced above
        url,
        data=body,
        headers={"content-type": "application/json", "user-agent": "tremvok"},
        method="POST",
    )
    try:
        # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310  # nosec B310
            return 200 <= response.status < 300
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return False


def fan_out(
    record: DeploymentRecord, *, slack_url: str | None = None, teams_url: str | None = None
) -> dict[str, bool]:
    """Send to every configured sink. An unconfigured sink is absent, not False."""
    results: dict[str, bool] = {}
    if slack_url:
        results["slack"] = post_webhook(slack_url, slack_payload(record))
    if teams_url:
        results["teams"] = post_webhook(teams_url, teams_payload(record))
    return results


def should_notify(policy: str, status: str) -> bool:
    """`always` | `on-success` | `on-failure`, evaluated the same way everywhere."""
    if policy == "on-success":
        return status == "success"
    if policy == "on-failure":
        return status in ("failure", "rolled-back")
    return True
