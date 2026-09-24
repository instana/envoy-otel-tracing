#!/bin/bash
set -eo pipefail

set -x

SCRIPT_NAME="mk.sh"
USAGE="
DESCRIPTION
  Wraps minikube. Can start and stop minikube (--start, --stop).
  Sets up (--up) the Envoy Proxy OTel tracing demo in minikube by running the
  client app, server app, Instana agent, and the Envoy Proxy pod.
  Can pull this down again (--down) by removing all those
  services again. The idea is to handle this similarly to docker-compose.
  The --up command implies --start and starts minikube if needed.

USAGE
  ${SCRIPT_NAME} --up
  ${SCRIPT_NAME} --down
  ${SCRIPT_NAME} --start
  ${SCRIPT_NAME} --stop
  ${SCRIPT_NAME} --help

OPTIONS
  -u, --up          Starts all demo pods: client, Instana agent, Envoy Proxy, server.
  -d, --down        Stops all running demo pods.
  -s, --start       Starts minikube with KVM driver, all CPUs, 8 GB mem, and 30 GB disk.
  -S, --stop        Calls 'minikube delete'.
  --demo-down       Keeps the Instana agent running because it takes long to restart it.
"

# Where to deploy whole demo
NAMESPACE="envoy-demo"

# Run from anywhere with relative paths
SRC_DIR=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
cd "${SRC_DIR}"

# grep -q return for "pattern has been found"
FOUND=0
NOT_FOUND=1

force_success() {
  echo -n ""
}

del_resources() {
  set -x
  local ns="$1"
  kubectl delete pods --all -n "$ns"
  kubectl delete daemonsets --all -n "$ns"
  kubectl delete deployments --all -n "$ns"
  kubectl delete services --all -n "$ns"
  local i
  for ((i=0; i<10; i++)); do
    if [ "$(kubectl get pods -n $ns | wc -l | tr -d '\n')" != "0" ]; then
      kubectl get all -n "$ns"
      sleep 1
    else
      break
    fi
  done
  set +x
}

# Delete a K8s namespace
del_namespace() {
  local ns="$1"
  del_resources "$ns"

  if [ "$ns" = "instana-agent" ]; then
    return   # Skip Instana agent namespace (hangs)
  fi

  if [ "$(kubectl get pods -n $ns | wc -l | tr -d '\n')" == "0" ]; then
    kubectl delete namespace "$ns"
  fi
}

# Uninstall the Instana agent with Helm 3
uninstall_instana_agent() {
  del_resources instana-agent
  helm uninstall --namespace instana-agent instana-agent
  del_namespace instana-agent
}

# Check if pods are already running inside a given namespace.
# Detect a not yet ready or broken instana-agent-controller-manager because
# it needs to create further pods such as the actual agent pod first.
# Returns
# RC=0 : Nothing running
# RC=1 : Pods are running
# RC=2 : Pods are in bad shape - need to uninstall before install
namespace_running() {
  local ns="$1"

  # Already running?
  local pods_output=$(kubectl get pods -n $ns 2>&1)
  local num_pods=$(($(wc -l <<< ${pods_output} | tr -d '\n') - 1))
  set +e
  grep -q "Running" <<< ${pods_output}
  local found_running=$?
  local is_running=0
  # Convert "found running" to "is running"
  if [ ${found_running} -eq ${FOUND} ]; then
    is_running=1
  fi
  # instana-agent-controller-manager has not spawned pods?
  grep -q "controller-manager" <<< ${pods_output}
  local found_controller_manager=$?
  if [[ ${found_controller_manager} -eq ${FOUND} && \
       -n "${num_pods}" && ${num_pods} -eq 1 ]]; then
    RC=2
    return
  fi
  set -e
  # Pods found?
  if [[ -n "${num_pods}" && ${num_pods} -gt 0 ]]; then
    if [ ${is_running} -ne 0 ]; then
      echo "Namespace $ns is already running."
      RC=1
      return
    else       # Found pods not running?
      RC=2
      return
    fi
  fi
  RC=0
}

# Install the Instana agent with Helm 3.
#
# But check first if it is installed and running already.
# Skip installation or uninstall first in these cases. ;-)
#
# Check for 30s if the controller manager spawns further pods,
# if not, it is faulty, and a reinstall is required. Try this
# 3 times.
#
# Include the agent configuration from .env.
install_instana_agent() {
  set -x

  # The agent bring up is unreliable.
  # So try 3 times to install it properly.
  local i
  for ((i=0; i<3; i++)); do
    # Already running?
    namespace_running instana-agent
    case "$RC" in
    1)
      set +x; return; ;;
    2)
      echo "Instana agent controller manager is broken."
      uninstall_instana_agent
      set -x
      sleep 2; ;;
    *)
      ;;
    esac

    # Include agent config
    . ../.env

    # Do the actual installation
    helm install instana-agent \
    --repo https://agents.instana.io/helm \
    --namespace instana-agent \
    --create-namespace \
    --set agent.key=${agent_key} \
    --set agent.downloadKey=${agent_key} \
    --set agent.endpointHost=${agent_endpoint} \
    --set agent.endpointPort=${agent_endpoint_port} \
    --set cluster.name=${cluster_name} \
    --set zone.name="${agent_zone}" \
    --set agent.configuration_yaml="
