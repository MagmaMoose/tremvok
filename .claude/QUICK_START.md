# Quick start (most-run commands)

**Action surface (repo root):**
```bash
shellcheck -S warning scripts/*.sh scripts/lib/*.sh   # lint
bats tests/bats                                        # 88 shell tests
python3 -c 'import yaml; yaml.safe_load(open("action.yml"))'   # action metadata parses
git update-index --chmod=+x scripts/<file>.sh          # mark a new script executable
```

**API surface:**
```bash
uv sync --all-groups
uv run pytest -q            # 63 tests, no network, no AWS
uv run ruff check .         # E,F,I,UP,B,SIM,RUF,S,BLE
uv run ruff format .
uv run mypy src
python3 scripts/build_api_zip.py --arch arm64    # -> dist/tremvok-api.zip + sha256
```

**Infrastructure:**
```bash
make -C terraform validate     # tofu validate the module
make -C terraform dev          # LocalStack: up + build + apply + smoke
make -C terraform serve        # uvicorn against LocalStack, fast inner loop
make -C terraform down         # stop and discard
```

**Docs:**
```bash
uv run --group docs mkdocs serve    # preview at :8000
```
