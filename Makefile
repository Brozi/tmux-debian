# ==============================================================================
# Makefile - tmux .deb builder
# ==============================================================================

VERSION ?= latest
ARCH ?= all
OUT_DIR ?= dist
REVISION ?= 1

.PHONY: help build build-all preview check test docker-build clean

help:
	@echo "tmux .deb package builder"
	@echo ""
	@echo "Available targets:"
	@echo "  make build         Build .deb package for host architecture (VERSION=$(VERSION))"
	@echo "  make build-all     Build .deb packages for all architectures (amd64, arm64)"
	@echo "  make preview       Build preview packages from upstream master branch"
	@echo "  make check         Check upstream for new releases"
	@echo "  make test          Run verification tests on built .deb packages"
	@echo "  make docker-build  Build packages inside a Docker container"
	@echo "  make clean         Remove build artifacts and temporary files"
	@echo ""
	@echo "Options:"
	@echo "  VERSION=3.8        Target specific version (default: latest)"
	@echo "  ARCH=amd64         Target architecture (amd64, arm64, all)"
	@echo "  REVISION=1         Package revision number"

build:
	./scripts/build-deb.sh --version $(VERSION) --revision $(REVISION) --out-dir $(OUT_DIR)

build-all:
	./scripts/build-deb.sh --version $(VERSION) --arch all --revision $(REVISION) --out-dir $(OUT_DIR)

preview:
	./scripts/build-deb.sh --version preview --arch all --revision $(REVISION) --out-dir $(OUT_DIR)

check:
	./scripts/check-upstream.sh

test:
	@ls $(OUT_DIR)/*.deb >/dev/null 2>&1 || { echo "No packages found in $(OUT_DIR)/ to test. Run 'make build' first." >&2; exit 1; }
	./scripts/test-deb.sh $(OUT_DIR)/*.deb

docker-build:
	docker compose run --rm builder --version $(VERSION) --arch $(ARCH) --revision $(REVISION) --out-dir $(OUT_DIR)

clean:
	rm -rf build/ dist/ .cache/
