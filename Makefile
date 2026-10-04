# Run `make` (or `make help`) to list targets.
-include .env
export

COMPOSE    := docker compose
DBMATE     := $(COMPOSE) run --rm --user $(shell id -u):$(shell id -g) dbmate
TEST_DB    := manga_test
TEST_URL   := postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@db:5432/$(TEST_DB)?sslmode=disable
DBMATE_T   := $(COMPOSE) run --rm -e DATABASE_URL=$(TEST_URL) dbmate --no-dump-schema
PSQL       := $(COMPOSE) exec -T db psql -v ON_ERROR_STOP=1 -U $(POSTGRES_USER)
MIGRATIONS := $(wildcard db/migrations/*.sql)
BASE       ?= origin/main

.DEFAULT_GOAL := help
.PHONY: help up down nuke logs psql migrate rollback migrate-redo new-migration reset \
        test test-db check-migrations check-frozen

help: ## List targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.env:
	cp .env.example .env

# --- stack -------------------------------------------------------------------
up: .env ## Build and start the stack, wait until healthy
	$(COMPOSE) up -d --build --wait

down: ## Stop the stack (keeps data)
	$(COMPOSE) down

nuke: ## Stop the stack and delete the database volume
	$(COMPOSE) down -v

logs: ## Follow logs
	$(COMPOSE) logs -f

psql: ## Open psql on the app database
	$(COMPOSE) exec db psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

# --- migrations --------------------------------------------------------------
migrate: ## Apply pending migrations and dump db/schema.sql
	$(DBMATE) up

rollback: ## Roll back the latest migration
	$(DBMATE) rollback

migrate-redo: rollback migrate ## Re-run the latest migration (for editing unmerged ones)

new-migration: ## Create a migration: make new-migration name=create_manga
	@test -n "$(name)" || (echo "usage: make new-migration name=<slug>" && exit 1)
	$(DBMATE) new $(name)

reset: ## Drop and rebuild the app database from migrations
	$(DBMATE) drop
	$(DBMATE) up

# --- eval gate ---------------------------------------------------------------
test: check-migrations test-db ## Run the full eval gate

test-db: ## Rebuild the test DB from migrations and run pgTAP tests
	$(DBMATE_T) drop
	$(DBMATE_T) $(if $(MIGRATIONS),up,create)
	$(PSQL) -d $(TEST_DB) -qc 'CREATE EXTENSION IF NOT EXISTS pgtap'
	$(COMPOSE) exec -T db sh -c 'pg_prove -U $(POSTGRES_USER) -d $(TEST_DB) /db/tests/*.sql'

check-migrations: ## Every migration must apply, roll back fully, and re-apply
ifneq ($(MIGRATIONS),)
	$(DBMATE_T) drop
	$(DBMATE_T) up
	@for _ in $(MIGRATIONS); do $(DBMATE_T) rollback || exit 1; done
	$(DBMATE_T) up
else
	@echo "no migrations yet"
endif

check-frozen: ## Fail if this branch changed a migration that is already on main
	@changed=$$(git diff --name-only --diff-filter=MDR $(BASE)...HEAD -- db/migrations) || exit 1; \
	if [ -n "$$changed" ]; then \
		echo "Migrations merged to main are frozen; add a new migration instead:"; \
		echo "$$changed"; exit 1; \
	fi; echo "no frozen migrations touched"
