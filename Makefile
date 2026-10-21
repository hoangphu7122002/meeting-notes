.DEFAULT_GOAL := help
.PHONY: help install deps dev lint lint-arch test test-e2e build-app previews ci clean
DIR ?= docs/screenshots

help: ## List targets
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

install: ## First-time setup: brew deps, uv sync, models, build and install the app
	scripts/install.sh

deps: ## Sync pipeline (uv) and resolve Swift packages
	cd pipeline && uv sync
	cd app && swift package resolve

dev: deps ## deps + swift build + doctor --offline (never launches the app)
	cd app && swift build
	cd pipeline && uv run meeting-notes doctor --offline

lint: lint-arch ## Architecture checks + app build
	cd app && swift build

# Needs pipeline/tests/architecture (planned, lands with WP-A).
lint-arch: ## Python (pytest AST) + Swift (grep) architecture rules
	cd pipeline && uv run pytest tests/architecture -q
	scripts/check-swift-arch.sh

test: ## Pipeline pytest (no e2e) + swift test
	cd pipeline && uv run pytest -q --ignore=tests/e2e
	cd app && swift test

test-e2e: ## Pipeline end-to-end tests
	cd pipeline && uv run pytest tests/e2e -q

build-app: ## Build, sign and install ~/Applications/MeetingNotes.app
	scripts/build-app.sh

previews: ## Render UI previews to PNG (DIR=docs/screenshots)
	cd app && swift run MeetingNotesPreviews $(abspath $(DIR))

ci: lint test ## lint + test

clean: ## Remove build outputs (never models/)
	rm -rf build app/.build
	find pipeline -name __pycache__ -type d -prune -exec rm -rf {} +
