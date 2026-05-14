ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

.PHONY: all compile docker-compile local-compile \
        test docker-test local-test local-eunit local-ct \
        dialyzer docker-dialyzer local-dialyzer \
        shell docker-shell local-shell \
        docker-build resolve-checkouts clean

REBAR3 ?= rebar3
CHECKOUTS_OVERRIDE = docker-compose.checkouts.yml
COMPOSE ?= docker compose -f docker-compose.test.yml -f $(CHECKOUTS_OVERRIDE)

# All Erlang invocations run in docker by default. The local-* targets
# exist for power users who already have OTP 27 + rebar3 on the host.

all: compile

compile: docker-compile
test: docker-test
dialyzer: docker-dialyzer
shell: docker-shell

# Generate a docker-compose override that bind-mounts each
# _checkouts/* symlink target at its real host path inside the
# container so the symlinks resolve. Run before any docker action.
resolve-checkouts:
	@sh scripts/resolve-checkouts > $(CHECKOUTS_OVERRIDE)

docker-build: resolve-checkouts
	$(COMPOSE) build

docker-compile: docker-build
	$(COMPOSE) run --rm test make local-compile

docker-test: docker-build
	$(COMPOSE) run --rm test

docker-dialyzer: docker-build
	$(COMPOSE) run --rm test make local-dialyzer

docker-shell: docker-build
	$(COMPOSE) run --rm test make local-shell

local-compile:
	$(REBAR3) compile

local-test: local-eunit local-ct local-dialyzer

local-eunit:
	$(REBAR3) eunit

local-ct:
	$(REBAR3) ct

local-dialyzer:
	$(REBAR3) dialyzer

local-shell:
	$(REBAR3) shell

clean:
	rm -rf _build $(CHECKOUTS_OVERRIDE)
