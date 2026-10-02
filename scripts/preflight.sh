#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # ok/warn/bad always return 0; JMESPath backticks are literal
# Read-only readiness checks for one environment:  ENV=prod scripts/preflight.sh. Changes nothing.
source "$(dirname "$0")/lib.sh"
need kubectl jq aws
[[ "${DEPLOY_MODE}" == "direct" ]] && need helm
FAILS=0
bad() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; FAILS=$((FAILS+1)); }

log "Kubernetes (${KUBE_CONTEXT})"
k version -o json --request-timeout=15s >/dev/null 2>&1 || die "cannot reach the cluster with context ${KUBE_CONTEXT}"
MINOR=$(k version -o json | jq -r '.serverVersion.minor' | tr -dc '0-9')
(( MINOR >= 30 )) && ok "Kubernetes 1.${MINOR} (ValidatingAdmissionPolicy is GA)" \
  || bad "Kubernetes 1.${MINOR}: need 1.30+ for ValidatingAdmissionPolicy"
k auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 && ok "you are cluster-admin" || bad "need cluster-admin to install"
READY=$(k get nodes -o json | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length')
(( READY >= 2 )) && ok "${READY} Ready nodes" || warn "${READY} Ready node(s): the gateway runs 2+ replicas spread across zones; 2+ nodes recommended"
# Capacity: the platform adds ~14 pods (+5 sample apps) and ~2 GiB of memory requests.
NEED_PODS=$([[ "${DEMO_APP}" == true ]] && echo 19 || echo 14)
NEED_MIB=2304
CAP=$(k get nodes -o json | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True")) | {p: (.status.allocatable.pods|tonumber),
  m: (.status.allocatable.memory | if endswith("Ki") then (.[:-2]|tonumber/1024) elif endswith("Mi") then (.[:-2]|tonumber) elif endswith("Gi") then (.[:-2]|tonumber*1024) else (tonumber/1048576) end)}]
  | {pods: (map(.p)|add), mib: (map(.m)|add|floor)}')
