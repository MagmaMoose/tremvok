"""Deployment history in DynamoDB, and the idempotency that makes notifications exactly-once.

One table, one partition per repository, sorted by time. Two item shapes share it:

    pk = repo#<owner>/<name>   sk = dep#<recorded_at>#<deployment_id>   the record
    pk = repo#<owner>/<name>   sk = dedup#<delivery_id>                 the idempotency token

The dedup token is written **first**, conditionally. A second POST carrying the same
`delivery_id` — a retried notify step, a re-run of the same job attempt — fails that condition
and returns without writing a record or sending a notification. If the record write then
fails, the token is deleted again, so the retry that follows is treated as the first attempt
rather than silently swallowed. Losing a record because its own dedup token survived it would
be the one failure this design must not have.

Capacity is **provisioned, not on-demand**, and deliberately tiny. On-demand cannot be capped,
so a runaway caller turns a free table into a bill; provisioned throttles instead, and a
throttled deployment record is a retry, not an outage.
"""

from __future__ import annotations

import logging
import time
import uuid

from .models import DeploymentIn, DeploymentRecord

log = logging.getLogger("tremvok.store")

_DEDUP = "dedup#"
_RECORD = "dep#"


def new_deployment_id() -> str:
    """A short, sortable-enough opaque id. Not a security boundary — the dedup token is."""
    return uuid.uuid4().hex[:16]


class DeploymentStore:
    def __init__(
        self,
        table_name: str,
        *,
        retention_days: int = 90,
        history_scan_limit: int = 200,
        table=None,
        endpoint_url: str | None = None,
    ) -> None:
        self.table_name = table_name
        self.retention_days = retention_days
        self.history_scan_limit = history_scan_limit
        self._table = table
        self._endpoint_url = endpoint_url

    @property
    def table(self):
        if self._table is None:
            import boto3  # lazy: importing this module must not require an AWS SDK

            self._table = boto3.resource("dynamodb", endpoint_url=self._endpoint_url).Table(
                self.table_name
            )
        return self._table

    @staticmethod
    def _partition(repository: str) -> str:
        return f"repo#{repository}"

    def _expires_at(self, now: float | None = None) -> int:
        return int((now or time.time()) + self.retention_days * 86_400)

    def claim(self, repository: str, delivery_id: str) -> bool:
        """Take the idempotency token. False means somebody already has it."""
        from botocore.exceptions import ClientError

        try:
            self.table.put_item(
                Item={
                    "pk": self._partition(repository),
                    "sk": f"{_DEDUP}{delivery_id}",
                    "expires_at": self._expires_at(),
                },
                ConditionExpression="attribute_not_exists(sk)",
            )
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
                return False
            raise
        return True

    def release(self, repository: str, delivery_id: str) -> None:
        """Give the token back. Best-effort: a failure here costs one duplicate at worst."""
        try:
            self.table.delete_item(
                Key={"pk": self._partition(repository), "sk": f"{_DEDUP}{delivery_id}"}
            )
        except Exception:  # compensation: this must never be the reason a request fails
            # Logged rather than swallowed: a stuck token means the next retry of this
            # delivery is reported as a duplicate and its record is lost, and the only place
            # that would ever be visible is this line in CloudWatch.
            log.warning("store.release_failed", exc_info=True)

    def put(self, record: DeploymentRecord) -> None:
        item = {
            "pk": self._partition(record.repository),
            "sk": f"{_RECORD}{record.recorded_at}#{record.deployment_id}",
            "expires_at": self._expires_at(),
            # Nones are stripped rather than stored as NULL: an absent attribute reads back as
            # a missing key, which the model already defaults, and it keeps item size down.
            **{k: v for k, v in record.model_dump().items() if v is not None},
        }
        self.table.put_item(Item=item)

    def record(
        self, payload: DeploymentIn, *, repository: str
    ) -> tuple[DeploymentRecord | None, bool]:
        """Store a deployment. Returns (record, is_duplicate); a duplicate stores nothing."""
        if not self.claim(repository, payload.delivery_id):
            return None, True
        record = DeploymentRecord.build(
            payload, repository=repository, deployment_id=new_deployment_id()
        )
        try:
            self.put(record)
        except Exception:
            self.release(repository, payload.delivery_id)
            raise
        return record, False

    def history(
        self, repository: str, *, environment: str | None = None, limit: int = 20
    ) -> list[DeploymentRecord]:
        """Most recent deployments first.

        `environment` is filtered in Python rather than with a DynamoDB FilterExpression
        because a FilterExpression is applied *after* `Limit`: asking for 20 production
        deployments would return however many of the last 20 rows happened to be production,
        which reads as "we stopped deploying" whenever a preview run is busy. One partition
        query with a bounded scan window is both correct and, at a handful of deployments a
        day, a single read unit.
        """
        from boto3.dynamodb.conditions import Key

        response = self.table.query(
            KeyConditionExpression=Key("pk").eq(self._partition(repository))
            & Key("sk").begins_with(_RECORD),
            ScanIndexForward=False,
            Limit=self.history_scan_limit,
        )

        seen: set[str] = set()
        out: list[DeploymentRecord] = []
        for item in response.get("Items", []):
            if environment and item.get("environment") != environment:
                continue
            # A record written before its dedup token was released (see `record`) can leave a
            # second row for one delivery. Collapse them here so history never double-counts.
            delivery_id = str(item.get("delivery_id", ""))
            if delivery_id and delivery_id in seen:
                continue
            seen.add(delivery_id)
            out.append(
                DeploymentRecord.model_validate(
                    {
                        k: (int(v) if k == "duration_ms" and v is not None else v)
                        for k, v in item.items()
                        if k not in ("pk", "sk", "expires_at")
                    }
                )
            )
            if len(out) >= limit:
                break
        return out
