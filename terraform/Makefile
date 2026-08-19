# Local development for the Tremvok API. Nothing here touches a real AWS account.
#
#   make dev           everything below, in order
#   make up            start LocalStack
#   make api-zip       build the Lambda package with THIS repo's own script
#   make apply-local   build the stack inside LocalStack, as the production leaf builds it
#   make smoke         drive it end to end and assert the invariants
#   make down          stop LocalStack and throw the state away
#
# The package is built by `scripts/build_api_zip.py` — the same script CI publishes with — so a
# local run and a released artifact cannot be built differently.

SHELL := /bin/bash
HERE  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
LS    := $(HERE)localstack
ROOT  := $(HERE)..

export AWS_ACCESS_KEY_ID     ?= test
export AWS_SECRET_ACCESS_KEY ?= test
export AWS_DEFAULT_REGION    ?= eu-west-1
export AWS_ENDPOINT_URL      ?= http://localhost:4566

# The zip and the function must agree, or the function imports a `pydantic_core` built for the
# wrong machine and 500s on the first request. Derived from the host because LocalStack runs
# the Lambda container on it.
ARCH ?= $(shell [ "$$(uname -m)" = "x86_64" ] && echo x86_64 || echo arm64)

# OpenTofu by preference: the stack needs >= 1.9, which rules out the last BUSL-free Terraform
# release (1.5.7), so on a machine with both, tofu is the one that works.
TFBIN ?= $(shell command -v tofu 2>/dev/null || command -v terraform 2>/dev/null)

.PHONY: dev up down api-zip apply-local destroy-local smoke logs fmt validate serve

dev: up api-zip apply-local smoke

up:
	docker compose -f $(LS)/docker-compose.yml up -d
	@echo "waiting for localstack..."
	@for i in $$(seq 1 60); do \
	  curl -sf http://localhost:4566/_localstack/health >/dev/null && exit 0; \
	  sleep 2; \
	done; echo "localstack did not become healthy" >&2; exit 1

down:
	docker compose -f $(LS)/docker-compose.yml down -v

api-zip:
	cd $(ROOT) && python3 scripts/build_api_zip.py --arch $(ARCH)

apply-local:
	cd $(LS) && $(TFBIN) init -input=false
	cd $(LS) && $(TFBIN) apply -auto-approve -input=false \
	  -var api_zip_path=$(abspath $(ROOT)/dist/tremvok-api.zip) \
	  -var architecture=$(ARCH)
	$(LS)/seed.sh

destroy-local:
	cd $(LS) && $(TFBIN) destroy -auto-approve -input=false \
	  -var api_zip_path=$(abspath $(ROOT)/dist/tremvok-api.zip) \
	  -var architecture=$(ARCH)

smoke:
	cd $(LS) && $(TFBIN) output -json > $(LS)/.outputs.json
	cd $(ROOT) && uv run python $(LS)/smoke.py $(LS)/.outputs.json

logs:
	aws --endpoint-url=$(AWS_ENDPOINT_URL) logs tail /aws/lambda/tremvok-api --follow

# The fast inner loop: the same app, in-process, against the same LocalStack. Useful while
# changing a handler; `make dev` is what proves the deployed shape.
serve:
	cd $(ROOT) && TREMVOK_TABLE=tremvok-api TREMVOK_PARAMETER_PREFIX=/tremvok/local \
	  TREMVOK_ALLOWED_OWNERS=MagmaMoose,CalebSargeant \
	  uv run uvicorn --factory tremvok.api.app:create_app --reload --port 8080

fmt:
	$(TFBIN) fmt -recursive $(HERE)

# Validates the MODULE, which is what a real leaf consumes. The localstack root is validated
# implicitly by `apply-local`.
validate:
	@cd $(HERE)modules/tremvok-api \
	  && printf 'provider "aws" { region = "eu-west-1" }\n' > _validate_provider.tf \
	  && $(TFBIN) init -backend=false -input=false >/dev/null \
	  && $(TFBIN) validate; \
	  status=$$?; rm -f _validate_provider.tf; exit $$status
