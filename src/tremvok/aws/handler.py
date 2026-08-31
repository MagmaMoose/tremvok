"""The Lambda entrypoint.

Mangum translates an API Gateway HTTP API (payload format 2.0) or a Lambda Function URL event
into the ASGI call FastAPI expects. Those two event shapes are byte-for-byte identical, which
is what lets the LocalStack harness stand a Function URL in for the gateway it cannot emulate
and still exercise this exact code path.

`lifespan="off"` because there is nothing to start: no connection pool, no background task.
Leaving it on makes every cold start run a startup/shutdown cycle for no work.
"""

from __future__ import annotations

from mangum import Mangum

from ..api.app import create_app

app = create_app()

# The name Terraform sets as `handler = "tremvok.aws.handler.handler"`.
handler = Mangum(app, lifespan="off")
