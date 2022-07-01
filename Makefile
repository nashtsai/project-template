# note: call scripts from /scripts

IMG ?= myapp
VERSION ?= 1.0.0-alpha.1
TAG ?= v$(VERSION)

CHART_PATH=deployment/helm

GO ?= go
GOOS ?= $(shell $(GO) env GOOS)
GOARCH ?= $(shell $(GO) env GOARCH)
# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell $(GO) env GOBIN))
GOBIN=$(shell $(GO) env GOPATH)/bin
else
GOBIN=$(shell $(GO) env GOBIN)
endif
# export GONOPROXY=
# export GONOSUMDB=
# export GOPRIVATE=
# export GOPROXY=${GOPROXY:-https://mirrors.aliyun.com/goproxy,direct}
# export GOPROXY=${GOPROXY:-https://goproxy.cn,direct}
export GOPROXY=https://goproxy.cn,direct

# Go module support: set `-mod=vendor` to use the vendored sources.
# See also hack/make.sh.
ifeq ($(shell go help mod >/dev/null 2>&1 && echo true), true)
  GO:=GO111MODULE=on $(GO)
  MOD_VENDOR=-mod=vendor
endif

ifneq ($(BUILDX_ENABLED), false)
	ifeq ($(shell docker buildx inspect 2>/dev/null | awk '/Status/ { print $$2 }'), running)
		BUILDX_ENABLED ?= true
	else
		BUILDX_ENABLED ?= false
	endif
endif

define BUILDX_ERROR
buildx not enabled, refusing to run this recipe
endef

# Which architecture to build - see $(ALL_ARCH) for options.
# if the 'local' rule is being run, detect the ARCH from 'go env'
# if it wasn't specified by the caller.
local : ARCH ?= $(shell go env GOOS)-$(shell go env GOARCH)
ARCH ?= linux-amd64

# BUILDX_PLATFORMS ?= $(subst -,/,$(ARCH))
BUILDX_PLATFORMS ?= linux/amd64,linux/arm64
BUILDX_OUTPUT_TYPE ?= docker

LD_FLAGS="-s -w -X main.version=v${VERSION} -X main.buildDate=`date -u +'%Y-%m-%dT%H:%M:%SZ'` -X main.gitCommit=`git rev-parse HEAD`"

TAG_LATEST ?= false

ifeq ($(TAG_LATEST), true)
	IMAGE_TAGS ?= $(IMG):$(VERSION) $(IMG):latest
else
	IMAGE_TAGS ?= $(IMG):$(VERSION)
endif

# Build binary
bin/app.%: fmt vet
	GOOS=$(word 2,$(subst ., ,$@)) GOARCH=$(word 3,$(subst ., ,$@)) $(GO) build -ldflags=${LD_FLAGS} -o $@ main.go


.PHONY: test
test:
	$(GO) test ./... -coverprofile cover.out

# test Kubernetes controllers, required etcd and apiserver
.PHONY: test-controllers
test-controllers: generate fmt vet manifests
	KUBEBUILDER_ASSETS=/usr/local/bin/ $(GO) test ./controllers/... -coverprofile cover.ou

# Build the docker image
.PHONY: docker-build-dist
docker-build-dist: bin/manager.linux.amd64 bin/manager.linux.arm64
	docker buildx build . --platform linux/amd64,linux/arm64 -t ${IMG}:${TAG} --push

.PHONY: docker-build
docker-build:
ifneq ($(BUILDX_ENABLED), true)
	DOCKER_BUILDKIT=1 docker build . -t ${IMG}:${TAG} 
else
	DOCKER_BUILDKIT=1 docker buildx build . --pull --platform $(BUILDX_PLATFORMS) -t ${IMG}:${TAG} --push
endif

.PHONY: podman-build
podman-build.%:
	#podman machine start
	podman build . \
	--authfile ./config.json \
	--jobs 8 \
	--platform linux/$(word 2,$(subst ., ,$@)) \
	--tag ${IMG}:${TAG}-$(word 2,$(subst ., ,$@))

.PHONY: kaniko-build
kaniko-build.%:
	# Kaniko doc: https://github.com/GoogleContainerTools/kaniko#using-kaniko
	docker run \
	-v `pwd`/config.json:/kaniko/.docker/config.json \
	-v $(pwd):/workspace \
	gcr.io/kaniko-project/executor:latest \
	--dockerfile /workspace/Dockerfile \
	--destination ${IMG}:${TAG}-$(word 2,$(subst ., ,$@)) \
	--context dir:///workspace/ \
	--cache=true \
	--cache-dir=/workspace/cache \
	--cache-copy-layers \
	--customPlatform=linux/$(word 2,$(subst ., ,$@))


.PHONY: run
run: fmt vet
	$(GO) run ./main.go

# Run go fmt against code
.PHONY: fmt
fmt:
	$(GO) fmt ./...

# Run go vet against code
.PHONY: vet
vet:
	$(GO) vet ./...

.PHONY: mod-download
mod-download: 
	$(GO) mod download


.PHONY: mod-vendor
mod-vendor: 
	$(GO) mod tidy
	$(GO) mod vendor
	$(GO) mod verify

.PHONY: clean
clean:
	$(GO) clean -i

.PHONY: lint
lint:
	golangci-lint run -v



.PHONY: install
install:
	$(GO) install github.com/bufbuild/buf/cmd/buf@v1.4.0
	$(GO) install \
		github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-grpc-gateway \
		github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-openapiv2 \
		google.golang.org/protobuf/cmd/protoc-gen-go \
		google.golang.org/grpc/cmd/protoc-gen-go-grpc

.PHONY: buf-mod-update
buf-mod-update:
	buf mod update

.PHONY: buf-gen
buf-gen:
	# buf generate \
	# 	--template ./buf.gen.yaml \
	# 	--path ./*.proto
	buf generate

.PHONY: buf-lint
buf-lint:
	buf lint
	buf breaking

.PHONY: grpc-proto-push
grpc-proto-push:
	oras push $(PROTO_REGISTRY):$(PROTO_TAG) \
		--manifest-config ./configs/oras-config.json:application/vnd.oras.config.v1+json \
		--manifest-annotations ./configs/oras-annotations.json \
		./$(SERVICE_NAME).proto
	# `oras pull $(PROTO_REGISTRY):$(PROTO_TAG)` to restore grpc proto file

.PHONY: bump-chart
bump-chart: 
	sed -i '' "s/^version:.*/version: $(VERSION)/" $(CHART_PATH)/Chart.yaml
	sed -i '' "s/^appVersion:.*/appVersion: $(VERSION)/" $(CHART_PATH)/Chart.yaml
	sed -i '' "s/tag:.*/tag: v$(VERSION)/" $(CHART_PATH)/values.yaml


.PHONY: mac-install-prerequisite
mac-install-prerequisite:
	brew install docker --cask
	brew install go@1.17 golangci-lint protobuf-c oras #protoc-gen-go protoc-gen-go-grpc bufbuild/buf/buf

