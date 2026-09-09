#!/usr/bin/env python3
"""Drive the whole stack against LocalStack and assert what must be true.

Unit tests prove the code; this proves the **wiring**. Every failure it catches is one no unit
test can see: a Lambda package built for the wrong architecture, an IAM policy that forgot
`kms:Decrypt`, a DynamoDB schema that does not match the keys the code writes, an environment
variable Terraform spells differently from `settings.py`.

It also runs the action's own deploy scripts against a real (emulated) S3 and Lambda, so the
scripts are exercised against the API they actually call rather than against a stub.

    make -C terraform smoke        # after `make up` and `make apply-local`
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess  # nosec B404
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import boto3
from boto3.dynamodb.conditions import Key
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

ROOT = Path(__file__).resolve().parents[2]
ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")  # DevSkim: ignore DS162092
REGION = os.environ.get("AWS_DEFAULT_REGION", "eu-west-1")
PARAMETER_PREFIX = "/tremvok/local"
ISSUER = "https://token.actions.githubusercontent.com"
AUDIENCE = "tremvok"
KID = "tremvok-localstack"

PASSED: list[str] = []
FAILED: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        PASSED.append(name)
        print(f"  ok    {name}")
    else:
        FAILED.append(name)
        print(f"  FAIL  {name}{f' — {detail}' if detail else ''}")


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def request(
    method: str, url: str, *, token: str | None = None, body: dict | None = None
) -> tuple[int, dict]:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"content-type": "application/json"}
    if token:
        headers["authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)  # noqa: S310  # nosec B310
    try:
        # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected  # noqa: E501
        with urllib.request.urlopen(req, timeout=60) as response:  # noqa: S310  # nosec B310
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, json.loads(raw or b"{}")
        except ValueError:
            return exc.code, {"raw": raw.decode(errors="replace")}


def main() -> int:
    outputs = json.loads(Path(sys.argv[1]).read_text())
    api_url = outputs["api_url"]["value"].rstrip("/")
    table_name = outputs["table_name"]["value"]
    function_name = outputs["function_name"]["value"]
    site_bucket = outputs["site_bucket"]["value"]
    artifact_bucket = outputs["artifact_bucket"]["value"]

    ssm = boto3.client("ssm", endpoint_url=ENDPOINT, region_name=REGION)
    dynamodb = boto3.resource("dynamodb", endpoint_url=ENDPOINT, region_name=REGION)
    s3 = boto3.client("s3", endpoint_url=ENDPOINT, region_name=REGION)
    lambda_client = boto3.client("lambda", endpoint_url=ENDPOINT, region_name=REGION)

    # ── an issuer the function can actually reach ────────────────────────────────────────
    # There is no GitHub here, so the harness *is* the issuer: it publishes its public key as a
    # pinned JWKS document, which is the same mechanism a GitHub Enterprise Server deployment
    # behind an egress-restricted network uses.
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    numbers = key.public_key().public_numbers()
    jwks = {
        "keys": [
            {
                "kty": "RSA",
                "kid": KID,
                "alg": "RS256",
                "use": "sig",
                "n": b64url(numbers.n.to_bytes((numbers.n.bit_length() + 7) // 8, "big")),
                "e": b64url(numbers.e.to_bytes((numbers.e.bit_length() + 7) // 8, "big")),
            }
        ]
    }
    ssm.put_parameter(
        Name=f"{PARAMETER_PREFIX}/jwks-document",
        Value=json.dumps(jwks),
        Type="SecureString",
        Overwrite=True,
    )

    def token(
        repository: str = "MagmaMoose/website",
        *,
        audience: str = AUDIENCE,
        expires_in: int = 600,
        valid_signature: bool = True,
    ) -> str:
        now = int(time.time())
        header = {"alg": "RS256", "kid": KID, "typ": "JWT"}
        claims = {
            "iss": ISSUER,
            "aud": audience,
            "exp": now + expires_in,
            "iat": now,
            "nbf": now,
            "repository": repository,
            "repository_owner": repository.split("/", 1)[0],
        }
        head = b64url(json.dumps(header, separators=(",", ":")).encode())
        body = b64url(json.dumps(claims, separators=(",", ":")).encode())
        signing_input = f"{head}.{body}".encode()
        signature = (
            key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
            if valid_signature
            else b"\x00" * 256
        )
        return f"{head}.{body}.{b64url(signature)}"

    print("\nThe API")
    # The single most valuable assertion in this file. A 200 here means the package imported —
    # which means the compiled `pydantic-core` wheel matches the function's architecture, the
    # handler path Terraform declares exists, and the role can write its own logs.
    status, body = request("GET", f"{api_url}/healthz")
    check(
        "healthz answers 200 (the package imports on this architecture)",
        status == 200,
        f"status={status} body={body}",
    )
    check("healthz identifies the service", body.get("service") == "tremvok", str(body))

    status, _ = request("POST", f"{api_url}/v1/deployments", body={"delivery_id": "x"})
    check("an unauthenticated write is refused", status == 401, f"status={status}")

    status, _ = request(
        "POST",
        f"{api_url}/v1/deployments",
        token=token(valid_signature=False),
        body={"delivery_id": "x"},
    )
    check("a forged signature is refused", status == 401, f"status={status}")

    status, _ = request(
        "POST",
        f"{api_url}/v1/deployments",
        token=token(audience="sigstore"),
        body={"delivery_id": "x"},
    )
    check("a token for another audience is refused", status == 401, f"status={status}")

    # Deny-by-default is the property that matters most: GitHub issues an OIDC token to every
    # repository on github.com, so this is the only thing standing between the table and all
    # of them.
    status, _ = request(
        "POST",
        f"{api_url}/v1/deployments",
        token=token("attacker/evil"),
        body=_payload("smoke-foreign"),
    )
    check("a repository outside the allowlist is refused", status == 403, f"status={status}")

    delivery = f"smoke-{int(time.time())}"
    status, recorded = request(
        "POST", f"{api_url}/v1/deployments", token=token(), body=_payload(delivery)
    )
    check(
        "a valid deployment is recorded",
        status == 200 and not recorded.get("duplicate"),
        f"status={status} body={recorded}",
    )
    check(
        "the repository comes from the token, not the body",
        recorded.get("repository") == "MagmaMoose/website",
        str(recorded),
    )

    # The seeded webhook URL is deliberately unresolvable, so this asserts the failure is
    # isolated: the sink was attempted, it failed, and the request still succeeded.
    check(
        "a failing notification sink does not fail the request",
        recorded.get("notified", {}).get("slack") is False,
        str(recorded.get("notified")),
    )

    status, again = request(
        "POST", f"{api_url}/v1/deployments", token=token(), body=_payload(delivery)
    )
    check(
        "a retry of the same delivery is a duplicate, not a second record",
        status == 200 and again.get("duplicate") is True,
        f"status={status} body={again}",
    )

    status, listed = request("GET", f"{api_url}/v1/deployments?limit=50", token=token())
    ours = [d for d in listed.get("deployments", []) if d.get("delivery_id") == delivery]
    check(
        "the deployment appears in history exactly once",
        status == 200 and len(ours) == 1,
        f"status={status} matches={len(ours)}",
    )

    status, other = request("GET", f"{api_url}/v1/deployments", token=token("MagmaMoose/dunmir"))
    check(
        "a repository cannot read another's history",
        status == 200 and other.get("count") == 0,
        str(other),
    )

    status, _ = request(
        "POST",
        f"{api_url}/v1/deployments",
        token=token(),
        body={**_payload("smoke-js"), "url": "javascript:alert(1)"},
    )
    check(
        "a javascript: URL is rejected before it reaches a chat card",
        status == 422,
        f"status={status}",
    )

    print("\nStorage")
    table = dynamodb.Table(table_name)
    items = table.query(KeyConditionExpression=Key("pk").eq("repo#MagmaMoose/website"))["Items"]
    check("records land in the repository's partition", bool(items), "no items")
    check(
        "every item carries a TTL, so history cannot grow forever",
        all("expires_at" in item for item in items),
    )
    ddb = boto3.client("dynamodb", endpoint_url=ENDPOINT, region_name=REGION)
    description = ddb.describe_table(TableName=table_name)["Table"]
    # Asserted on the throughput numbers rather than on BillingModeSummary, which a provisioned
    # table may omit entirely — a check that reads a missing field and defaults to "correct"
    # cannot fail, which is worse than not checking at all.
    throughput = description.get("ProvisionedThroughput", {})
    check(
        "the table is provisioned, so it cannot scale itself into a bill",
        throughput.get("ReadCapacityUnits") == 2 and throughput.get("WriteCapacityUnits") == 2,
        str(throughput),
    )
    check(
        "the TTL attribute Terraform declares is the one the code writes",
        ddb.describe_time_to_live(TableName=table_name)
        .get("TimeToLiveDescription", {})
        .get("AttributeName")
        == "expires_at",
    )

    print("\nThe action's S3 target, against a real bucket")
    site = ROOT / "dist" / "smoke-site"
    site.mkdir(parents=True, exist_ok=True)
    (site / "index.html").write_text("<!doctype html><title>smoke</title>")
    (site / "app.deadbeef.css").write_text("body{}")

    code = _run_script(
        "deploy-s3-cloudfront.sh",
        BUCKET=site_bucket,
        ARTIFACT_PATH=str(site),
        MODE="preview",
        PREVIEW_ALIAS="pr-1",
        SITE_URL="https://example.invalid",
    )
    check("a preview syncs to S3", code == 0, f"exit={code}")
    keys = {o["Key"] for o in s3.list_objects_v2(Bucket=site_bucket).get("Contents", [])}
    check(
        "the preview landed under its own prefix",
        "previews/pr-1/index.html" in keys,
        str(sorted(keys)),
    )
    html = s3.head_object(Bucket=site_bucket, Key="previews/pr-1/index.html")
    css = s3.head_object(Bucket=site_bucket, Key="previews/pr-1/app.deadbeef.css")
    check(
        "documents are revalidated, assets are immutable",
        "must-revalidate" in html.get("CacheControl", "")
        and "immutable" in css.get("CacheControl", ""),
        f"html={html.get('CacheControl')} css={css.get('CacheControl')}",
    )

    empty = ROOT / "dist" / "smoke-empty"
    shutil.rmtree(empty, ignore_errors=True)
    empty.mkdir(parents=True)
    code = _run_script(
        "deploy-s3-cloudfront.sh", BUCKET=site_bucket, ARTIFACT_PATH=str(empty), MODE="deploy"
    )
    # The guard that matters: a build that quietly produced nothing, followed by
    # `aws s3 sync --delete`, empties the live site and exits 0 while doing it.
    check("an empty build refuses to sync rather than emptying the site", code != 0, f"exit={code}")

    print("\nThe action's Lambda target, against a real function")
    package = ROOT / "dist" / "tremvok-api.zip"
    code = _run_script(
        "deploy-lambda-zip.sh",
        FUNCTION_NAME=function_name,
        ARTIFACT_PATH=str(package),
        ARTIFACT_BUCKET=artifact_bucket,
        KEY_PREFIX="smoke",
        VERSION_LABEL="1.0.0",
        MODE="preview",
    )
    check("a preview publishes a Lambda version", code == 0, f"exit={code}")
    versions = lambda_client.list_versions_by_function(FunctionName=function_name)["Versions"]
    check("more than $LATEST now exists", len(versions) > 1, str(len(versions)))
    aliases = lambda_client.list_aliases(FunctionName=function_name).get("Aliases", [])
    check("a preview did not move the live alias", not aliases, str(aliases))

    # Same key, different bytes: this must be refused rather than silently swapping the code
    # behind a version somebody already reviewed.
    tampered = ROOT / "dist" / "tampered.zip"
    tampered.write_bytes(package.read_bytes() + b"\x00")
    code = _run_script(
        "deploy-lambda-zip.sh",
        FUNCTION_NAME=function_name,
        ARTIFACT_PATH=str(tampered),
        ARTIFACT_BUCKET=artifact_bucket,
        KEY_PREFIX="smoke",
        VERSION_LABEL="1.0.0",
        MODE="deploy",
    )
    check("a published key is immutable", code != 0, f"exit={code}")

    code = _run_script(
        "deploy-lambda-zip.sh",
        FUNCTION_NAME=function_name,
        ARTIFACT_PATH=str(package),
        ARTIFACT_BUCKET=artifact_bucket,
        KEY_PREFIX="smoke",
        VERSION_LABEL="1.0.1",
        MODE="deploy",
    )
    check("a deploy moves the alias", code == 0, f"exit={code}")
    aliases = lambda_client.list_aliases(FunctionName=function_name).get("Aliases", [])
    check("the live alias now exists", any(a["Name"] == "live" for a in aliases), str(aliases))

    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    if FAILED:
        print("failed: " + ", ".join(FAILED))
    return 1 if FAILED else 0


def _payload(delivery_id: str) -> dict:
    return {
        "delivery_id": delivery_id,
        "environment": "local",
        "status": "success",
        "target": "s3-cloudfront",
        "mode": "deploy",
        "version": "0.1.0",
        "url": "https://example.invalid/",
        "commit": "0123456789abcdef",
        "verified": True,
    }


def _run_script(name: str, **env: str) -> int:
    """Run one of the action's scripts against LocalStack, with a scratch GITHUB_OUTPUT."""
    environment = {
        **os.environ,
        "AWS_ENDPOINT_URL": ENDPOINT,
        "AWS_DEFAULT_REGION": REGION,
        "AWS_ACCESS_KEY_ID": os.environ.get("AWS_ACCESS_KEY_ID", "test"),
        "AWS_SECRET_ACCESS_KEY": os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
        "GITHUB_OUTPUT": str(ROOT / "dist" / "smoke-outputs.txt"),
        **env,
    }
    result = subprocess.run(  # noqa: S603  # nosec B603 B607
        ["bash", str(ROOT / "scripts" / name)],  # noqa: S607  # nosec B607
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        print(f"    ({name} exited {result.returncode}: {result.stdout.strip()[-300:]})")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
