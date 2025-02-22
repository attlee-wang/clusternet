#!/usr/bin/env bash

# Copyright 2021 The Clusternet Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

PLATFORMS=${PLATFORMS:-linux/amd64}
CGO_ENABLED=${CGO_ENABLED:-0}

readonly CLUSTERNET_ROOT=$(dirname "${BASH_SOURCE[0]}")/../..

source "${CLUSTERNET_ROOT}/hack/lib/version.sh"

function abspath() {
  # run in a subshell for simpler 'cd'
  (
    if [[ -d "${1}" ]]; then # This also catch symlinks to dirs.
      cd "${1}"
      pwd -P
    else
      cd "$(dirname "${1}")"
      local f
      f=$(basename "${1}")
      if [[ -L "${f}" ]]; then
        readlink "${f}"
      else
        echo "$(pwd -P)/${f}"
      fi
    fi
  )
}

clusternet::golang::setup_platform() {
  local platform=$1

  local goos
  local goarch

  case "${platform}" in
    "darwin/amd64")
      goos=darwin
      goarch=amd64
      ;;
    "darwin/arm64")
      goos=darwin
      goarch=arm64
      ;;
    "linux/amd64")
      goos=linux
      goarch=amd64
      ;;
    "linux/arm")
      goos=linux
      goarch=arm
      ;;
    "linux/arm64")
      goos=linux
      goarch=arm64
      ;;
    "linux/ppc64le")
      goos=linux
      goarch=ppc64le
      ;;
    "linux/s390x")
      goos=linux
      goarch=s390x
      ;;
    "linux/386")
      goos=linux
      goarch=386
      ;;
    *)
      echo "Unsupported platform. Must be in darwin/amd64, darwin/arm64, linux/amd64, linux/arm, linux/arm64, linux/ppc64le, linux/s390x, linux/386"
      exit 1
      ;;
  esac

  export GOOS=${goos}
  export GOARCH=${goarch}
}

clusternet::golang::build_binary() {
  clusternet::golang::verify_golang
  # Create a sub-shell so that we don't pollute the outer environment
  (
    echo "Building with $(go version)"

    local goldflags
    goldflags="$(clusternet::version::ldflags)"

    local platform=$1
    clusternet::golang::setup_platform "${platform}"

    local target=$2
    echo "Building cmd/${target} binary for ${platform} ..."

    GOOS=${GOOS} GOARCH=${GOARCH} \
      CGO_ENABLED=${CGO_ENABLED-} \
      GOPATH="$(abspath ${CLUSTERNET_ROOT}/../../../../)" \
      go build -ldflags "$goldflags" -o ./_output/${platform}/bin/${target} ./cmd/${target}/
  )
}

# Ensure the go tool exists and is a viable version.
clusternet::golang::verify_golang() {
  if [[ -z "$(command -v go)" ]]; then
    echo """
Can't find 'go' in PATH, please fix and retry.
See http://golang.org/doc/install for installation instructions.
"""
    return 2
  fi
}

# Asks golang what it thinks the host platform is.
clusternet::docker::host_platform() {
  if [[ "$(go env GOHOSTOS)" == "darwin" ]]; then
    echo "linux/$(go env GOHOSTARCH)"
  else
    echo "$(go env GOHOSTOS)/$(go env GOHOSTARCH)"
  fi
}

clusternet::docker::image() {
  # Create a sub-shell so that we don't pollute the outer environment
  (
    local platform=$1
    clusternet::golang::setup_platform "${platform}"

    local CGO_ENABLED=0
    local CC=""
    local LDFLAGS="$(clusternet::version::ldflags)"
    local CCPKG=""

    # Do not set CC when building natively on a platform, only if cross-compiling
    if [[ $(clusternet::docker::host_platform) != "$platform" ]]; then
      # Dynamic CGO linking for other server architectures than host architecture goes here
      # If you want to include support for more server platforms than these, add arch-specific gcc names here
      LDFLAGS+="-linkmode=external -w -extldflags=-static"
      case "${platform}" in
        "linux/amd64")
          CGO_ENABLED=1
          CC=x86_64-linux-gnu-gcc
          CCPKG=gcc-x86-64-linux-gnu
          ;;
        "linux/arm")
          CGO_ENABLED=1
          CC=arm-linux-gnueabihf-gcc
          CCPKG=gcc-arm-linux-gnueabihf
          ;;
        "linux/arm64")
          CGO_ENABLED=1
          CC=aarch64-linux-gnu-gcc
          CCPKG=gcc-aarch64-linux-gnu
          ;;
        "linux/ppc64le")
          CGO_ENABLED=1
          CC=powerpc64le-linux-gnu-gcc
          CCPKG=gcc-powerpc64le-linux-gnu
          ;;
        "linux/s390x")
          CGO_ENABLED=1
          CC=s390x-linux-gnu-gcc
          CCPKG=gcc-s390x-linux-gnu
          ;;
        "linux/386")
          CGO_ENABLED=1
          CC=i686-linux-gnu-gcc
          CCPKG=gcc-i686-linux-gnu
          ;;
        *)
          echo "Unsupported platforms. Must be in linux/amd64, linux/arm, linux/arm64, linux/ppc64le, linux/s390x, linux/386"
          exit 1
          ;;
      esac
    fi

    local target=$2
    tag=$(git describe --tags --always)
    echo "Building docker image ${REGISTRY}/clusternet/${target}-${GOARCH}:${tag} ..."

    docker buildx build \
      --load \
      -t ${REGISTRY}/clusternet/"${target}"-${GOARCH}:"${tag}" \
      --build-arg BASEIMAGE="${BASEIMAGE}" \
      --build-arg GOVERSION="${GOVERSION}" \
      --build-arg GOARCH="${GOARCH}" \
      --build-arg CGO_ENABLED="${CGO_ENABLED}" \
      --build-arg CC="${CC}" \
      --build-arg CCPKG=${CCPKG} \
      --build-arg LDFLAGS="${LDFLAGS}" \
      --build-arg PKGNAME="${target}" \
      --build-arg PLATFORM="${platform}" .
  )
}
