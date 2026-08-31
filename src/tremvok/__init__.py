"""Tremvok — deployment orchestration and notifications for MagmaMoose.

Deliberately empty of imports. `scripts/build_api_zip.py` packages this tree for Lambda and
`tests/test_oidc.py` imports `tremvok.oidc` on its own; a top-level import here would drag
FastAPI into both. Keep it a docstring and a version.
"""

__version__ = "0.1.0"
