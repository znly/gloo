#----------------------------------------------------------------------------------
# Base
#----------------------------------------------------------------------------------

ROOTDIR := $(shell pwd)
OUTPUT_DIR ?= $(ROOTDIR)/_output

# Kind of a hack to make sure _output exists
z := $(shell mkdir -p $(OUTPUT_DIR))

SOURCES := $(shell find . -name "*.go" | grep -v test.go)
RELEASE := "true"
ifeq ($(TAGGED_VERSION),)
	TAGGED_VERSION := $(shell git describe --tags --dirty)
	RELEASE := "false"
endif
VERSION ?= $(shell echo $(TAGGED_VERSION) | cut -c 2-)

# The full SHA of the currently checked out commit
CHECKED_OUT_SHA := $(shell git rev-parse HEAD)
# Returns the name of the default branch in the remote `origin` repository, e.g. `master`
DEFAULT_BRANCH_NAME := $(shell git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')
# Print the branches that contain the current commit and keep only the one that
# EXACTLY matches the name of the default branch (avoid matching e.g. `master-2`).
# If we get back a result, it mean we are on the default branch.
EMPTY_IF_NOT_DEFAULT := $(shell git branch --contains $(CHECKED_OUT_SHA) | grep -ow $(DEFAULT_BRANCH_NAME))

ON_DEFAULT_BRANCH := false
ifneq ($(EMPTY_IF_NOT_DEFAULT),)
    ON_DEFAULT_BRANCH = true
endif

ASSETS_ONLY_RELEASE := true
ifeq ($(ON_DEFAULT_BRANCH), true)
    ASSETS_ONLY_RELEASE = false
endif

print-git-info:
	@echo CHECKED_OUT_SHA: $(CHECKED_OUT_SHA)
	@echo DEFAULT_BRANCH_NAME: $(DEFAULT_BRANCH_NAME)
	@echo EMPTY_IF_NOT_DEFAULT: $(EMPTY_IF_NOT_DEFAULT)
	@echo ON_DEFAULT_BRANCH: $(ON_DEFAULT_BRANCH)
	@echo ASSETS_ONLY_RELEASE: $(ASSETS_ONLY_RELEASE)

LDFLAGS := "-X github.com/solo-io/gloo/pkg/version.Version=$(VERSION)"
GCFLAGS := all="-N -l"

GO_BUILD_FLAGS := GO111MODULE=on CGO_ENABLED=0 GOARCH=amd64

# Passed by cloudbuild
GCLOUD_PROJECT_ID := $(GCLOUD_PROJECT_ID)
BUILD_ID := $(BUILD_ID)

TEST_ASSET_DIR := $(ROOTDIR)/_test

#----------------------------------------------------------------------------------
# Docker functions
#----------------------------------------------------------------------------------

# $(1) component name
# $(2) component directory
define build_staged
docker build $(ROOTDIR) -f $(2)/cmd/Dockerfile.staged \
	-t quay.io/solo-io/$(1):$(VERSION)
endef

# $(1) name of container
define build_container
docker build -t quay.io/solo-io/$(1):$(VERSION) $(ROOTDIR)/projects/$(1)/_output -f $(ROOTDIR)/projects/$(1)/cmd/Dockerfile;
endef

#----------------------------------------------------------------------------------
# Macros
#----------------------------------------------------------------------------------

# This macro takes a relative path as its only argument and returns all the files
# in the tree rooted at that directory that match the given criteria.
get_sources = $(shell find $(1) -name "*.go" | grep -v test | grep -v generated.go | grep -v mock_)

#----------------------------------------------------------------------------------
# Repo setup
#----------------------------------------------------------------------------------

# https://www.viget.com/articles/two-ways-to-share-git-hooks-with-your-team/
.PHONY: init
init: update-deps
	git config core.hooksPath .githooks

.PHONY: fmt-changed
fmt-changed:
	git diff --name-only | grep '.*.go$$' | xargs -- goimports -w


# must be a seperate target so that make waits for it to complete before moving on
.PHONY: mod-download
mod-download:
	go mod download


.PHONY: update-deps
update-deps: mod-download
	$(shell cd $(shell go list -f '{{ .Dir }}' -m github.com/solo-io/protoc-gen-ext); make install)
	chmod +x $(shell go list -f '{{ .Dir }}' -m k8s.io/code-generator)/generate-groups.sh
	GO111MODULE=off go get -u golang.org/x/tools/cmd/goimports
	GO111MODULE=off go get -u github.com/gogo/protobuf/gogoproto
	GO111MODULE=off go get -u github.com/gogo/protobuf/protoc-gen-gogo
	GO111MODULE=off go get -u github.com/cratonica/2goarray
	GO111MODULE=off go get -v -u github.com/golang/mock/gomock
	GO111MODULE=off go install github.com/golang/mock/mockgen


.PHONY: check-format
check-format:
	NOT_FORMATTED=$$(gofmt -l ./projects/ ./pkg/ ./test/) && if [ -n "$$NOT_FORMATTED" ]; then echo These files are not formatted: $$NOT_FORMATTED; exit 1; fi

check-spelling:
	./ci/spell.sh check

#----------------------------------------------------------------------------------
# Build Container
#----------------------------------------------------------------------------------

.PHONY: build-container
build-container:
	docker build -t quay.io/solo-io/gloo-build:$(VERSION) -f hack/build/Dockerfile .

#----------------------------------------------------------------------------------
# Clean
#----------------------------------------------------------------------------------

# Important to clean before pushing new releases. Dockerfiles and binaries may not update properly
.PHONY: clean
clean:
	rm -rf _output
	rm -rf _test
	rm -rf docs/site*
	rm -rf docs/themes
	rm -rf docs/resources
	git clean -f -X install

#----------------------------------------------------------------------------------
# Generated Code and Docs
#----------------------------------------------------------------------------------

.PHONY: generated-code
generated-code: $(OUTPUT_DIR)/.generated-code verify-enterprise-protos update-licenses generate-helm-files

# Alternative to make generated-code which runs entirely in a docker container.
# WARNING: On mac this will perform much slower as the performance of docker volumes is poor
.PHONY: generated-code-docker
generated-code-docker:
	docker run --rm --name gloo-build -w /etc/src \
		-c $(shell expr $(shell nproc --all) - 2) \
        -v $(ROOTDIR):/etc/src:delegated quay.io/solo-io/gloo-build \
        go run generate.go && goimports -w .



# Note: currently we generate CLI docs, but don't push them to the consolidated docs repo (gloo-docs). Instead, the
# Glooctl enterprise docs are pushed from the private repo.
SUBDIRS:=$(shell ls -d -- */ | grep -v vendor)
$(OUTPUT_DIR)/.generated-code:
	go mod tidy
	rm -rf vendor_any
	find * -type f | grep .sk.md | xargs rm -f
	GO111MODULE=on go generate ./...
	rm docs/content/cli/glooctl*; GO111MODULE=on go run projects/gloo/cli/cmd/docs/main.go
	gofmt -w $(SUBDIRS)
	goimports -w $(SUBDIRS)
	mkdir -p $(OUTPUT_DIR)
	touch $@

# Make sure that the enterprise API *.pb.go files that are generated but not used in this repo are valid.
.PHONY: verify-enterprise-protos
verify-enterprise-protos:
	@echo Verifying validity of generated enterprise files...
	$(GO_BUILD_FLAGS) GOOS=linux go build projects/gloo/pkg/api/v1/enterprise/verify.go

#----------------------------------------------------------------------------------
# Generate mocks
#----------------------------------------------------------------------------------

# The values in this array are used in a foreach loop to dynamically generate the
# commands in the generate-client-mocks target.
# For each value, the ":" character will be replaced with " " using the subst function,
# thus turning the string into a 3-element array. The n-th element of the array will
# then be selected via the word function
MOCK_RESOURCE_INFO := \
	gloo:artifact:ArtifactClient \
	gloo:endpoint:EndpointClient \
	gloo:proxy:ProxyClient \
	gloo:secret:SecretClient \
	gloo:settings:SettingsClient \
	gloo:upstream:UpstreamClient \
	gateway:gateway:GatewayClient \
	gateway:virtual_service:VirtualServiceClient\
	gateway:route_table:RouteTableClient\

# Use gomock (https://github.com/golang/mock) to generate mocks for our resource clients.
.PHONY: generate-client-mocks
generate-client-mocks:
	@$(foreach INFO, $(MOCK_RESOURCE_INFO), \
		echo Generating mock for $(word 3,$(subst :, , $(INFO)))...; \
		mockgen -destination=projects/$(word 1,$(subst :, , $(INFO)))/pkg/mocks/mock_$(word 2,$(subst :, , $(INFO)))_client.go \
     		-package=mocks \
     		github.com/solo-io/gloo/projects/$(word 1,$(subst :, , $(INFO)))/pkg/api/v1 \
     		$(word 3,$(subst :, , $(INFO))) \
     	;)

#----------------------------------------------------------------------------------
# glooctl
#----------------------------------------------------------------------------------

CLI_DIR=projects/gloo/cli

$(OUTPUT_DIR)/glooctl: $(SOURCES)
	GO111MODULE=on go build -ldflags=$(LDFLAGS) -gcflags=$(GCFLAGS) -o $@ $(CLI_DIR)/cmd/main.go

$(OUTPUT_DIR)/glooctl-linux-amd64: $(SOURCES)
	$(GO_BUILD_FLAGS) GOOS=linux go build -ldflags=$(LDFLAGS) -gcflags=$(GCFLAGS) -o $@ $(CLI_DIR)/cmd/main.go

$(OUTPUT_DIR)/glooctl-darwin-amd64: $(SOURCES)
	$(GO_BUILD_FLAGS) GOOS=darwin go build -ldflags=$(LDFLAGS) -gcflags=$(GCFLAGS) -o $@ $(CLI_DIR)/cmd/main.go

$(OUTPUT_DIR)/glooctl-windows-amd64.exe: $(SOURCES)
	$(GO_BUILD_FLAGS) GOOS=windows go build -ldflags=$(LDFLAGS) -gcflags=$(GCFLAGS) -o $@ $(CLI_DIR)/cmd/main.go


.PHONY: glooctl
glooctl: $(OUTPUT_DIR)/glooctl
.PHONY: glooctl-linux-amd64
glooctl-linux-amd64: $(OUTPUT_DIR)/glooctl-linux-amd64
.PHONY: glooctl-darwin-amd64
glooctl-darwin-amd64: $(OUTPUT_DIR)/glooctl-darwin-amd64
.PHONY: glooctl-windows-amd64
glooctl-windows-amd64: $(OUTPUT_DIR)/glooctl-windows-amd64.exe

.PHONY: build-cli
build-cli: glooctl-linux-amd64 glooctl-darwin-amd64 glooctl-windows-amd64

#----------------------------------------------------------------------------------
# Gateway
#----------------------------------------------------------------------------------

GATEWAY=gateway
GATEWAY_DIR=projects/$(GATEWAY)
GATEWAY_OUTPUT_DIR=$(ROOTDIR)/$(GATEWAY_DIR)/_output
GATEWAY_SOURCES=$(shell find $(GATEWAY_DIR) -name "*.go" | grep -v test | grep -v generated.go)

$(GATEWAY_OUTPUT_DIR)/gateway-linux-amd64: $(GATEWAY_SOURCES)
	CGO_ENABLED=0 GOARCH=amd64 GOOS=linux go build -ldflags=$(LDFLAGS) -gcflags=$(GCFLAGS) -o $@ $(GATEWAY_DIR)/cmd/main.go

.PHONY: gateway-docker
gateway-docker: $(GATEWAY_OUTPUT_DIR)/gateway-linux-amd64
	$(call build_container,$(GATEWAY))

gateway-docker-build:
	$(call build_staged,gateway,$(GATEWAY_DIR))

.PHONY: gateway
gateway: $(GATEWAY_OUTPUT_DIR)/gateway-linux-amd64

#----------------------------------------------------------------------------------
# Ingress
#----------------------------------------------------------------------------------

INGRESS=ingress
INGRESS_DIR=projects/$(INGRESS)
INGRESS_OUTPUT_DIR=$(ROOTDIR)/$(INGRESS_DIR)/_output
INGRESS_SOURCES=$(shell find $(INGRESS_DIR) -name "*.go" | grep -v test | grep -v generated.go)

$(INGRESS_OUTPUT_DIR)/ingress-linux-amd64: $(INGRESS_SOURCES)
	CGO_ENABLED=0 GOARCH=amd64 GOOS=linux go build -ldflags=$(LDFLAGS) -gcflags=$(GCFLAGS) -o $@ $(INGRESS_DIR)/cmd/main.go

.PHONY: ingress-docker
ingress-docker: $(INGRESS_OUTPUT_DIR)/ingress-linux-amd64
	$(call build_container,$(INGRESS))

ingress-docker-build:
	$(call build_staged,ingress,$(INGRESS_DIR))

.PHONY: ingress
ingress: $(INGRESS_OUTPUT_DIR)/ingress-linux-amd64

#----------------------------------------------------------------------------------
# Access Logger
#----------------------------------------------------------------------------------

ACCESS_LOG=accesslogger
ACCESS_LOG_DIR=projects/$(ACCESS_LOG)
ACCESS_LOG_OUTPUT_DIR=$(ROOTDIR)/$(ACCESS_LOG_DIR)/_output
ACCESS_LOG_SOURCES=$(shell find $(ACCESS_LOG_DIR) -name "*.go" | grep -v test | grep -v generated.go)

$(ACCESS_LOG_OUTPUT_DIR)/access-logger-linux-amd64: $(ACCESS_LOG_SOURCES)
	CGO_ENABLED=0 GOARCH=amd64 GOOS=linux go build -ldflags=$(LDFLAGS) -gcflags=$(GCFLAGS) -o $@ $(ACCESS_LOG_DIR)/cmd/main.go

.PHONY: access-logger-docker
access-logger-docker: $(ACCESS_LOG_OUTPUT_DIR)/access-logger-linux-amd64
	docker build -t quay.io/solo-io/access-logger:$(VERSION) $(ACCESS_LOG_OUTPUT_DIR) -f $(ROOTDIR)/$(ACCESS_LOG_DIR)/cmd/Dockerfile;

access-logger-docker-build:
	$(call build_staged,access-logger,$(ACCESS_LOG_DIR))

.PHONY: access-logger
access-logger: $(ACCESS_LOG_OUTPUT_DIR)/access-logger-linux-amd64

#----------------------------------------------------------------------------------
# Discovery
#----------------------------------------------------------------------------------

DISCOVERY=discovery
DISCOVERY_DIR=projects/$(DISCOVERY)
DISCOVERY_OUTPUT_DIR=$(ROOTDIR)/$(DISCOVERY_DIR)/_output
DISCOVERY_SOURCES=$(shell find $(DISCOVERY_DIR) -name "*.go" | grep -v test | grep -v generated.go)

$(DISCOVERY_OUTPUT_DIR)/discovery-linux-amd64: $(DISCOVERY_SOURCES)
	CGO_ENABLED=0 GOARCH=amd64 GOOS=linux go build -ldflags=$(LDFLAGS) -gcflags=$(GCFLAGS) -o $@ $(DISCOVERY_DIR)/cmd/main.go

.PHONY: discovery-docker
discovery-docker: $(DISCOVERY_OUTPUT_DIR)/discovery-linux-amd64
	$(call build_container,$(DISCOVERY))

discovery-docker-build:
	$(call build_staged,discovery,$(DISCOVERY_DIR))

.PHONY: discovery
discovery: $(DISCOVERY_OUTPUT_DIR)/discovery-linux-amd64

#----------------------------------------------------------------------------------
# Gloo
#----------------------------------------------------------------------------------

GLOO=gloo
GLOO_DIR=projects/$(GLOO)
GLOO_OUTPUT_DIR=$(ROOTDIR)/$(GLOO_DIR)/_output
GLOO_SOURCES=$(shell find $(GLOO_DIR) -name "*.go" | grep -v test | grep -v generated.go)

$(GLOO_OUTPUT_DIR)/gloo-linux-amd64: $(GLOO_SOURCES)
	CGO_ENABLED=0 GOARCH=amd64 GOOS=linux go build -ldflags=$(LDFLAGS) -gcflags=$(GCFLAGS) -o $@ $(GLOO_DIR)/cmd/main.go

.PHONY: gloo-docker
gloo-docker: $(GLOO_OUTPUT_DIR)/gloo-linux-amd64
	mkdir -p $(GLOO_OUTPUT_DIR)
	cp hack/utils/oss_compliance/third_party_licenses.txt $(GLOO_OUTPUT_DIR)/third_party_licenses.txt
	$(call build_container,$(GLOO))

gloo-docker-build:
	$(call build_staged,gloo,$(GLOO_DIR))

.PHONY: gloo
gloo: $(GLOO_OUTPUT_DIR)/gloo-linux-amd64

#----------------------------------------------------------------------------------
# Envoy init (BASE)
#----------------------------------------------------------------------------------

ENVOYINIT=envoyinit
ENVOYINIT_DIR=projects/$(ENVOYINIT)
ENVOYINIT_OUTPUT_DIR=$(ROOTDIR)/$(ENVOYINIT_DIR)/_output
ENVOYINIT_SOURCES=$(shell find $(ENVOYINIT_DIR) -name "*.go" | grep -v test | grep -v generated.go)

$(ENVOYINIT_OUTPUT_DIR)/envoyinit-linux-amd64: $(ENVOYINIT_SOURCES)
	CGO_ENABLED=0 GOARCH=amd64 GOOS=linux go build -ldflags=$(LDFLAGS) -gcflags=$(GCFLAGS) -o $@ $(ENVOYINIT_DIR)/cmd/main.go

.PHONY: gloo-envoy-wrapper-docker
gloo-envoy-wrapper-docker: $(ENVOYINIT_OUTPUT_DIR)/envoyinit-linux-amd64
	docker build $(ENVOYINIT_OUTPUT_DIR) -f $(ENVOYINIT_DIR)/cmd/Dockerfile.envoyinit \
		-t quay.io/solo-io/gloo-envoy-wrapper:$(VERSION)

.PHONY: envoyinit
envoyinit: $(ENVOYINIT_OUTPUT_DIR)/envoyinit-linux-amd64

#----------------------------------------------------------------------------------
# Envoy init (WASM)
#----------------------------------------------------------------------------------

ENVOY_WASM=envoyinit
ENVOY_WASM_DIR=projects/$(ENVOY_WASM)
ENVOY_WASM_OUTPUT_DIR=$(ROOTDIR)/$(ENVOY_WASM_DIR)/_output
ENVOY_WASM_SOURCES=$(shell find $(ENVOY_WASM_DIR) -name "*.go" | grep -v test | grep -v generated.go)

$(ENVOYINIT_OUTPUT_DIR)/envoywasm-linux-amd64: $(ENVOY_WASM_SOURCES)
	$(GO_BUILD_FLAGS) GOOS=linux go build -ldflags=$(LDFLAGS) -gcflags=$(GCFLAGS) -o $@ $(ENVOY_WASM_DIR)/cmd/main.go

.PHONY: envoywasm
envoywasm: $(ENVOY_WASM_OUTPUT_DIR)/envoywasm-linux-amd64


.PHONY: gloo-envoy-wasm-wrapper-docker
gloo-envoy-wasm-wrapper-docker: $(ENVOY_WASM_OUTPUT_DIR)/envoywasm-linux-amd64
	docker build $(ENVOY_WASM_OUTPUT_DIR) -f $(ENVOY_WASM_DIR)/cmd/Dockerfile.envoywasm \
		-t quay.io/solo-io/gloo-envoy-wasm-wrapper:$(VERSION)


#----------------------------------------------------------------------------------
# Certgen - Job for creating TLS Secrets in Kubernetes
#----------------------------------------------------------------------------------
CERTGEN=certgen
CERTGEN_DIR=jobs/$(CERTGEN)
CERTGEN_OUTPUT_DIR=$(ROOTDIR)/$(CERTGEN_DIR)/_output
CERTGEN_SOURCES=$(shell find $(CERTGEN_DIR) -name "*.go" | grep -v test | grep -v generated.go)

$(CERTGEN_OUTPUT_DIR)/certgen-linux-amd64: $(CERTGEN_SOURCES)
	CGO_ENABLED=0 GOARCH=amd64 GOOS=linux go build -ldflags=$(LDFLAGS) -gcflags=$(GCFLAGS) -o $@ $(CERTGEN_DIR)/cmd/main.go

.PHONY: certgen-docker
certgen-docker: $(CERTGEN_OUTPUT_DIR)/certgen-linux-amd64
	docker build -t quay.io/solo-io/$(CERTGEN):$(VERSION) $(CERTGEN_OUTPUT_DIR) -f $(ROOTDIR)/$(CERTGEN_DIR)/cmd/Dockerfile;

certgen-docker-build:
	$(call build_staged,ingress,$(CERTGEN_DIR))

.PHONY: certgen
certgen: $(CERTGEN_OUTPUT_DIR)/certgen-linux-amd64

#----------------------------------------------------------------------------------
# Build All
#----------------------------------------------------------------------------------

BINARIES := gloo glooctl gateway discovery envoyinit certgen ingress

.PHONY: build
build: gloo glooctl gateway discovery envoyinit certgen ingress

#----------------------------------------------------------------------------------
# Deployment Manifests / Helm
#----------------------------------------------------------------------------------

HELM_SYNC_DIR := $(OUTPUT_DIR)/helm
HELM_DIR := install/helm/gloo

# Creates Chart.yaml and values.yaml. See install/helm/gloo/README.md for more info.
.PHONY: generate-helm-files
generate-helm-files: $(OUTPUT_DIR)/.helm-prepared

$(OUTPUT_DIR)/.helm-prepared:
	GO111MODULE=on go run $(HELM_DIR)/generate.go --version $(VERSION)  --generate-helm-docs
	touch $@

package-chart: generate-helm-files
	mkdir -p $(HELM_SYNC_DIR)/charts
	helm package --destination $(HELM_SYNC_DIR)/charts $(HELM_DIR)
	helm repo index $(HELM_SYNC_DIR)

push-chart-to-registry: generate-helm-files
	mkdir -p $(HELM_REPOSITORY_CACHE)
	cp $(DOCKER_CONFIG)/config.json $(HELM_REPOSITORY_CACHE)/config.json
	HELM_EXPERIMENTAL_OCI=1 helm chart save $(HELM_DIR) gcr.io/solo-public/gloo-helm:$(VERSION)
	HELM_EXPERIMENTAL_OCI=1 helm chart push gcr.io/solo-public/gloo-helm:$(VERSION)

.PHONY: fetch-helm
fetch-helm:
	mkdir -p './_output/helm'
	gsutil -m rsync -r gs://solo-public-helm/ './_output/helm'

.PHONY: save-helm
save-helm:
ifeq ($(RELEASE),"true")
	gsutil -m rsync -r './_output/helm' gs://solo-public-helm/
endif

#----------------------------------------------------------------------------------
# Build the Gloo Manifests that are published as release assets
#----------------------------------------------------------------------------------

.PHONY: render-manifests
render-manifests: install/gloo-gateway.yaml install/gloo-ingress.yaml install/gloo-knative.yaml

INSTALL_NAMESPACE ?= gloo-system

MANIFEST_OUTPUT = > /dev/null
ifneq ($(BUILD_ID),)
MANIFEST_OUTPUT =
endif

define HELM_VALUES
namespace:
  create: true
crds:
  create: true
endef

# Export as a shell variable, make variables do not play well with multiple lines
export HELM_VALUES
$(OUTPUT_DIR)/release-manifest-values.yaml:
	@echo "$$HELM_VALUES" > $@

install/gloo-gateway.yaml: $(OUTPUT_DIR)/glooctl-linux-amd64 $(OUTPUT_DIR)/release-manifest-values.yaml package-chart
ifeq ($(RELEASE),"true")
	$(OUTPUT_DIR)/glooctl-linux-amd64 install gateway -n $(INSTALL_NAMESPACE) -f $(HELM_SYNC_DIR)/charts/gloo-$(VERSION).tgz \
		--values $(OUTPUT_DIR)/release-manifest-values.yaml --dry-run | tee $@ $(OUTPUT_YAML) $(MANIFEST_OUTPUT)
endif

install/gloo-knative.yaml: $(OUTPUT_DIR)/glooctl-linux-amd64 $(OUTPUT_DIR)/release-manifest-values.yaml package-chart
ifeq ($(RELEASE),"true")
	$(OUTPUT_DIR)/glooctl-linux-amd64 install knative -n $(INSTALL_NAMESPACE) -f $(HELM_SYNC_DIR)/charts/gloo-$(VERSION).tgz \
		--values $(OUTPUT_DIR)/release-manifest-values.yaml --dry-run | tee $@ $(OUTPUT_YAML) $(MANIFEST_OUTPUT)
endif

install/gloo-ingress.yaml: $(OUTPUT_DIR)/glooctl-linux-amd64 $(OUTPUT_DIR)/release-manifest-values.yaml package-chart
ifeq ($(RELEASE),"true")
	$(OUTPUT_DIR)/glooctl-linux-amd64 install ingress -n $(INSTALL_NAMESPACE) -f $(HELM_SYNC_DIR)/charts/gloo-$(VERSION).tgz \
		--values $(OUTPUT_DIR)/release-manifest-values.yaml --dry-run | tee $@ $(OUTPUT_YAML) $(MANIFEST_OUTPUT)
endif

#----------------------------------------------------------------------------------
# Release
#----------------------------------------------------------------------------------
GLOOE_CHANGELOGS_BUCKET=gloo-ee-changelogs

$(OUTPUT_DIR)/gloo-enterprise-version:
	GO111MODULE=on go run hack/find_latest_enterprise_version.go

.PHONY: download-glooe-changelog
download-glooe-changelog: $(OUTPUT_DIR)/gloo-enterprise-version
	mkdir -p '../solo-projects/changelog'
	gsutil -m cp -r gs://$(GLOOE_CHANGELOGS_BUCKET)/$(shell cat $(OUTPUT_DIR)/gloo-enterprise-version)/* '../solo-projects/changelog'

# The code does the proper checking for a TAGGED_VERSION
.PHONY: upload-github-release-assets
upload-github-release-assets: print-git-info build-cli render-manifests
	GO111MODULE=on go run ci/upload_github_release_assets.go $(ASSETS_ONLY_RELEASE)

.PHONY: publish-docs
publish-docs: generate-helm-files
	cd docs && make docker-push-docs \
		VERSION=$(VERSION) \
		TAGGED_VERSION=$(TAGGED_VERSION) \
		GCLOUD_PROJECT_ID=$(GCLOUD_PROJECT_ID) \
		RELEASE=$(RELEASE) \
		ON_DEFAULT_BRANCH=$(ON_DEFAULT_BRANCH)


#----------------------------------------------------------------------------------
# Docker
#----------------------------------------------------------------------------------
#
#---------
#--------- Push
#---------

DOCKER_IMAGES :=
ifeq ($(RELEASE),"true")
	DOCKER_IMAGES := docker
endif

.PHONY: docker docker-push
docker: discovery-docker gateway-docker gloo-docker \
 		gloo-envoy-wrapper-docker gloo-envoy-wasm-wrapper-docker \
 		certgen-docker ingress-docker access-logger-docker

# Depends on DOCKER_IMAGES, which is set to docker if RELEASE is "true", otherwise empty (making this a no-op).
# This prevents executing the dependent targets if RELEASE is not true, while still enabling `make docker`
# to be used for local testing.
# docker-push is intended to be run by CI
docker-push: $(DOCKER_IMAGES)
	docker push quay.io/solo-io/gateway:$(VERSION) && \
	docker push quay.io/solo-io/ingress:$(VERSION) && \
	docker push quay.io/solo-io/discovery:$(VERSION) && \
	docker push quay.io/solo-io/gloo:$(VERSION) && \
	docker push quay.io/solo-io/gloo-envoy-wrapper:$(VERSION) && \
	docker push quay.io/solo-io/gloo-envoy-wasm-wrapper:$(VERSION) && \
	docker push quay.io/solo-io/certgen:$(VERSION) && \
	docker push quay.io/solo-io/access-logger:$(VERSION)

push-kind-images: docker
	kind load docker-image quay.io/solo-io/gateway:$(VERSION) --name $(CLUSTER_NAME)
	kind load docker-image quay.io/solo-io/ingress:$(VERSION) --name $(CLUSTER_NAME)
	kind load docker-image quay.io/solo-io/discovery:$(VERSION) --name $(CLUSTER_NAME)
	kind load docker-image quay.io/solo-io/gloo:$(VERSION) --name $(CLUSTER_NAME)
	kind load docker-image quay.io/solo-io/gloo-envoy-wrapper:$(VERSION) --name $(CLUSTER_NAME)
	kind load docker-image quay.io/solo-io/certgen:$(VERSION) --name $(CLUSTER_NAME)


#----------------------------------------------------------------------------------
# Build assets for Kube2e tests
#----------------------------------------------------------------------------------
#
# The following targets are used to generate the assets on which the kube2e tests rely upon. The following actions are performed:
#
#   1. Generate Gloo value files
#   2. Package the Gloo Helm chart to the _test directory (also generate an index file)
#
# The Kube2e tests will use the generated Gloo Chart to install Gloo to the GKE test cluster.

.PHONY: build-test-assets
build-test-assets: build-test-chart $(OUTPUT_DIR)/glooctl-linux-amd64 \
 	$(OUTPUT_DIR)/glooctl-darwin-amd64

.PHONY: build-kind-assets
build-kind-assets: push-kind-images build-kind-chart $(OUTPUT_DIR)/glooctl-linux-amd64 \
 	$(OUTPUT_DIR)/glooctl-darwin-amd64

.PHONY: build-test-chart
build-test-chart:
	mkdir -p $(TEST_ASSET_DIR)
	GO111MODULE=on go run $(HELM_DIR)/generate.go --version $(VERSION)
	helm package --destination $(TEST_ASSET_DIR) $(HELM_DIR)
	helm repo index $(TEST_ASSET_DIR)

.PHONY: build-kind-chart
build-kind-chart:
	mkdir -p $(TEST_ASSET_DIR)
	GO111MODULE=on go run $(HELM_DIR)/generate.go --version $(VERSION)
	helm package --destination $(TEST_ASSET_DIR) $(HELM_DIR)
	helm repo index $(TEST_ASSET_DIR)

#----------------------------------------------------------------------------------
# Third Party License Management
#----------------------------------------------------------------------------------
.PHONY: update-licenses
update-licenses:
# TODO(helm3): fix after we completely drop toml parsing in favor of go modules
#	cd hack/utils/oss_compliance && GO111MODULE=on go run main.go