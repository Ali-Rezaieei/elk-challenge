# ---------------------------------------------------------------------------
# Thin Makefile: every target shells out to scripts/ so a reviewer can read one
# file to understand a step. Standalone: `cd cloud && make deploy` works without
# the launcher. The API token comes from HCLOUD_TOKEN (or the gitignored .env).
# ---------------------------------------------------------------------------
SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help
.PHONY: help preflight deploy verify idempotency destroy reset lint logs

help: ## Show this help.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

preflight: ## Validate token, project, quota, keys - before any billable call.
	@./scripts/preflight.sh

deploy: ## Full deploy: preflight -> terraform -> ansible -> verify.
	@./scripts/deploy.sh

verify: ## Functional + security tests (incl. round trip) against the live server.
	@./scripts/verify.sh

idempotency: ## Re-run Ansible; asserts a second run reports changed=0.
	@./scripts/deploy.sh --idempotency-check

destroy: ## Tear everything down and prove the project is empty.
	@./scripts/destroy.sh

reset: ## Destroy + purge local certs/secrets/inventory/state for a true cold start.
	@./scripts/destroy.sh --purge-generated

lint: ## Static analysis: terraform fmt/validate, ansible-lint, shellcheck, yamllint.
	@./scripts/lint.sh

logs: ## Tail recent service logs from the server over SSH.
	@./scripts/logs.sh
