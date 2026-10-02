#!/usr/bin/env bash
# shellcheck disable=SC2034  # constants here are used by the scripts that source this file
# Shared helpers. Every script runs against ONE environment:  ENV=prod scripts/<x>.sh
set -euo pipefail
# Written for bash 3.2 (macOS default) and later: no mapfile, no ${x,,}, no associative arrays.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME="${ENV:-}"
if [[ -z "${ENV_NAME}" ]]; then
  envs=("${REPO_ROOT}"/envs/*.env); envs=("${envs[@]##*/}")
  echo "Set the environment: ENV=<name>, one of: ${envs[*]%.env}" >&2; exit 2
fi
ENV_FILE="${REPO_ROOT}/envs/${ENV_NAME}.env"
[[ -f "${ENV_FILE}" ]] || { echo "Missing ${ENV_FILE}. Copy envs/dev.env (non-prod) or envs/prod.env and edit it." >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
export ENV_NAME

: "${APP_NAMESPACES:=}" "${APP_NAMESPACES_READONLY:=}" "${DEMO_APP:=false}" "${MAX_REPLICAS:=10}"
: "${LLM_TOKENS_PER_MINUTE:=400000}" "${LLM_REQUESTS_PER_MINUTE:=120}"
: "${DEPLOY_MODE:=gitops}" "${ARGOCD_NAMESPACE:=argocd}" "${GATEWAY_API_CRDS:=auto}" "${CENTRAL_OTLP_ENDPOINT:=}"
: "${KAGENT_OIDC:=false}" "${KAGENT_EXTERNAL_DB:=false}" "${ENVIRONMENT:=nonprod}" "${AWS_AUTH_MODE:=pod-identity}"
: "${GIT_REVISION:=main}" "${EGRESS_LOCKDOWN:=true}" "${BEDROCK_PRIVATE_ENDPOINT:=false}" "${BREAKGLASS_GROUPS:=system:masters}"
export APP_NAMESPACES APP_NAMESPACES_READONLY DEMO_APP MAX_REPLICAS LLM_TOKENS_PER_MINUTE LLM_REQUESTS_PER_MINUTE DEPLOY_MODE ARGOCD_NAMESPACE GATEWAY_API_CRDS \
       CENTRAL_OTLP_ENDPOINT KAGENT_OIDC KAGENT_EXTERNAL_DB ENVIRONMENT AWS_AUTH_MODE GIT_REVISION EGRESS_LOCKDOWN \
       BEDROCK_PRIVATE_ENDPOINT BREAKGLASS_GROUPS

DEPLOY_DIR="${REPO_ROOT}/deploy/${ENV_NAME}"
AGW_NS="agentgateway-system"
KAGENT_NS="kagent"
TOOLS_NS="kagent-tools"
EXEC_NS="kagent-executor"
OBS_NS="sre-observability"
DEMO_NS="${DEMO_NAMESPACE:-shop-demo}"   # namespace the sample apps go into (DEMO_APP=true)
PLATFORM_NAMESPACES=("${AGW_NS}" "${KAGENT_NS}" "${TOOLS_NS}" "${EXEC_NS}" "${OBS_NS}")
GATEWAY_NAME="agentgateway-proxy"
GW_URL="http://${GATEWAY_NAME}.${AGW_NS}.svc.cluster.local"
TOOLS_SA="system:serviceaccount:${TOOLS_NS}:kagent-tools"
EXEC_SA="system:serviceaccount:${EXEC_NS}:kagent-executor"
IS_PROD=false; [[ "${ENVIRONMENT}" == prod ]] && IS_PROD=true

# Pinned versions (checked 2026-10-01). Change here, then `make configure` for every env.
ARGOCD_VERSION="v3.5.3"
GATEWAY_API_VERSION="v1.6.0"
AGENTGATEWAY_VERSION="v1.5.0"
KAGENT_VERSION="0.10.1"
KAGENT_TOOLS_VERSION="0.3.0"
OTEL_COLLECTOR_VERSION="0.174.0"
VERSIONS_JSON=$(printf '{"gateway_api":"%s","agentgateway":"%s","kagent":"%s","kagent_tools":"%s","otel_collector":"%s"}' \
  "${GATEWAY_API_VERSION}" "${AGENTGATEWAY_VERSION}" "${KAGENT_VERSION}" "${KAGENT_TOOLS_VERSION}" "${OTEL_COLLECTOR_VERSION}")
export VERSIONS_JSON

log()  { printf '\n\033[1;34m==> [%s] %s\033[0m\n' "${ENV_NAME}" "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

need() { for b in "$@"; do command -v "$b" >/dev/null 2>&1 || die "'$b' is required but not installed"; done; }

# Always target this environment's cluster explicitly; never rely on the current context.
k() { kubectl --context "${KUBE_CONTEXT}" "$@"; }
h() { helm --kube-context "${KUBE_CONTEXT}" "$@"; }
awsr() { aws --region "${AWS_REGION}" "$@"; }

proxy_service_account() {
  k get deploy "${GATEWAY_NAME}" -n "${AGW_NS}" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true
}

# True if the cluster already serves Gateway API CRDs at bundle-version >= v1.5.
gateway_api_present() {
  local ver
  ver=$(k get crd gateways.gateway.networking.k8s.io \
        -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || true)
  [[ -n "$ver" ]] || return 1
  ver="${ver#v}"
  local major="${ver%%.*}" rest="${ver#*.}"
  local minor="${rest%%.*}"
  (( major > 1 || (major == 1 && minor >= 5) ))
}

want_gateway_api_crds() {  # resolves GATEWAY_API_CRDS=auto against the live cluster: true|false
  case "${GATEWAY_API_CRDS}" in
    true|false) echo "${GATEWAY_API_CRDS}" ;;
    *) if gateway_api_present; then echo false; else echo true; fi ;;
  esac
}

cluster_vpc_id() { awsr eks describe-cluster --name "${CLUSTER_NAME}" --query cluster.resourcesVpcConfig.vpcId --output text; }

wait_for() {  # wait_for <description> <seconds> <command...>
  local what="$1" secs="$2"; shift 2
  local end=$((SECONDS + secs))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS >= end )) && die "timed out after ${secs}s waiting for ${what}"
    sleep 10
  done
  ok "${what}"
}
