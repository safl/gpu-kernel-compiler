# SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
#
# SPDX-License-Identifier: BSD-3-Clause
#
# What CI runs, and what a human runs the same way. ENGINE=podman works too.
ENGINE ?= docker
IMAGE ?= ghcr.io/safl/gpu-kernel-compiler
TAG ?= latest
# podman's default OCI format has no SHELL, which the Dockerfile's pipes need
FORMAT = $(if $(filter podman,$(notdir $(ENGINE))),--format docker)

.DEFAULT_GOAL := help
.PHONY: help all build smoke push test

help:
	@echo "make build    build $(IMAGE):$(TAG)"
	@echo "make smoke    compile tests/kernel.cl for every target in it and check each output"
	@echo "make push     push it, and as :TAG for each of TAGS"
	@echo "make test     unit-test kobj_check"
	@echo "make all      build, then smoke"

all: build smoke

build:
	$(ENGINE) build $(FORMAT) -t $(IMAGE):$(TAG) .

smoke:
	ENGINE=$(ENGINE) tests/smoke.sh $(IMAGE):$(TAG)

push:
	$(ENGINE) push $(IMAGE):$(TAG)
	for t in $(TAGS); do \
		$(ENGINE) tag $(IMAGE):$(TAG) $(IMAGE):$$t && $(ENGINE) push $(IMAGE):$$t || exit 1; \
	done

test:
	pytest -q tests
