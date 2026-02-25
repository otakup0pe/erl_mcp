.PHONY: all compile test eunit ct clean docker-test docker-build

REBAR3 ?= rebar3
DOCKER_IMAGE ?= erl-mcp-test:latest

all: compile

compile:
	$(REBAR3) compile

test: docker-test

docker-build:
	docker build -t $(DOCKER_IMAGE) -f Dockerfile.test .

docker-test: docker-build
	docker run --rm -v $(PWD):/app -w /app $(DOCKER_IMAGE) make local-test

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
