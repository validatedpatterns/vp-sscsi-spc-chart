# https://hub.docker.com/r/helmunittest/helm-unittest/tags/
HELM_UNITTEST_IMAGE ?= docker.io/helmunittest/helm-unittest:3.14.4-0.5.0
HELM_DOCS_IMAGE ?= docker.io/jnorwood/helm-docs:latest

PWD=$(shell pwd)
MYNAME=$(shell id -n -u)
MYUID=$(shell id -u)
MYGID=$(shell id -g)
PODMAN_ARGS := --security-opt label=disable --net=host --rm --passwd-entry "$(MYNAME):x:$(MYUID):$(MYGID)::/apps:/bin/bash" --user $(MYUID):$(MYGID) --userns keep-id:uid=$(MYUID),gid=$(MYGID)
##@ Common Tasks

.PHONY: help
help: ## This help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: helm-lint
helm-lint: ## Runs helm lint against the chart
	helm lint .

.PHONY: helm-unittest
helm-unittest: ## Runs the helm unit tests
	podman run $(PODMAN_ARGS) -v $(PWD):/apps:rw,Z -w /apps $(HELM_UNITTEST_IMAGE) .

.PHONY: helm-docs
helm-docs: ## Generates README.md from values.yaml
	podman run $(PODMAN_ARGS) -v $(PWD):/helm-docs:rw $(HELM_DOCS_IMAGE)

.PHONY: test
test: helm-lint helm-unittest ## Runs helm lint and unit tests
