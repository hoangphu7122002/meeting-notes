.DEFAULT_GOAL := help
.PHONY: help install install-shared deps dev lint lint-arch test test-e2e build-app previews ci clean
DIR ?= docs/screenshots

help: ## List targets
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

install: ## One-pass setup (idempotent): prerequisites, uv sync, models, app. ARGS=--dry-run|--yes|--force
	scripts/install.sh $(ARGS)

install-shared: ## Install for every account: /Applications + /Users/Shared/MeetingNotes. ARGS=--dry-run|--yes|--force
	scripts/install.sh --shared $(ARGS)

deps: ## Sync pipeline (uv) and resolve Swift packages
	cd pipeline && uv sync
	cd app && swift package resolve

dev: deps ## deps + swift build + doctor --offline (never launches the app)
	cd app && swift build
	cd pipeline && uv run meeting-notes doctor --offline

lint: lint-arch ## Architecture checks + app build
	cd app && swift build

lint-arch: ## Python (pytest AST) + Swift (grep) architecture rules
	cd pipeline && uv run pytest tests/architecture -q
	scripts/check-swift-arch.sh

test: ## Pipeline pytest (no e2e) + swift test
	cd pipeline && uv run pytest -q --ignore=tests/e2e
	cd app && swift test

test-e2e: ## Pipeline end-to-end tests
	cd pipeline && uv run pytest tests/e2e -q

build-app: ## Build, sign and install ~/Applications/MeetingNotes.app (+ diarization helper)
	scripts/build-app.sh

previews: ## Render UI previews to PNG (DIR=docs/screenshots)
	cd app && swift run MeetingNotesPreviews $(abspath $(DIR))

ci: lint test ## lint + test

clean: ## Remove build outputs (never models/)
	rm -rf build app/.build
	find pipeline -name __pycache__ -type d -prune -exec rm -rf {} +
	find pipeline \( -name '*.pyc' -o -name '*.pyo' \) -type f -delete
