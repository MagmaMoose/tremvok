"""Storage and, mostly, idempotency — the property that keeps Slack from double-pinging."""

from __future__ import annotations

import boto3
import pytest
from moto import mock_aws

from tremvok.models import DeploymentIn
from tremvok.store import DeploymentStore

TABLE = "tremvok-deployments-test"


def _payload(delivery_id: str = "run-1:1:prod:deploy", **overrides) -> DeploymentIn:
    base = {
        "delivery_id": delivery_id,
        "environment": "prod",
        "status": "success",
        "target": "s3-cloudfront",
        "mode": "deploy",
        "version": "1.4.0",
        "url": "https://magmamoose.com/",
        "commit": "0123456789abcdef",
    }
    base.update(overrides)
    return DeploymentIn(**base)


@pytest.fixture
def store():
    with mock_aws():
        client = boto3.client("dynamodb", region_name="eu-west-1")
        client.create_table(
            TableName=TABLE,
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            ProvisionedThroughput={"ReadCapacityUnits": 2, "WriteCapacityUnits": 2},
        )
        yield DeploymentStore(
            TABLE, table=boto3.resource("dynamodb", region_name="eu-west-1").Table(TABLE)
        )


def test_a_deployment_is_recorded_and_readable(store):
    record, duplicate = store.record(_payload(), repository="MagmaMoose/website")
    assert duplicate is False
    assert record is not None

    history = store.history("MagmaMoose/website")
    assert [item.deployment_id for item in history] == [record.deployment_id]
    assert history[0].version == "1.4.0"


def test_the_same_delivery_id_is_recorded_once(store):
    first, duplicate_first = store.record(_payload(), repository="MagmaMoose/website")
    second, duplicate_second = store.record(_payload(), repository="MagmaMoose/website")

    assert (duplicate_first, duplicate_second) == (False, True)
    assert second is None
    assert len(store.history("MagmaMoose/website")) == 1
    assert first is not None


def test_a_different_delivery_id_is_a_new_deployment(store):
    store.record(_payload("run-1:1:prod:deploy"), repository="MagmaMoose/website")
    store.record(_payload("run-2:1:prod:deploy"), repository="MagmaMoose/website")
    assert len(store.history("MagmaMoose/website")) == 2


def test_a_failed_write_releases_the_idempotency_token(store, monkeypatch):
    # The failure this guards: token taken, record write throws, and every retry afterwards is
    # dismissed as a duplicate — so the deployment is never recorded at all.
    def explode(_record):
        raise RuntimeError("dynamodb said no")

    monkeypatch.setattr(store, "put", explode)
    with pytest.raises(RuntimeError):
        store.record(_payload(), repository="MagmaMoose/website")

    monkeypatch.undo()
    record, duplicate = store.record(_payload(), repository="MagmaMoose/website")
    assert duplicate is False
    assert record is not None


def test_repositories_do_not_see_each_other(store):
    store.record(_payload("a"), repository="MagmaMoose/website")
    store.record(_payload("b"), repository="MagmaMoose/dunmir")
    assert len(store.history("MagmaMoose/website")) == 1
    assert len(store.history("MagmaMoose/dunmir")) == 1


def test_history_is_newest_first_and_limited(store):
    for index in range(5):
        store.record(_payload(f"run-{index}", version=f"1.0.{index}"), repository="r/r")
    history = store.history("r/r", limit=3)
    assert [item.version for item in history] == ["1.0.4", "1.0.3", "1.0.2"]


def test_history_filters_by_environment(store):
    store.record(_payload("a", environment="prod"), repository="r/r")
    store.record(_payload("b", environment="preview"), repository="r/r")
    assert [item.environment for item in store.history("r/r", environment="preview")] == ["preview"]


def test_records_carry_a_ttl_so_history_cannot_grow_forever(store):
    store.record(_payload(), repository="r/r")
    items = store.table.scan()["Items"]
    assert items, "expected the record and its dedup token"
    assert all("expires_at" in item for item in items)
