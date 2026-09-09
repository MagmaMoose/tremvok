# Configuration reference

<!-- sources: src/tremvok/settings.py, terraform/modules/tremvok-api/variables.tf -->

The action's inputs live in the [action reference](action-reference.md). This page covers the
other two configuration surfaces: the API's environment variables and the Terraform module's
input variables.

You only need this page if you deploy the optional deployment-record API. The action itself
needs none of it.

## API environment variables

Terraform sets all of these on the Lambda function. Set a wrong value and it shows up in a plan
diff, which is the reason they're environment variables rather than parameters.

| Variable | Type | Default | Required | What it does |
| --- | --- | --- | --- | --- |
| `TREMVOK_TABLE` | string | `""` | yes | DynamoDB table holding deployment records. An empty value makes every write fail. |
| `TREMVOK_ALLOWED_OWNERS` | comma-separated list | `""` | yes | GitHub owners whose tokens may write. Lower-cased on read. **Empty denies everyone**, which is deliberate: `authorize()` is deny-by-default, so a misconfigured deploy records nothing rather than accepting anyone's token. |
| `TREMVOK_PARAMETER_PREFIX` | string | `""` | no | SSM path prefix the notification webhooks are read from. A trailing `/` is stripped. Empty means no sink is configured, which is the normal case, not an error. |
| `TREMVOK_OIDC_AUDIENCE` | string | `tremvok` | no | Audience claim the token must carry. Must match the action's `api-audience` input. |
| `TREMVOK_OIDC_ISSUERS` | comma-separated list | `https://token.actions.githubusercontent.com` | no | Accepted `iss` claims. Add your GitHub Enterprise Server issuer here; setting it replaces the default rather than adding to it. |
| `TREMVOK_RETENTION_DAYS` | integer | `90` | no | How long a record lives. Written as a DynamoDB TTL on `expires_at`, so expiry costs nothing and needs no sweeper. |
| `AWS_ENDPOINT_URL` | string | unset | no | Points boto3 at LocalStack. Set by the local harness, never in production. |

Read once per execution environment and cached, so changing one needs a new deployment, not a
new request.

### Secrets are not here

Slack and Teams webhook URLs are SSM Parameter Store `SecureString` values under
`TREMVOK_PARAMETER_PREFIX`, never environment variables. An environment variable is plaintext to
anyone holding `lambda:GetFunctionConfiguration`, which is a much wider blast radius than it
looks. Parameter Store gives you KMS at rest and an IAM-scoped read for nothing.

!!! warning "Storing a webhook URL with the AWS CLI"
    `aws ssm put-parameter --value https://hooks.slack.example/...` downloads the URL and stores
    its contents. The CLI expands any argument starting with `http://` or `https://` into the
    body of that URL, and the error blames the wrong thing. Use `--cli-input-json`, which isn't
    subject to the expansion on any CLI version. `terraform/localstack/seed.sh` does it that way.

## Terraform module variables

`terraform/modules/tremvok-api` is the whole stack. Defaults are read from
`variables.tf` in this run.

| Variable | Type | Default | What it does |
| --- | --- | --- | --- |
| `name` | string | `tremvok-api` | Name prefix for every resource the module creates. |
| `environment` | string | none | Environment label, required. |
| `region` | string | none | AWS region, required. |
| `artifact_bucket` | string | none | Bucket holding the built Lambda package. |
| `artifact_version` | string | none | Key of the package to deploy. |
| `architecture` | string | `arm64` | Lambda architecture. Must match what `build_api_zip.py --arch` produced. |
| `allowed_owners` | list(string) | `[]` | Sets `TREMVOK_ALLOWED_OWNERS`. Empty denies everyone. |
| `oidc_audience` | string | `tremvok` | Sets `TREMVOK_OIDC_AUDIENCE`. |
| `retention_days` | number | `90` | Sets `TREMVOK_RETENTION_DAYS`. |
| `log_retention_days` | number | `14` | CloudWatch log group retention. |
| `throttle_rate_limit` | number | `2` | API Gateway steady-state requests per second. |
| `throttle_burst_limit` | number | `10` | API Gateway burst capacity. |
| `reserved_concurrency` | number | `5` | Lambda reserved concurrency. |
| `memory_size` | number | `512` | Lambda memory in MB. |
| `timeout` | number | `20` | Lambda timeout in seconds. |
| `parameter_prefix` | string | none | Sets `TREMVOK_PARAMETER_PREFIX`. |
| `alarm_actions` | list(string) | `[]` | SNS topics the CloudWatch alarms notify. Empty means the alarms exist but tell nobody. |
| `localstack` | bool | `false` | Swaps API Gateway for a Lambda Function URL and skips the alarms. Never set this in a real account. |
| `tags` | map(string) | `{}` | Tags applied to every resource. |

!!! warning "The architecture has to match the package"
    `pydantic-core` is a compiled wheel. An arm64 package on an x86_64 function applies cleanly,
    plans green, and then fails on the first request with
    `No module named 'pydantic_core._pydantic_core'`. `build_api_zip.py --arch` and
    `architecture` must agree. The Makefile derives both from `uname -m`.

## The cost ceiling

AWS has no spend cap, and Budgets only report after the fact. Three independent caps hold the
bill down, and any one of them alone would leave a hole:

| Cap | Variable | Default | What it stops |
| --- | --- | --- | --- |
| API Gateway throttle | `throttle_rate_limit`, `throttle_burst_limit` | 2/sec, burst 10 | Request volume, before it reaches Lambda |
| Lambda reserved concurrency | `reserved_concurrency` | 5 | Parallel executions, so a slow dependency can't fan out |
| Provisioned DynamoDB | not configurable | provisioned, not on-demand | On-demand billing turning a free table into a bill. A throttled write is a retry, not an outage. |

Record expiry is a DynamoDB TTL on `expires_at`, so old records cost nothing to remove.

`history_scan_limit` is `200` and isn't configurable. It bounds how many items a history query
reads, because DynamoDB applies a `FilterExpression` *after* `Limit`: asking for 20 production
deployments could otherwise scan the whole partition.
