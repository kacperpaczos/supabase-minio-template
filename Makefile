# Developer shortcuts for the self-hosted Supabase + MinIO stack.
# Run `make help` for the list of targets.

SHELL := /usr/bin/env bash
COMPOSE ?= docker compose
SERVICE ?=

.DEFAULT_GOAL := help

.PHONY: help env up wait down restart status logs psql backup restore smoke urls config pull clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

env: ## Generate .env with fresh random secrets (FORCE=1 to replace an existing one)
	@./scripts/gen-env.sh $(if $(FORCE),--force)

.env:
	@echo "No .env found - run 'make env' first." >&2; exit 1

up: .env ## Start the stack and wait until it is healthy
	$(COMPOSE) up -d
	@./scripts/wait-healthy.sh
	@$(MAKE) --no-print-directory urls

wait: .env ## Wait until all services are healthy
	@./scripts/wait-healthy.sh

down: ## Stop and remove containers (data volumes are kept)
	$(COMPOSE) down

restart: .env ## Restart all services (or SERVICE=name)
	$(COMPOSE) restart $(SERVICE)

status: ## Show container status, health and memory use
	@$(COMPOSE) ps -a
	@ids=$$($(COMPOSE) ps -q); [ -z "$$ids" ] || docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}' $$ids

logs: ## Follow logs (SERVICE=name to filter)
	$(COMPOSE) logs -f --tail=100 $(SERVICE)

psql: .env ## Open psql in the database container
	$(COMPOSE) exec db psql -U postgres -d postgres

backup: .env ## Dump the database and mirror Storage objects into ./backups/<timestamp>/
	@./scripts/backup.sh

restore: .env ## Restore a backup: make restore BACKUP=backups/<timestamp>
	@test -n "$(BACKUP)" || { echo "usage: make restore BACKUP=backups/<timestamp>" >&2; exit 1; }
	@./scripts/restore.sh "$(BACKUP)"

smoke: .env ## Run the end-to-end smoke test against the running stack
	@./scripts/smoke.sh

urls: .env ## Print local endpoints (no secrets)
	@api=$$(sed -n 's/^API_HOST_PORT=//p' .env); db=$$(sed -n 's/^DB_HOST_PORT=//p' .env); \
	mc=$$(sed -n 's/^MINIO_CONSOLE_HOST_PORT=//p' .env); \
	echo "API / SUPABASE_URL : http://127.0.0.1:$$api"; \
	echo "Studio             : http://127.0.0.1:$$api/   (DASHBOARD_USERNAME / DASHBOARD_PASSWORD in .env)"; \
	echo "Postgres           : 127.0.0.1:$$db"; \
	echo "MinIO console      : http://127.0.0.1:$$mc  (MINIO_ROOT_USER / MINIO_ROOT_PASSWORD in .env)"

config: .env ## Validate the compose file with the current .env
	$(COMPOSE) config -q && echo "compose config OK"

pull: .env ## Pull all pinned images
	$(COMPOSE) pull

clean: ## DANGER: stop the stack and delete all data volumes
	@read -r -p "Delete ALL data (database, storage objects)? [y/N] " a; [ "$$a" = y ] || [ "$$a" = Y ] || { echo aborted; exit 1; }
	$(COMPOSE) down -v --remove-orphans