USED=$(k get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed -o json | jq '{pods: (.items|length),
  mib: ([.items[].spec.containers[].resources.requests.memory // "0" | if endswith("Ki") then (.[:-2]|tonumber/1024) elif endswith("Mi") then (.[:-2]|tonumber) elif endswith("Gi") then (.[:-2]|tonumber*1024) elif endswith("M") then (.[:-1]|tonumber) elif endswith("G") then (.[:-1]|tonumber*1000) else (tonumber/1048576) end] | add | floor)}')
FREE_PODS=$(( $(jq .pods <<<"$CAP") - $(jq .pods <<<"$USED") ))
FREE_MIB=$(( $(jq .mib <<<"$CAP") - $(jq .mib <<<"$USED") ))
if [[ -n "$(k get ns "${KAGENT_NS}" -o name 2>/dev/null)" ]]; then
  ok "capacity: ${FREE_PODS} free pod slots, ~${FREE_MIB} MiB unrequested memory (platform already partly installed)"
elif (( FREE_PODS >= NEED_PODS && FREE_MIB >= NEED_MIB )); then
  ok "capacity: ${FREE_PODS} free pod slots (need ${NEED_PODS}), ~${FREE_MIB} MiB unrequested memory (need ${NEED_MIB})"
else
  bad "capacity: ${FREE_PODS} free pod slots (need ${NEED_PODS}), ~${FREE_MIB} MiB unrequested memory (need ${NEED_MIB}). Small instances cap pods per node (t3.small = 11): add nodes such as t3.large (35 pods, 8 GiB) or enable VPC CNI prefix delegation"
fi

log "AWS: ${CLUSTER_NAME} in ${AWS_REGION}"
C=$(awsr eks describe-cluster --name "${CLUSTER_NAME}" --output json 2>/dev/null) \
  || die "aws eks describe-cluster failed (CLUSTER_NAME / AWS_REGION / AWS credentials)"
ok "EKS cluster found ($(jq -r .cluster.version <<<"$C"))"
SERVER=$(kubectl config view -o json | jq -r --arg c "${KUBE_CONTEXT}" \
  '(.contexts[] | select(.name==$c) | .context.cluster) as $cl | .clusters[] | select(.name==$cl) | .cluster.server')
[[ "$(tr '[:upper:]' '[:lower:]' <<<"${SERVER}")" == "$(jq -r .cluster.endpoint <<<"$C" | tr '[:upper:]' '[:lower:]')" ]] \
  && ok "KUBE_CONTEXT points at this EKS cluster" \
  || bad "KUBE_CONTEXT server (${SERVER}) is not ${CLUSTER_NAME}'s endpoint - wrong context?"
if [[ "${AWS_AUTH_MODE}" == "pod-identity" ]]; then
  aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" --addon-name eks-pod-identity-agent >/dev/null 2>&1 \
    && ok "eks-pod-identity-agent add-on installed" \
    || bad "eks-pod-identity-agent add-on missing: aws eks create-addon --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION} --addon-name eks-pod-identity-agent"
else
  OIDC=$(jq -r '.cluster.identity.oidc.issuer' <<<"$C" | sed 's|https://||')
  aws iam list-open-id-connect-providers --output text | grep -q "${OIDC##*/}" && ok "IAM OIDC provider exists (IRSA)" \
    || bad "no IAM OIDC provider: eksctl utils associate-iam-oidc-provider --cluster ${CLUSTER_NAME} --region ${AWS_REGION} --approve"
fi
NP=$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" --addon-name vpc-cni \
      --query 'addon.configurationValues' --output text 2>/dev/null || true)
if echo "${NP}" | grep -q '"enableNetworkPolicy": *"true"'; then ok "VPC CNI network policy enabled"
elif k get ds -n kube-system calico-node >/dev/null 2>&1 || k get ds -n calico-system calico-node >/dev/null 2>&1 || k get ds -n kube-system cilium >/dev/null 2>&1; then
  ok "NetworkPolicy enforced by Calico/Cilium"
else
  warn "No NetworkPolicy enforcement detected: the 3 NetworkPolicies will be ignored. Enable it with:"
  warn "  aws eks update-addon --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION} --addon-name vpc-cni \\"
  warn "    --configuration-values '{\"enableNetworkPolicy\": \"true\"}'"
fi
for t in api audit authenticator; do
  jq -e --arg t "$t" '[.cluster.logging.clusterLogging[] | select(.enabled) | .types[]] | index($t)' <<<"$C" >/dev/null \
    && ok "control-plane log '$t' -> CloudWatch" || warn "control-plane log '$t' off: admission denials and agent API calls won't reach CloudWatch"
done

if [[ "${KAGENT_EXTERNAL_DB}" != true ]]; then
  DEFAULT_SC=$(k get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{.provisioner}{end}' 2>/dev/null || true)
  if [[ -n "${DEFAULT_SC}" ]]; then ok "default StorageClass ${DEFAULT_SC% *} (${DEFAULT_SC#* }) for kagent's bundled PostgreSQL"
  else bad "no default StorageClass: kagent's bundled PostgreSQL volume can never bind (install the aws-ebs-csi-driver add-on and a default gp3 StorageClass - guide step 2g - or set KAGENT_EXTERNAL_DB=true)"; fi
  awsr eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name aws-ebs-csi-driver >/dev/null 2>&1 \
    && ok "aws-ebs-csi-driver add-on installed" \
    || warn "aws-ebs-csi-driver add-on not found (fine only if another CSI driver backs the default StorageClass)"
fi

log "Bedrock: ${LLM_MODEL}"
aws bedrock-runtime converse --region "${AWS_REGION}" --model-id "${LLM_MODEL}" \
   --messages '[{"role":"user","content":[{"text":"Reply OK"}]}]' --inference-config '{"maxTokens":5}' >/dev/null 2>&1 \
  && ok "your AWS identity can invoke ${LLM_MODEL}" || bad "cannot invoke ${LLM_MODEL} in ${AWS_REGION}: enable it under Bedrock > Model access"

log "Environment rules ($([[ ${IS_PROD} == true ]] && echo production || echo non-production))"
[[ -f "${DEPLOY_DIR}/platform/kustomization.yaml" ]] && ok "deploy/${ENV_NAME}/ rendered" || bad "deploy/${ENV_NAME}/ missing: make configure ENV=${ENV_NAME}"
if ${IS_PROD}; then
  [[ "${DEPLOY_MODE}" == gitops ]] && ok "GitOps only" || bad "production must use DEPLOY_MODE=gitops"
  [[ "${EGRESS_LOCKDOWN}" == true ]] && ok "egress lockdown on" || bad "production needs EGRESS_LOCKDOWN=true"
  [[ "${BEDROCK_PRIVATE_ENDPOINT}" == true ]] && ok "Bedrock over a VPC endpoint" || bad "production needs BEDROCK_PRIVATE_ENDPOINT=true"
  [[ "${KAGENT_OIDC}" == true ]] && ok "UI behind your IdP (OIDC)" || warn "KAGENT_OIDC=false: UI only via port-forward by cluster admins (fine), but no named users in kagent's records"
  [[ "${KAGENT_EXTERNAL_DB}" == true ]] && ok "external PostgreSQL" || warn "KAGENT_EXTERNAL_DB=false: conversations live in the bundled PostgreSQL pod (no backups)"
fi
if [[ "${BEDROCK_PRIVATE_ENDPOINT}" == true ]]; then
  VPC_ID=$(jq -r .cluster.resourcesVpcConfig.vpcId <<<"$C")
  [[ "$(awsr ec2 describe-vpc-attribute --vpc-id "${VPC_ID}" --attribute enableDnsHostnames --query EnableDnsHostnames.Value --output text 2>/dev/null)" == True ]] \
    && ok "VPC ${VPC_ID} has DNS hostnames on (needed for endpoint private DNS)" \
    || bad "VPC ${VPC_ID}: enableDnsHostnames is off - aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-hostnames"
  EP=$(awsr ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.bedrock-runtime" \
        --query 'VpcEndpoints[0].[VpcEndpointId,PrivateDnsEnabled]' --output text 2>/dev/null || true)
  case "${EP}" in
    *True) ok "existing bedrock-runtime endpoint ${EP%%[[:space:]]*} will be reused" ;;
    *False) bad "bedrock-runtime endpoint ${EP%%[[:space:]]*} exists with private DNS off: enable it, or pods resolve the public name and egress lockdown blocks it" ;;
    *) ok "no bedrock-runtime endpoint yet: install creates one (tagged, removed by make clean)" ;;
  esac
fi
if [[ "${EGRESS_LOCKDOWN}" == true ]]; then
  F="${DEPLOY_DIR}/platform/facts"
  if [[ -f "$F" ]]; then
    RENDERED=$(sed -n 's/^# discovered VPC_CIDRS=//p' "$F")
    LIVE=$(awsr ec2 describe-vpcs --vpc-ids "$(jq -r .cluster.resourcesVpcConfig.vpcId <<<"$C")" \
      --query 'Vpcs[0].CidrBlockAssociationSet[?CidrBlockState.State==`associated`].CidrBlock' --output text 2>/dev/null | tr '\t' ' ')
    [[ -z "${LIVE}" || "${LIVE}" == "${RENDERED}" ]] && ok "egress rules match the VPC CIDRs (${RENDERED})" \
      || bad "VPC CIDRs changed (${LIVE}) since deploy/${ENV_NAME} was rendered (${RENDERED}): make configure ENV=${ENV_NAME}"
  fi
  [[ "$(jq -r .cluster.resourcesVpcConfig.endpointPrivateAccess <<<"$C")" == true ]] && ok "API server private endpoint on" \
    || warn "API server private endpoint off: pods still reach the API through the in-VPC ENIs, but enable private access for a fully private path"
fi

log "What is already on the cluster"
if gateway_api_present; then
  ok "Gateway API $(k get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}') present (reused)"
elif k get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  [[ "${GATEWAY_API_CRDS}" == false ]] && bad "Gateway API CRDs older than v1.5 and GATEWAY_API_CRDS=false: agentgateway needs v1.5+" \
    || warn "Gateway API CRDs older than v1.5: they will be upgraded to ${GATEWAY_API_VERSION} (check other gateways on this cluster)"
else
  ok "no Gateway API CRDs yet: ${GATEWAY_API_VERSION} will be installed"
fi
if command -v helm >/dev/null 2>&1; then
  RELEASES=$(h list -A -o json 2>/dev/null || echo '[]')
  for r in agentgateway:${AGW_NS} kagent:${KAGENT_NS} kagent-tools:${TOOLS_NS} kagent-executor:${EXEC_NS} kagent-crds:${KAGENT_NS} agentgateway-crds:${AGW_NS}; do
    name="${r%%:*}" ns="${r#*:}"
    found=$(jq -r --arg n "$name" '.[] | select(.name==$n) | "\(.namespace) \(.chart)"' <<<"${RELEASES}")
    [[ -z "${found}" ]] && continue
    if [[ "${found%% *}" != "${ns}" ]]; then bad "Helm release '${name}' exists in namespace ${found%% *}: one install per cluster; remove it first"
    elif [[ "${DEPLOY_MODE}" == "direct" ]]; then ok "Helm release '${name}' (${found#* }) will be upgraded in place"
    else bad "Helm release '${name}' (${found#* }) exists: run 'helm uninstall ${name} -n ${ns}' first (CRDs are kept), or use DEPLOY_MODE=direct"
    fi
  done
fi
FOREIGN=$(k get agents.kagent.dev,modelconfigs.kagent.dev,remotemcpservers.kagent.dev -A \
  -o json 2>/dev/null | jq -r '.items[] | select((.metadata.labels["app.kubernetes.io/part-of"] // "") != "governed-sre-agent")
    | select(.metadata.name != "default-model-config" and .metadata.name != "kagent-tool-server")
    | "\(.kind) \(.metadata.namespace)/\(.metadata.name)"' || true)
if [[ -n "${FOREIGN}" ]]; then
  warn "kagent resources from an earlier install (e.g. eks-agentic-sre). The admission policies will block"
  warn "updates to any that bypass the gateway; delete them if they are not needed:"
  while read -r l; do echo "      ${l}"; done <<<"${FOREIGN}"
fi
for ns in ${APP_NAMESPACES} ${APP_NAMESPACES_READONLY}; do
  [[ "${DEMO_APP}" == true && "${ns}" == "${DEMO_NS}" ]] && continue
  k get ns "${ns}" >/dev/null 2>&1 && ok "app namespace ${ns} exists (agent RoleBindings only)" \
    || bad "namespace ${ns} (APP_NAMESPACES / APP_NAMESPACES_READONLY) does not exist"
done

if [[ "${DEPLOY_MODE}" == "gitops" ]]; then
  log "GitOps: Argo CD in '${ARGOCD_NAMESPACE}', repo ${GIT_REPO_URL}@${GIT_REVISION}"
  if k get statefulset argocd-application-controller -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
    V=$(k get deploy argocd-server -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    ok "existing Argo CD found (${V##*:}); it will be reused, not reinstalled"
  else
    ok "no Argo CD in '${ARGOCD_NAMESPACE}': ${ARGOCD_VERSION} will be installed there"
  fi
  grep -q "repoURL: ${GIT_REPO_URL}" "${DEPLOY_DIR}/gitops/root.yaml" 2>/dev/null \
    || bad "deploy/${ENV_NAME}/gitops is not configured for ${GIT_REPO_URL}: make configure ENV=${ENV_NAME}, commit and push"
  if command -v git >/dev/null 2>&1; then
    if git ls-remote --exit-code "${GIT_REPO_URL}" "${GIT_REVISION}" >/dev/null 2>&1 \
       || git ls-remote --exit-code "${GIT_REPO_URL}" "refs/tags/${GIT_REVISION}" >/dev/null 2>&1; then
      ok "${GIT_REVISION} exists in ${GIT_REPO_URL}"
      if git -C "${REPO_ROOT}" rev-parse >/dev/null 2>&1; then
        git -C "${REPO_ROOT}" diff --quiet HEAD -- "deploy/${ENV_NAME}" envs/"${ENV_NAME}".env platform helm-values 2>/dev/null \
          || bad "uncommitted changes under deploy/${ENV_NAME}, envs, platform or helm-values: Argo CD only sees what is pushed"
      fi
    else
      warn "cannot read ${GIT_REVISION} from ${GIT_REPO_URL} from here (private repo? add credentials to Argo CD: README 'Private repository')"
    fi
  fi
else
  log "Direct mode: Helm $(helm version --short 2>/dev/null)"
fi

log "Preflight: ${FAILS} blocking issue(s)"
(( FAILS == 0 ))
