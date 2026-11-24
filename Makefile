# The command layer of the sandbox. See "Planned command surface" in the
# README.

SHELL := bash
.NOTPARALLEL:

# The configuration file, by default config.yaml: make up CONFIG=<file>.
CONFIG ?= config.yaml
export SANDBOX_CONFIG := $(abspath $(CONFIG))

# The profile, by default scaffold: make up PROFILE=<name> reads
# profiles/<name>.yaml.
PROFILE ?= scaffold
export SANDBOX_PROFILE := $(PROFILE)

REQUIRE_BATS = command -v bats >/dev/null || { echo 'bats-core not found, see "Host requirements" in the README' >&2; exit 1; }

.PHONY: up up-management up-storage up-compute push status down footprint vendor validate test test-validate test-host

up:
	scripts/up.sh

up-management up-storage up-compute:
	scripts/up.sh $(@:up-%=%)

push:
	scripts/push.sh

status:
	scripts/status.sh

down:
	scripts/down.sh

footprint:
	scripts/footprint.sh

vendor:
	scripts/vendor.sh

validate:
	scripts/validate.sh

test:
	@$(REQUIRE_BATS)
	bats tests/unit

test-validate:
	@$(REQUIRE_BATS)
	bats tests/validate

test-host:
	@$(REQUIRE_BATS)
	bats tests/host
