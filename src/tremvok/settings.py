"""Configuration, and where each value is allowed to come from.

Two rules the rest of the service depends on:

**Secrets are SSM Parameter Store `SecureString`, never Lambda environment variables.** An
environment variable is plaintext to anyone holding `lambda:GetFunctionConfiguration`, which is
a much wider blast radius than it looks. Parameter Store gives KMS-at-rest and an IAM-scoped
read for nothing — Secrets Manager's $0.40/secret/month buys rotation, and a Slack incoming
webhook rotates approximately never.

**Everything else is an environment variable**, because Terraform sets it and a wrong value
should be visible in a plan diff rather than hidden in a parameter nobody diffs.
"""

from __future__ import annotations

import functools
import os
from dataclasses import dataclass, field

DEFAULT_AUDIENCE = "tremvok"
DEFAULT_RETENTION_DAYS = 90


def _env_list(name: str) -> tuple[str, ...]:
    raw = os.environ.get(name, "")
    return tuple(item.strip() for item in raw.split(",") if item.strip())


@dataclass(frozen=True)
class Settings:
    table_name: str = ""
    parameter_prefix: str = ""
    audience: str = DEFAULT_AUDIENCE
    # Deny by default: see `tremvok.oidc.authorize`. Lower-cased here so the comparison there
    # can be a plain set membership rather than a loop.
    allowed_owners: frozenset[str] = field(default_factory=frozenset)
    issuers: tuple[str, ...] = ("https://token.actions.githubusercontent.com",)
    retention_days: int = DEFAULT_RETENTION_DAYS
    # Set by the LocalStack harness; boto3 honours it natively. Never set in production.
    endpoint_url: str | None = None
    history_scan_limit: int = 200

    @classmethod
    def from_env(cls) -> Settings:
        issuers = _env_list("TREMVOK_OIDC_ISSUERS") or (
            "https://token.actions.githubusercontent.com",
        )
        return cls(
            table_name=os.environ.get("TREMVOK_TABLE", ""),
            parameter_prefix=os.environ.get("TREMVOK_PARAMETER_PREFIX", "").rstrip("/"),
            audience=os.environ.get("TREMVOK_OIDC_AUDIENCE", DEFAULT_AUDIENCE),
            allowed_owners=frozenset(o.lower() for o in _env_list("TREMVOK_ALLOWED_OWNERS")),
            issuers=issuers,
            retention_days=int(os.environ.get("TREMVOK_RETENTION_DAYS", DEFAULT_RETENTION_DAYS)),
            endpoint_url=os.environ.get("AWS_ENDPOINT_URL") or None,
        )


@functools.lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings.from_env()


class ParameterStore:
    """Reads `SecureString` parameters once per execution environment.

    Cached because a Lambda container serves many requests and `ssm:GetParameter` is both a
    network round trip on the critical path and a metered API call. A missing parameter caches
    as `None` — a sink that is not configured is the normal case, not an error, and re-asking
    SSM about it on every request would be the expensive way to learn nothing.
    """

    def __init__(self, prefix: str, *, client=None, endpoint_url: str | None = None) -> None:
        self.prefix = prefix.rstrip("/")
        self._client = client
        self._endpoint_url = endpoint_url
        self._cache: dict[str, str | None] = {}

    @property
    def client(self):
        if self._client is None:
            import boto3  # imported lazily: the FastAPI tests never touch SSM

            self._client = boto3.client("ssm", endpoint_url=self._endpoint_url)
        return self._client

    def get(self, name: str) -> str | None:
        if not self.prefix:
            return None
        if name in self._cache:
            return self._cache[name]
        try:
            response = self.client.get_parameter(Name=f"{self.prefix}/{name}", WithDecryption=True)
            value: str | None = response["Parameter"]["Value"] or None
        except Exception:  # noqa: BLE001 - ParameterNotFound and friends are all "not set"
            value = None
        self._cache[name] = value
        return value

    def invalidate(self) -> None:
        self._cache.clear()
