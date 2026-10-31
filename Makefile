ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

.PHONY: all compile docker-compile local-compile \
        test docker-test local-test local-eunit local-ct \
        dialyzer docker-dialyzer local-dialyzer \
        shell docker-shell local-shell \
        docker-build resolve-checkouts dev-upgrade clean

REBAR3 ?= rebar3
CHECKOUTS_OVERRIDE = docker-compose.checkouts.yml
COMPOSE ?= docker compose -f docker-compose.test.yml -f $(CHECKOUTS_OVERRIDE)

export BUILDX_BUILDER ?= default

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
	$(REBAR3) cover

local-eunit:
	$(REBAR3) eunit

local-ct:
	$(REBAR3) ct

local-dialyzer:
	$(REBAR3) dialyzer

local-shell:
	$(REBAR3) shell

# Unlock before resolving because rebar3 upgrade can leave git branch
# dependencies pinned to stale refs while still exiting successfully.
# `unlock --all` is required, not optional: rebar3 REJECTS the bare
# `rebar3 unlock` form, so dropping the flag means nothing un-pins and
# the bump resolves against the refs already in rebar.lock.
# verify-erlang-lock then reports which refs actually MOVED, against the
# baseline snapshotted before the container runs -- a missing dep is
# fatal, an unchanged ref is not (a dep already at its tip correctly
# does not move).
dev-upgrade: resolve-checkouts
	@mkdir -p _build
	@sh scripts/verify-erlang-lock --snapshot > _build/rebar-lock.before
	@target='$(DEP)'; \
	if [ -z "$$target" ]; then \
		echo "Bumping all git deps to latest allowed refs..."; \
		unlock_cmd='rebar3 unlock --all'; \
		rm_cmd='rm -rf _build/default/lib _build/test/lib'; \
	else \
		echo "Bumping $$target..."; \
		unlock_cmd="rebar3 unlock $$target"; \
		rm_cmd="rm -rf _build/default/lib/$$target _build/test/lib/$$target"; \
	fi; \
	$(COMPOSE) run --rm test sh -c "$$unlock_cmd && $$rm_cmd && rebar3 deps && rebar3 lock"
	@rc=0; sh scripts/verify-erlang-lock --since _build/rebar-lock.before $(DEP) || rc=$$?; \
		rm -f _build/rebar-lock.before; \
		exit $$rc

clean:
	rm -rf _build $(CHECKOUTS_OVERRIDE)
