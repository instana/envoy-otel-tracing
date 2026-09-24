#!/bin/bash

set -eo pipefail
set -x

# Run from anywhere with relative paths
SRC_DIR=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
cd "${SRC_DIR}"

# Patch the INSTANA_AGENT_HOST env var into envoy-gateway.yaml
export INSTANA_AGENT_HOST="instana-agent"
envsubst '{$INSTANA_AGENT_HOST}' < "./envoy/envoy-gateway.yaml.in" > "./envoy/envoy-gateway.yaml"

# Run the demo
docker-compose down && docker-compose up --build
