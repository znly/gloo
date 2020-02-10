
#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_ROOT=$(dirname "${BASH_SOURCE[0]}")/..
ROOT_PKG=github.com/solo-io/gloo/projects/gateway/pkg/api/v1
CLIENT_PKG=${ROOT_PKG}/kube/client
APIS_PKG=${ROOT_PKG}/kube/apis

# code-generator does work with go.mod but makes assumptions about
# the project living in $GOPATH/src. To work around this and support
# any location; create a temporary directory, use this as an output
# base, and copy everything back once generated.
TEMP_DIR=$(mktemp -d)
cleanup() {
    echo ">> Removing ${TEMP_DIR}"
    rm -rf ${TEMP_DIR}
}
trap "cleanup" EXIT SIGINT

echo ">> Temporary output directory ${TEMP_DIR}"

docker run --rm --name gloo-build -w /etc/src \
  -c $(shell expr $(shell nproc --all) - 2) \
      -v $(ROOTDIR):/etc/src:delegated quay.io/solo-io/gloo-build \
      go run generate.go && goimports -w .