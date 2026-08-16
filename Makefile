# ---------------------------------------------------------------------------
# Thin Makefile: every target is a one-liner that shells out to scripts/.
# The scripts hold the real logic so they remain runnable standalone (and so a
# reviewer can read one file to understand a step instead of decoding Make).
# ---------------------------------------------------------------------------

# Load the project prefix so `make reset` scopes teardown to *our* resources
# only and never touches unrelated Docker objects on the reviewer's machine.
SHELL := /usr/bin/env bash
PROJECT_PREFIX ?= elk-local

.DEFAULT_GOAL := help

.PHONY: help preflight deploy verify idempotency destroy reset lint

help: ## Show this help.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

preflight: ## Validate the environment; fails fast with exact remediation.
	@./scripts/preflight.sh

deploy: ## Full deploy: preflight -> terraform -> ansible -> verify.
	@./scripts/deploy.sh

verify: ## Functional + security smoke tests against a running deployment.
	@./scripts/verify.sh

idempotency: ## Re-run Ansible; asserts a second run reports changed=0.
	@./scripts/deploy.sh --idempotency-check

destroy: ## Tear everything down, including named volumes.
	@./scripts/destroy.sh

reset: ## Destroy + purge generated certs/secrets/inventory for a true cold start.
	@./scripts/destroy.sh --purge-generated

lint: ## Static analysis: terraform fmt/validate, ansible-lint, shellcheck.
	@./scripts/lint.sh
