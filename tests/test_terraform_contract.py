"""The contract between the Terraform module and the code it configures.

These two files are edited by different people at different times, and nothing connects them:
`terraform/modules/tremvok-api/lambda.tf` sets environment variables, and
`src/tremvok/settings.py` reads them. A name spelled differently on either side produces a
function that starts, answers `/healthz` with a cheerful 200, and then behaves as though it were
never configured — an empty owner allowlist denies every caller, an empty table name fails on
the first write.

The LocalStack harness catches this by standing the whole thing up. These tests catch it without
Docker, which matters on a machine or a runner that has none.
"""

from __future__ import annotations

import pathlib
import re

MODULE = pathlib.Path(__file__).resolve().parents[1] / "terraform" / "modules" / "tremvok-api"
SETTINGS = pathlib.Path(__file__).resolve().parents[1] / "src" / "tremvok" / "settings.py"

LAMBDA_TF = (MODULE / "lambda.tf").read_text()
SETTINGS_SRC = SETTINGS.read_text()

# Read by the code but deliberately not set by Terraform, each for a stated reason.
NOT_SET_BY_TERRAFORM = {
    # Defaults to github.com's issuer; only a GitHub Enterprise Server deployment overrides it.
    "TREMVOK_OIDC_ISSUERS",
    # Set only by the LocalStack harness. Setting it in production would point the SDK at
    # something that is not AWS.
    "AWS_ENDPOINT_URL",
}


def terraform_variables() -> set[str]:
    block = LAMBDA_TF[LAMBDA_TF.index("environment {") : LAMBDA_TF.index("depends_on")]
    return set(re.findall(r"^\s*(TREMVOK_[A-Z_]+)\s*=", block, re.MULTILINE))


def settings_variables() -> set[str]:
    return set(re.findall(r'"(TREMVOK_[A-Z_]+|AWS_ENDPOINT_URL)"', SETTINGS_SRC))


def test_terraform_sets_nothing_the_code_does_not_read():
    """A variable set and never read is dead configuration that looks live in a plan diff."""
    unread = terraform_variables() - settings_variables()
    assert not unread, f"lambda.tf sets {sorted(unread)}, which settings.py never reads"


def test_the_code_reads_nothing_terraform_forgets_to_set():
    unset = settings_variables() - terraform_variables() - NOT_SET_BY_TERRAFORM
    assert not unset, (
        f"settings.py reads {sorted(unset)}, which lambda.tf never sets — the function will "
        "start and behave as though it were never configured"
    )


def test_the_handler_terraform_names_is_the_one_that_exists():
    handler = re.search(r'handler\s*=\s*"([^"]+)"', LAMBDA_TF)
    assert handler, "lambda.tf declares no handler"
    module_path, _, attribute = handler.group(1).rpartition(".")

    target = (
        pathlib.Path(__file__).resolve().parents[1]
        / "src"
        / (module_path.replace(".", "/") + ".py")
    )
    assert target.is_file(), f"lambda.tf points at {module_path}, which does not exist"
    assert re.search(rf"^{attribute}\s*=", target.read_text(), re.MULTILINE), (
        f"{module_path} defines no {attribute!r}"
    )


def test_the_iam_policy_covers_every_aws_call_the_code_makes():
    """Least privilege cuts both ways: a missing action is a 500 nobody sees until production."""
    policy = (MODULE / "iam.tf").read_text()
    source = "\n".join(p.read_text() for p in (SETTINGS.parent).rglob("*.py"))

    required = {
        ".put_item(": "dynamodb:PutItem",
        ".delete_item(": "dynamodb:DeleteItem",
        ".query(": "dynamodb:Query",
        ".get_parameter(": "ssm:GetParameter",
    }
    for call, action in required.items():
        if call in source:
            assert action in policy, f"the code calls {call} but the role lacks {action}"


def test_secure_string_parameters_can_actually_be_decrypted():
    # ssm:GetParameter with WithDecryption=True on a SecureString needs kms:Decrypt. Without it
    # the call succeeds and returns ciphertext, which reads as "the webhook is not configured"
    # rather than as a permissions error — a silent failure, not a loud one.
    policy = (MODULE / "iam.tf").read_text()
    assert "WithDecryption=True" in SETTINGS_SRC
    assert "kms:Decrypt" in policy


def test_the_capacity_and_retention_caps_are_present():
    """The cost ceiling. AWS has no spend cap, so these are the controls that actually hold."""
    storage = (MODULE / "storage.tf").read_text()
    assert 'billing_mode   = "PROVISIONED"' in storage, "on-demand capacity cannot be capped"
    assert 'attribute_name = "expires_at"' in storage
    assert "enabled        = true" in storage

    variables = (MODULE / "variables.tf").read_text()
    assert "reserved_concurrency" in variables
    assert "throttle_rate_limit" in variables
    assert "log_retention_days" in variables
    assert "reserved_concurrent_executions" in LAMBDA_TF
