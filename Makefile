ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

.PHONY: all compile test local-test local-eunit local-ct clean docker-build docker-test dialyzer shell

REBAR3 ?= rebar3
COMPOSE ?= docker compose -f docker-compose.test.yml

all: compile

compile:
	$(REBAR3) compile

test: docker-test

docker-build:
	$(COMPOSE) build

docker-test: docker-build
	$(COMPOSE) run --rm test

local-test: local-eunit local-ct

local-eunit:
	$(REBAR3) eunit

local-ct:
	$(REBAR3) ct

clean:
	$(REBAR3) clean

dialyzer:
	$(REBAR3) dialyzer

shell:
	$(REBAR3) shell