com.instana.plugin.opentelemetry:
  enabled: true
  grpc:
    enabled: true
  http:
    enabled: false

com.instana.plugin.javatrace:
  instrumentation:
    spanBatchingEnabled: false
    " \
    instana-agent

    # First install is always broken due to whatever reason
    if [ $i -eq 0 ]; then
      sleep 5;
      continue;
    fi

    # Give the instana-agent-controller-manager 30s to start up further pods.
    # If that fails, the controller-manager is broken
    local j
    for ((j=0; j<30; j++)); do
      sleep 1
      namespace_running instana-agent
      case "$RC" in
      1)
        set +x; return; ;;
      *)
        ;;
      esac
    done
  done
  set +x
}

MINIKUBE_IS_UP=0

# Get the minikube status.
# Just return in ${MINIKUBE_IS_UP} if minikube is running (1) or down (0)
minikube_get_status() {
  set +e
  minikube status | grep -q "host: Running"
  local minikube_is_down=$?
  if [ ${minikube_is_down} -eq 0 ]; then
    MINIKUBE_IS_UP=1
  fi
  set -e
}

CPUS=$(lscpu | grep "^CPU(s):" | awk '{ print $2 }')
REGISTRY="myregistry"
REG_PORT="5000"
REGISTRY_ADDR="${REGISTRY}:${REG_PORT}"
# https://unix.stackexchange.com/a/20793 (resolve hostname to IP address):
REG_IP=$(getent hosts ${REGISTRY} | awk '{ print $1 }')
REG_ADDR=${REG_IP}:${REG_PORT}

# Check if minikube is already running.
# Start it otherwise with all CPUs, 8 GB memory, and 30 GB disk with KVM driver.
# Ensure that the configured registry is marked as insecure registry.
start_minikube() {
  minikube_get_status
  if [ ${MINIKUBE_IS_UP} -ne 0 ]; then
    echo "Minikube is already running"
    return
  fi
  echo "Starting minikube.."
  minikube start --vm-driver=kvm2 --memory=12g --cpus=${CPUS} --disk-size='30000mb' \
    --insecure-registry "10.0.0.0/24" --insecure-registry "192.168.0.0/24" \
    --insecure-registry "${REG_ADDR}"
  REG_IP_FROM_MKDOCKER=$(minikube ssh -- \
    "cat /usr/lib/systemd/system/docker.service | grep -o ${REG_IP}" \
      2> /dev/null | tr -d '\r')
  if [[ -z "${REG_IP_FROM_MKDOCKER}" || "${REG_IP_FROM_MKDOCKER}" != "${REG_IP}" ]]; then
    echo "Failed to configure local docker registry in minikube! Cry! :("
  else
    echo "Minikube configured successfully with local docker registry! Yay! :)"
  fi
}

CLIENT_APP_IMG="envoy-otel-tracing_client-app:latest"
SERVER_APP_IMG="envoy-otel-tracing_server-app:latest"
ENVOY_IMG="envoy-otel-tracing_envoy:latest"

tag_and_push_img() {
  local img="$1"
  local remote_img="${REGISTRY_ADDR}/${img}"
  docker tag ${img} ${remote_img}
  docker push ${remote_img}
}

ENVOY_CFG_YAML_IN="../envoy/envoy-gateway.yaml.in"
ENVOY_CFG_YAML_OUT=${ENVOY_CFG_YAML_IN%".in"}    # Drop .in suffix
ENVOY_CFG_SERVER_APP_YAML_IN="../server-app/envoy-server-app.yaml.in"
ENVOY_CFG_SERVER_APP_YAML_OUT=${ENVOY_CFG_SERVER_APP_YAML_IN%".in"}    # Drop .in suffix

patch_envoy_config() {
  # Set the Instana agent hostname as "hostname.namespace" (both are "instana-agent")
  export INSTANA_AGENT_HOST="instana-agent.instana-agent"
  envsubst '{$INSTANA_AGENT_HOST}' < "${ENVOY_CFG_YAML_IN}" > "${ENVOY_CFG_YAML_OUT}"
  envsubst '{$INSTANA_AGENT_HOST}' < "${ENVOY_CFG_SERVER_APP_YAML_IN}" > "${ENVOY_CFG_SERVER_APP_YAML_OUT}"
}

