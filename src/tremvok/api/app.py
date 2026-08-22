"""The Tremvok HTTP API.

Three endpoints and no session state, so it runs identically as a Lambda behind an HTTP API,
as a container on the firefly cluster, or as `uvicorn` on a laptop pointed at LocalStack.

    GET  /healthz                 liveness; no auth, no storage read
    POST /v1/deployments          record one deployment attempt and notify humans
    GET  /v1/deployments          the calling repository's history

**Authentication is a GitHub Actions OIDC token and nothing else.** There is no API key to
distribute, and the `repository` a record lands under is the token's claim rather than a field
in the body — so the interesting attack ("record a rollback against someone else's repo") is
not expressible, not merely rejected. See `tremvok.oidc`.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request

from .. import __version__
from ..models import DeploymentAccepted, DeploymentIn, DeploymentPage
from ..notify import fan_out
from ..oidc import JwksCache, OidcError, authorize, verify_token
from ..settings import ParameterStore, Settings, get_settings
from ..store import DeploymentStore


def caller_repository(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> str:
    """Verify the bearer OIDC token and return the repository it belongs to.

    Module level, not a closure inside `create_app`, and that is load-bearing. This file uses
    `from __future__ import annotations`, so every annotation is a string that FastAPI resolves
    against the function's *module* globals — a dependency defined inside `create_app` is not
    there, the `Annotated[str, Depends(...)]` fails to resolve, and FastAPI silently falls back
    to treating `repository` as a required **query parameter**. The symptom is every
    authenticated route answering `422 {"loc": ["query", "repository"]}` instead of running the
    dependency at all: an auth check that vanishes rather than fails.

    Collaborators therefore come off `request.app.state`, which `create_app` populates.
    """
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    state = request.app.state
    try:
        claims = verify_token(
            token,
            audience=state.settings.audience,
            jwks=state.jwks,
            issuers=tuple(state.settings.issuers),
        )
        return authorize(claims, state.settings.allowed_owners)
    except OidcError as exc:
        # 403 rather than 401 for an authorization failure: the token was fine, the caller is
        # not ours, and a 401 would send the action into a pointless token refresh.
        status = 403 if "not allowed" in str(exc) else 401
        raise HTTPException(status_code=status, detail=str(exc)) from exc


def create_app(
    settings: Settings | None = None,
    *,
    store: DeploymentStore | None = None,
    parameters: ParameterStore | None = None,
    jwks: JwksCache | None = None,
) -> FastAPI:
    """Build the app. Every collaborator is injectable so the tests need no AWS and no network."""
    resolved = settings or get_settings()

    app = FastAPI(
        title="Tremvok",
        version=__version__,
        description="Deployment records and human-channel notifications for MagmaMoose.",
        docs_url=None,  # nothing here is worth a public schema browser
        redoc_url=None,
        openapi_url=None,
    )
    app.state.settings = resolved
    app.state.store = store or DeploymentStore(
        resolved.table_name,
        retention_days=resolved.retention_days,
        history_scan_limit=resolved.history_scan_limit,
        endpoint_url=resolved.endpoint_url,
    )
    app.state.parameters = parameters or ParameterStore(
        resolved.parameter_prefix, endpoint_url=resolved.endpoint_url
    )
    # The JWKS loader reads a pinned document from Parameter Store, lazily and only on a `kid`
    # the cache does not already hold — so a deployment that does not pin one never calls SSM
    # for it, and a cold start is not slowed by a parameter that is usually absent.
    app.state.jwks = jwks or JwksCache(
        resolved.issuers[0],
        loader=lambda: app.state.parameters.get("jwks-document"),
    )

    @app.get("/healthz")
    def healthz() -> dict:
        # Deliberately does not touch DynamoDB. A health check that reads storage turns a
        # throttled table into an unhealthy service, and this endpoint's only job is to say
        # the function is warm and the package imported.
        return {"status": "ok", "service": "tremvok", "version": __version__}

    @app.post("/v1/deployments", response_model=DeploymentAccepted)
    def record_deployment(
        payload: DeploymentIn,
        request: Request,
        repository: Annotated[str, Depends(caller_repository)],
    ) -> DeploymentAccepted:
        state = request.app.state
        record, duplicate = state.store.record(payload, repository=repository)

        if duplicate or record is None:
            # 200, not 409. The caller did nothing wrong — it retried, which is exactly what a
            # notify step should do — and a 4xx here would fail a job whose deploy succeeded.
            return DeploymentAccepted(
                deployment_id="",
                repository=repository,
                recorded_at="",
                duplicate=True,
                notified={},
            )

        notified = fan_out(
            record,
            slack_url=state.parameters.get("slack-webhook"),
            teams_url=state.parameters.get("teams-webhook"),
        )
        return DeploymentAccepted(
            deployment_id=record.deployment_id,
            repository=record.repository,
            recorded_at=record.recorded_at,
            duplicate=False,
            notified=notified,
        )

    @app.get("/v1/deployments", response_model=DeploymentPage)
    def list_deployments(
        request: Request,
        repository: Annotated[str, Depends(caller_repository)],
        environment: Annotated[str | None, Query(max_length=100)] = None,
        limit: Annotated[int, Query(ge=1, le=100)] = 20,
    ) -> DeploymentPage:
        # No `repository` query parameter on purpose: you read your own history. Cross-repo
        # reads are a dashboard feature and want a different credential than a workflow token.
        deployments = request.app.state.store.history(
            repository, environment=environment, limit=limit
        )
        return DeploymentPage(
            repository=repository, count=len(deployments), deployments=deployments
        )

    return app
