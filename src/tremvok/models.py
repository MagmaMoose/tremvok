"""The wire contract for a deployment record.

`repository` is deliberately absent from the request model. It comes from the OIDC token's
`repository` claim, which GitHub asserts and the caller cannot forge — so a workflow in one
repository cannot record (or notify about) a deployment in another. Anything the caller *can*
set is here; anything that must be trusted is not.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator

DeploymentStatus = Literal["success", "failure", "skipped", "rolled-back"]

# The v1 target adapters. Kept as a Literal rather than a free string so a typo in a workflow
# is a 422 with the valid values listed, not a history row nobody can filter on later.
DeploymentTarget = Literal["s3-cloudfront", "lambda-zip", "terragrunt", "other"]


class DeploymentIn(BaseModel):
    """What the action POSTs after a deploy attempt finishes."""

    model_config = {"extra": "forbid"}

    # Idempotency key. The action derives it from the run: `<run_id>:<attempt>:<env>:<mode>`,
    # so re-running a failed *step* inside the same attempt is a duplicate and re-running the
    # whole job is not. It is what stops a retried notify step double-pinging Slack.
    delivery_id: str = Field(min_length=1, max_length=200)

    environment: str = Field(min_length=1, max_length=100)
    status: DeploymentStatus
    target: DeploymentTarget
    mode: str = Field(default="deploy", max_length=40)

    version: str | None = Field(default=None, max_length=200)
    url: str | None = Field(default=None, max_length=2000)
    commit: str | None = Field(default=None, max_length=100)
    run_url: str | None = Field(default=None, max_length=2000)
    actor: str | None = Field(default=None, max_length=100)
    verified: bool = False
    duration_ms: int | None = Field(default=None, ge=0, le=86_400_000)
    detail: str | None = Field(default=None, max_length=2000)

    @field_validator("url", "run_url")
    @classmethod
    def _http_only(cls, value: str | None) -> str | None:
        # A notification body is rendered into Slack and Teams as a link. `javascript:` and
        # `data:` URLs in a chat card are a phishing primitive, and the record is written by a
        # workflow whose own inputs may come from a pull request title.
        if value is None:
            return None
        if not value.startswith(("http://", "https://")):
            raise ValueError("must be an http(s) URL")
        return value


class DeploymentRecord(BaseModel):
    """A stored deployment. `DeploymentIn` plus what the service decides."""

    repository: str
    recorded_at: str
    deployment_id: str
    delivery_id: str
    environment: str
    status: DeploymentStatus
    target: DeploymentTarget
    mode: str
    version: str | None = None
    url: str | None = None
    commit: str | None = None
    run_url: str | None = None
    actor: str | None = None
    verified: bool = False
    duration_ms: int | None = None
    detail: str | None = None

    @classmethod
    def build(
        cls,
        payload: DeploymentIn,
        *,
        repository: str,
        deployment_id: str,
        now: datetime | None = None,
    ) -> DeploymentRecord:
        moment = now or datetime.now(UTC)
        return cls(
            repository=repository,
            recorded_at=moment.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            deployment_id=deployment_id,
            **payload.model_dump(),
        )


class DeploymentAccepted(BaseModel):
    deployment_id: str
    repository: str
    recorded_at: str
    duplicate: bool
    notified: dict[str, bool]


class DeploymentPage(BaseModel):
    repository: str
    count: int
    deployments: list[DeploymentRecord]
