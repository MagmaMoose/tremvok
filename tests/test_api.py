"""The HTTP surface, end to end, with DynamoDB mocked and no network anywhere."""

from __future__ import annotations

import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws

from tremvok.api.app import create_app
from tremvok.settings import ParameterStore, Settings
from tremvok.store import DeploymentStore

from .conftest import TEST_AUDIENCE, TEST_ISSUER

TABLE = "tremvok-deployments-api-test"

BODY = {
    "delivery_id": "run-9:1:prod:deploy",
    "environment": "prod",
    "status": "success",
    "target": "s3-cloudfront",
    "mode": "deploy",
    "version": "2.0.0",
    "url": "https://magmamoose.com/",
    "commit": "deadbeefdeadbeef",
    "run_url": "https://github.com/MagmaMoose/website/actions/runs/9",
    "verified": True,
}


class FakeParameters(ParameterStore):
    """A ParameterStore with values baked in — no SSM, no boto3, no network."""

    def __init__(self, values: dict[str, str | None]):
        super().__init__("/tremvok/test")
        self._cache = dict(values)

    def get(self, name: str) -> str | None:
        return self._cache.get(name)


@pytest.fixture
def sent():
    return []


@pytest.fixture
def client(jwks, monkeypatch, sent):
    from tremvok import notify

    monkeypatch.setattr(
        notify, "post_webhook", lambda url, payload, **_k: sent.append((url, payload)) is None
    )
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name="eu-west-1")
        dynamodb.create_table(
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
        settings = Settings(
            table_name=TABLE,
            audience=TEST_AUDIENCE,
            allowed_owners=frozenset({"magmamoose"}),
            issuers=(TEST_ISSUER,),
        )
        app = create_app(
            settings,
            store=DeploymentStore(TABLE, table=dynamodb.Table(TABLE)),
            parameters=FakeParameters({"slack-webhook": "https://hooks.slack.test/x"}),
            jwks=jwks,
        )
        yield TestClient(app)


def auth(token: str) -> dict[str, str]:
    return {"authorization": f"Bearer {token}"}


def test_healthz_needs_no_token(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_recording_a_deployment_notifies_once(client, make_token, sent):
    response = client.post("/v1/deployments", json=BODY, headers=auth(make_token()))
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["repository"] == "MagmaMoose/website"
    assert body["duplicate"] is False
    assert body["notified"] == {"slack": True}
    assert len(sent) == 1


def test_a_retry_is_a_duplicate_and_does_not_notify_again(client, make_token, sent):
    client.post("/v1/deployments", json=BODY, headers=auth(make_token()))
    response = client.post("/v1/deployments", json=BODY, headers=auth(make_token()))

    # 200, not 409: the caller retried a notify step, which is correct behaviour, and failing
    # it would turn a successful deploy red.
    assert response.status_code == 200
    assert response.json()["duplicate"] is True
    assert len(sent) == 1


def test_the_repository_comes_from_the_token_not_the_body(client, make_token):
    # The body cannot carry `repository`; `extra: forbid` makes the attempt a 422 rather than
    # a silently ignored field.
    response = client.post(
        "/v1/deployments",
        json={**BODY, "repository": "someone-else/repo"},
        headers=auth(make_token()),
    )
    assert response.status_code == 422

    client.post("/v1/deployments", json=BODY, headers=auth(make_token(repository="MagmaMoose/x")))
    listed = client.get("/v1/deployments", headers=auth(make_token(repository="MagmaMoose/x")))
    assert listed.json()["repository"] == "MagmaMoose/x"
    assert listed.json()["count"] == 1


def test_a_repository_only_reads_its_own_history(client, make_token):
    client.post("/v1/deployments", json=BODY, headers=auth(make_token()))
    other = client.get("/v1/deployments", headers=auth(make_token(repository="MagmaMoose/other")))
    assert other.json()["count"] == 0


def test_a_foreign_owner_is_refused(client, make_token):
    response = client.post(
        "/v1/deployments", json=BODY, headers=auth(make_token(repository="attacker/evil"))
    )
    assert response.status_code == 403


def test_no_token_is_a_401(client):
    assert client.post("/v1/deployments", json=BODY).status_code == 401


def test_a_forged_token_is_a_401(client, make_token):
    assert (
        client.post("/v1/deployments", json=BODY, headers=auth(make_token(sign=False))).status_code
        == 401
    )


def test_a_javascript_url_is_refused(client, make_token):
    # The record is rendered as a link in Slack and Teams; a `javascript:` URL there is a
    # phishing primitive, and the field is populated from workflow inputs.
    response = client.post(
        "/v1/deployments",
        json={**BODY, "url": "javascript:alert(1)"},
        headers=auth(make_token()),
    )
    assert response.status_code == 422


def test_an_unknown_status_is_refused(client, make_token):
    response = client.post(
        "/v1/deployments", json={**BODY, "status": "probably-fine"}, headers=auth(make_token())
    )
    assert response.status_code == 422


def test_history_is_filterable_and_bounded(client, make_token):
    for index in range(3):
        client.post(
            "/v1/deployments",
            json={**BODY, "delivery_id": f"run-{index}", "environment": "preview"},
            headers=auth(make_token()),
        )
    listed = client.get("/v1/deployments?environment=preview&limit=2", headers=auth(make_token()))
    assert listed.json()["count"] == 2
    assert client.get("/v1/deployments?limit=0", headers=auth(make_token())).status_code == 422


def test_there_is_no_public_schema_browser(client):
    assert client.get("/docs").status_code == 404
    assert client.get("/openapi.json").status_code == 404
