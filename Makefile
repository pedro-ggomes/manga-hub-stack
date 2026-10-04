# Run `make` (or `make help`) to list targets.
-include .env
export

COMPOSE    := docker compose
DBMATE     := $(COMPOSE) run --rm --user $(shell id -u):$(shell id -g) dbmate
TEST_DB    := manga_test
TEST_URL   := postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@db:5432/$(TEST_DB)?sslmode=disable
DBMATE_T   := $(COMPOSE) run --rm -e DATABASE_URL=$(TEST_URL) dbmate --no-dump-schema
# postgrest-test holds connections to the test DB; stop it before dropping
DROP_TEST  := $(COMPOSE) --profile test rm -sf postgrest-test && $(DBMATE_T) drop
PSQL       := $(COMPOSE) exec -T db psql -v ON_ERROR_STOP=1 -U $(POSTGRES_USER)
MIGRATIONS := $(wildcard db/migrations/*.sql)
BASE       ?= origin/main

.DEFAULT_GOAL := help
.PHONY: help check-env bootstrap up down nuke logs psql migrate rollback migrate-redo new-migration reset \
        configure seed dev test test-db test-api test-web check-migrations check-frozen

help: ## List targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.env:
	sed -e "s/^AUTHENTICATOR_PASSWORD=generate/AUTHENTICATOR_PASSWORD=$$(openssl rand -hex 24)/" \
	    -e "s/^JWT_SECRET=generate/JWT_SECRET=$$(openssl rand -hex 32)/" .env.example > .env

check-env: .env ## Fail if .env is missing keys that .env.example defines
	@missing=$$(grep -oE '^[A-Z_]+=' .env.example | while read k; do grep -q "^$$k" .env || echo "$${k%=}"; done); \
	if [ -n "$$missing" ]; then echo ".env is missing: $$missing (copy them from .env.example; 'generate' values: openssl rand -hex 32)"; exit 1; fi

bootstrap: up migrate configure seed ## First run: start, migrate, configure, seed
	$(COMPOSE) restart postgrest

# --- stack -------------------------------------------------------------------
up: check-env ## Build and start the stack (waits for the DB; the API retries until configured)
	$(COMPOSE) up -d --build --wait db
	$(COMPOSE) up -d

down: ## Stop the stack (keeps data)
	$(COMPOSE) down

nuke: ## Stop the stack and delete the database volume
	$(COMPOSE) down -v

logs: ## Follow logs
	$(COMPOSE) logs -f

psql: ## Open psql on the app database
	$(COMPOSE) exec db psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

frontend/node_modules: frontend/package-lock.json
	cd frontend && npm ci --no-fund
	@touch $@

dev: frontend/node_modules ## Run the web app on http://localhost:5173 (needs make up)
	cd frontend && npm run dev

# --- migrations --------------------------------------------------------------
migrate: ## Apply pending migrations, dump db/schema.sql, reload the API schema cache
	$(DBMATE) up
	$(PSQL) -d $(POSTGRES_DB) -qc "NOTIFY pgrst, 'reload schema'"

rollback: ## Roll back the latest migration
	$(DBMATE) rollback
	$(PSQL) -d $(POSTGRES_DB) -qc "NOTIFY pgrst, 'reload schema'"

migrate-redo: rollback migrate ## Re-run the latest migration (unmerged, down unchanged; else make reset)

new-migration: ## Create a migration: make new-migration name=create_manga
	@test -n "$(name)" || (echo "usage: make new-migration name=<slug>" && exit 1)
	$(DBMATE) new $(name)

configure: ## Apply env settings (authenticator password, JWT secret): make configure [DB=name]
	$(COMPOSE) exec -T -e AUTHENTICATOR_PASSWORD -e JWT_SECRET -e JWT_TTL db \
		psql -v ON_ERROR_STOP=1 -1 -q -U $(POSTGRES_USER) -d $(or $(DB),$(POSTGRES_DB)) -f /src/db/configure.sql

seed: ## Load the dev seed (idempotent)
	$(COMPOSE) exec -T -e DEMO_PASSWORD db psql -v ON_ERROR_STOP=1 -1 -q -U $(POSTGRES_USER) -d $(POSTGRES_DB) -f /src/db/seed.sql

reset: ## Drop and rebuild the app database from migrations, then seed
	$(COMPOSE) rm -sf postgrest
	$(DBMATE) drop
	$(DBMATE) up
	$(MAKE) configure seed
	$(COMPOSE) up -d postgrest

# --- eval gate ---------------------------------------------------------------
test: check-migrations test-db test-api test-web ## Run the full eval gate

test-web: frontend/node_modules ## Frontend typecheck + component tests
	cd frontend && npm run typecheck && npm test

test-db: ## Rebuild the test DB from migrations and run pgTAP tests
	$(DROP_TEST)
	$(DBMATE_T) $(if $(MIGRATIONS),up,create)
	@# pgTAP in its own schema: tests run assertions as the API roles, and public stays clean
	$(PSQL) -d $(TEST_DB) -qc 'CREATE SCHEMA tap; CREATE EXTENSION pgtap SCHEMA tap; GRANT USAGE ON SCHEMA tap TO PUBLIC; GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA tap TO PUBLIC; ALTER DATABASE $(TEST_DB) SET search_path = public, extensions, tap'
	$(COMPOSE) exec -T db sh -c 'pg_prove -U $(POSTGRES_USER) -d $(TEST_DB) /src/db/tests/*.sql'

test-api: ## HTTP contract + concurrency tests against a PostgREST on the test DB
	$(MAKE) configure DB=$(TEST_DB)
	$(COMPOSE) --profile test up -d --force-recreate postgrest-test
	API_URL=http://127.0.0.1:$(API_TEST_PORT) node --test --test-concurrency=1 'tests/api/*.test.ts'

check-migrations: ## Every migration must apply, roll back fully, and re-apply
ifneq ($(MIGRATIONS),)
	$(DROP_TEST)
	$(DBMATE_T) up
	@for _ in $(MIGRATIONS); do $(DBMATE_T) rollback || exit 1; done
	$(DBMATE_T) up
else
	@echo "no migrations yet"
endif

check-frozen: ## Fail if this branch changed a migration that is already on main
	@changed=$$(git diff --name-only --diff-filter=MDR $(BASE)...HEAD -- 'db/migrations/*.sql') || exit 1; \
	if [ -n "$$changed" ]; then \
		echo "Migrations merged to main are frozen; add a new migration instead:"; \
		echo "$$changed"; exit 1; \
	fi; echo "no frozen migrations touched"
