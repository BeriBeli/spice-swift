# SwiftSpice — thin task runner over Scripts/. Run `make` for the target list.
# Scripts remain the source of truth; this file only provides short entry points.

MODULE_CACHE_DIR := $(CURDIR)/.build/module-cache
CLANG_MODULE_CACHE_PATH ?= $(MODULE_CACHE_DIR)
SWIFTPM_MODULECACHE_OVERRIDE ?= $(MODULE_CACHE_DIR)
export CLANG_MODULE_CACHE_PATH SWIFTPM_MODULECACHE_OVERRIDE

.DEFAULT_GOAL := help

.PHONY: help prepare doctor build debug test test-public-api protocol analyze sanitize coverage audit all release check-version clean distclean

help: ## Show this help
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_-]+:.*## /{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

prepare:
	@mkdir -p "$(MODULE_CACHE_DIR)"

doctor: ## Check Xcode, Swift, SDK, Metal, and native artifacts
	@./Scripts/doctor.sh

build: ## Build the SwiftSpice library for Apple Silicon
	@./Scripts/build-lib.sh

debug: ## Build and run the SpiceViewer integration client
	@./Scripts/debug-run.sh $(ARGS)

test: prepare ## Run the SwiftSpice test suite
	@swift test --disable-sandbox \
		-Xswiftc -warnings-as-errors

test-public-api: prepare ## Compile the standalone public API consumer
	@swift build --disable-sandbox \
		--package-path Tests/PublicAPIConsumer \
		-Xswiftc -warnings-as-errors

protocol: prepare ## Verify generated protocol sources are current
	@swift package --allow-writing-to-package-directory generate-spice-protocol --check

analyze: ## Run security-focused static analysis on owned C shims
	@./Scripts/analyze-c-shims.sh

sanitize: prepare ## Run the complete test suite with AddressSanitizer
	@./Scripts/test-address-sanitizer.sh

coverage: prepare ## Enforce the production-source line coverage baseline
	@./Scripts/check-code-coverage.sh

audit: ## Verify checked-in native dependencies are arm64 and relocatable
	@./Scripts/verify-native-closure.sh --artifacts-only

all: ## Run environment, metadata, generation, build, API, and test gates
	@$(MAKE) doctor
	@$(MAKE) check-version
	@$(MAKE) protocol
	@$(MAKE) analyze
	@$(MAKE) build
	@$(MAKE) test-public-api
	@$(MAKE) test
	@$(MAKE) sanitize
	@$(MAKE) coverage

release: ## Cut a release: make release VERSION=0.1.11
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=X.Y.Z"; exit 1; }
	@./Scripts/release.sh $(VERSION)

check-version: ## Assert VERSION, CHANGELOG, and an optional TAG agree
	@./Scripts/check-version.sh $(TAG)

clean: ## Remove SwiftPM build products
	@swift package clean

distclean: clean ## Also remove generated SwiftPM state
	@rm -rf .build/ .swiftpm/ Tests/PublicAPIConsumer/.build/ Tests/PublicAPIConsumer/.swiftpm/
	@echo "removed generated SwiftPM state"