build_and_push_images() {
  patch_envoy_config
  pushd ..
  docker-compose build
  popd
  tag_and_push_img ${CLIENT_APP_IMG}
  tag_and_push_img ${SERVER_APP_IMG}
  tag_and_push_img ${ENVOY_IMG}
}

CLIENT_YAML_IN="client-app-deployment.yaml.in"
CLIENT_YAML_OUT=${CLIENT_YAML_IN%".in"}    # Drop .in suffix
SERVER_YAML_IN="server-app-deployment.yaml.in"
SERVER_YAML_OUT=${SERVER_YAML_IN%".in"}    # Drop .in suffix
SERVER_YAML_SERVICE="server-app-service.yaml"
ENVOY_YAML_IN="envoy-deployment.yaml.in"
ENVOY_YAML_OUT=${ENVOY_YAML_IN%".in"}    # Drop .in suffix
ENVOY_YAML_SERVICE="envoy-service.yaml"

generate_yaml() {
  echo "Generating deployment YAMLs.."
  export REG_ADDR
  envsubst '{$REG_ADDR}' < "${CLIENT_YAML_IN}" > "${CLIENT_YAML_OUT}"
  envsubst '{$REG_ADDR}' < "${SERVER_YAML_IN}" > "${SERVER_YAML_OUT}"
  envsubst '{$REG_ADDR}' < "${ENVOY_YAML_IN}" > "${ENVOY_YAML_OUT}"
}

del_deployment() {
  kubectl -n ${NAMESPACE} delete deployments.apps "$1"
}

del_service() {
  kubectl -n ${NAMESPACE} delete services "$1"
}

stop_envoy() {
  del_service envoy
  del_deployment envoy
}

stop_demo_pods() {
  set -x
  del_service server-app
  del_deployment server-app
  del_deployment client-app
  stop_envoy

  local i
  for ((i=0; i<30; i++)); do
    if [ "$(kubectl -n ${NAMESPACE} get pods | grep "envoy\|app" | wc -l | tr -d '\n')" != "0" ]; then
      kubectl -n ${NAMESPACE} get pods
      sleep 1
    else
      break
    fi
  done
  set +x
}

apply_yaml() {
  kubectl -n ${NAMESPACE} apply -f "$1"
}

create_namespace() {
  kubectl create namespace "$1"
}

run_envoy() {
  echo "Waiting for server-app before starting Envoy"
  set -x
  local i
  for ((i=0; i<30; i++)); do
    if [ "$(kubectl -n ${NAMESPACE} get pods | grep 'server-app' | grep 'Running' | wc -l | tr -d '\n')" != "0" ]; then
      break
    else
      kubectl -n ${NAMESPACE} get pods
      sleep 1
    fi
  done
  set +x
  apply_yaml ${ENVOY_YAML_OUT}
  apply_yaml ${ENVOY_YAML_SERVICE}
}

run_demo_pods() {
  create_namespace ${NAMESPACE} || force_success
  apply_yaml ${SERVER_YAML_OUT}
  apply_yaml ${SERVER_YAML_SERVICE}
  apply_yaml ${CLIENT_YAML_OUT}
  run_envoy
}

bring_down() {
  set +e
  uninstall_instana_agent
  stop_demo_pods
  del_namespace $NAMESPACE
  set -e
}

# Keep Instana agent running and keep the demo namespace
demo_down() {
  set +e
  stop_demo_pods
  set -e
}

bring_up() {
  start_minikube
  install_instana_agent
  generate_yaml
  build_and_push_images
  run_demo_pods
  set +x
  echo "Run 'kubectl get all -A' to check the Kubernetes resources."
  echo "Run 'kubectl logs -n envoy-demo deployment.apps/envoy | grep "tracing" | tail -n30' to check the Envoy Proxy OTel exporter."
  set -x
}

# Print usage text and exit.
usage() {
  echo "${USAGE}"
  exit 1
}

# Process options and call functions from there.
main() {
  # Called without option?
  if [ -z "$1" ]; then
    usage
  fi

  local options=$(getopt -o "s,S,u,d,h" -l "start,stop,up,down,demo-down,help" -- "$@")
  eval set -- "${options}"
  while true; do
    case $1 in
    -s | --start)
      start_minikube; shift;;
    -S | --stop)
      minikube delete; shift;;
    -u | --up)
      bring_up; shift;;
    -d | --down)
      bring_down; shift;;
    --demo-down)
      demo_down; shift;;
    -h | --help)
      usage;;
    --)
      shift; break;;
    esac
  done
}

############
### MAIN ###
############

main $@
