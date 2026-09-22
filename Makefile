APP      ?= Om
PREFIX   ?= $(HOME)/Applications
BUILD    ?= build
CONFIG   ?= release
VERSION  := $(shell git describe --tags --always --dirty 2>/dev/null || echo 0.0.0)

.DEFAULT_GOAL := help
.PHONY: help build test lint app install uninstall run cli release clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk -F':.*?## ' '{printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  version $(VERSION), installs into $(PREFIX)"

build: ## Compile everything in release configuration
	swift build -c $(CONFIG)

test: ## Run the test suite
	swift test

lint: ## Check formatting without changing anything
	@command -v swift-format >/dev/null 2>&1 \
		&& swift-format lint --recursive Sources Tests \
		|| echo "swift-format not installed; skipping"

app: build ## Build the .app bundle into build/
	@CONFIGURATION=$(CONFIG) APP_NAME=$(APP) BUILD_DIR=$(BUILD) sh scripts/bundle.sh

install: app ## Copy the bundle into the install prefix
	@mkdir -p "$(PREFIX)"
	@rm -rf "$(PREFIX)/$(APP).app"
	@cp -R "$(BUILD)/$(APP).app" "$(PREFIX)/$(APP).app"
	@echo "installed $(PREFIX)/$(APP).app ($(VERSION))"

uninstall: ## Remove the installed application
	@rm -rf "$(PREFIX)/$(APP).app"
	@echo "removed $(PREFIX)/$(APP).app"

run: install ## Install and launch
	@open "$(PREFIX)/$(APP).app"

cli: build ## Print where the om command-line tool was built
	@echo "$$(swift build -c $(CONFIG) --show-bin-path)/om"

release: test app ## Test, build and package a versioned zip
	@cd $(BUILD) && zip -qry "$(APP)-$(VERSION).zip" "$(APP).app"
	@echo "$(BUILD)/$(APP)-$(VERSION).zip"

clean: ## Remove build products
	@rm -rf .build $(BUILD)
