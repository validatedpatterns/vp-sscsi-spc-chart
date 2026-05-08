# https://hub.docker.com/r/helmunittest/helm-unittest/tags/
HELM_UNITTEST_IMAGE ?= docker.io/helmunittest/helm-unittest:3.14.4-0.5.0
HELM_DOCS_IMAGE ?= docker.io/jnorwood/helm-docs:latest
# https://github.com/super-linter/super-linter/pkgs/container/super-linter
SUPER_LINTER_IMAGE ?= ghcr.io/super-linter/super-linter:slim-v8.1.0
SUPER_LINTER_DEFAULT_BRANCH ?= main
# Keep Trivy DB outside the mounted workspace so Gitleaks/JSCPD do not scan downloaded artifacts.
SUPER_LINTER_TRIVY_CACHE ?= $(HOME)/.cache/vp-sscsi-spc-super-linter-trivy

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

##@ Linting

.PHONY: super-linter
super-linter: ## Runs GitHub Super-Linter locally (.github/super-linter.env)
	@mkdir -p $(SUPER_LINTER_TRIVY_CACHE)
	podman run $(PODMAN_ARGS) \
		-e RUN_LOCAL=true \
		-e DEFAULT_BRANCH=$(SUPER_LINTER_DEFAULT_BRANCH) \
		-e USE_FIND_ALGORITHM=true \
		-e TRIVY_CACHE_DIR=/trivy-cache \
		--env-file .github/super-linter.env \
		-v $(SUPER_LINTER_TRIVY_CACHE):/trivy-cache:rw,Z \
		-v $(PWD):/tmp/lint:rw,Z \
		$(SUPER_LINTER_IMAGE)
