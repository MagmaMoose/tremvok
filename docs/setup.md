# Setting Tremvok up

## 1. An IAM role the workflow can assume

Tremvok authenticates to AWS with this run's GitHub OIDC token. Nothing is stored in the
repository. The role's trust policy is what decides who may use it — scope it to the repository
**and** the refs that may deploy:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike": { "token.actions.githubusercontent.com:sub": "repo:MagmaMoose/website:ref:refs/heads/main" }
  }
}
```

`StringLike` on `sub` with a `ref:` prefix, not `repo:owner/name:*`. The wildcard form lets a
pull request from a branch in the same repository assume a production deploy role.

Grant it only what the target needs — for `s3-cloudfront` that is `s3:PutObject`,
`s3:DeleteObject`, `s3:ListBucket` on the one bucket, and
`cloudfront:CreateInvalidation` on the one distribution.

## 2. The workflow

Copy the example from the [action reference](action.md) into `.github/workflows/deploy.yml` and
set the four repository variables it reads. Nothing else is required — the API is optional.

## 3. (Optional) The Tremvok API

Only needed for deployment history, or for notifications that do not put a webhook URL in every
repository.

Deploying it is described in
[terraform/README.md](https://github.com/MagmaMoose/tremvok/blob/main/terraform/README.md);
the short version is that the module needs an artifact bucket, two SSM parameters written by
hand, and `allowed_owners` set to the GitHub owners you actually control.

Then add to the action:

```yaml
with:
  api-url: https://<api-id>.execute-api.eu-west-1.amazonaws.com
```

and `permissions: id-token: write`. The repository stores nothing.

## 4. Verify it, properly

After the first deploy of any new wiring:

```bash
curl -si https://your-site/ | head -1        # the site answers
```

and for the API, a **real signed POST**, not a `GET /healthz`. A health check passing proves the
function imported; it proves nothing at all about the write path, the table, or the IAM policy.
The LocalStack smoke suite exists to make that distinction cheap to test.
