#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # ok/warn always return 0; JMESPath backticks are literal
# Renders envs/<env>.env into deploy/<env>/. Re-run after any change to the env file, review
# `git diff deploy/<env>`, then commit (and push, for GitOps).
#   ENV=prod scripts/configure.sh
# Reads two facts from the live environment (skip by setting them in the env file):
#   VPC_CIDRS        the cluster VPC's CIDR blocks (egress rules for the API server / VPC endpoints)
#   KUBE_API_SVC_IP  the ClusterIP of default/kubernetes
source "$(dirname "$0")/lib.sh"
need python3

log "Discovering facts about ${CLUSTER_NAME}"
REACHABLE=false
command -v kubectl >/dev/null 2>&1 && k version --request-timeout=10s >/dev/null 2>&1 && REACHABLE=true
if [[ -z "${VPC_CIDRS:-}" ]]; then
  if command -v aws >/dev/null 2>&1 && VPC=$(cluster_vpc_id 2>/dev/null) && [[ -n "${VPC}" && "${VPC}" != None ]]; then
    VPC_CIDRS=$(awsr ec2 describe-vpcs --vpc-ids "${VPC}" \
      --query 'Vpcs[0].CidrBlockAssociationSet[?CidrBlockState.State==`associated`].CidrBlock' --output text | tr '\t' ' ')
    ok "VPC ${VPC}: ${VPC_CIDRS}"
  elif [[ -f "${DEPLOY_DIR}/platform/facts" ]]; then
    VPC_CIDRS=$(sed -n 's/^# discovered VPC_CIDRS=//p' "${DEPLOY_DIR}/platform/facts")
    [[ -n "${VPC_CIDRS}" ]] && warn "AWS not reachable: reusing VPC_CIDRS=${VPC_CIDRS} from the last configure"
  fi
fi
[[ "${EGRESS_LOCKDOWN}" == true && -z "${VPC_CIDRS:-}" ]] && die "EGRESS_LOCKDOWN=true needs VPC_CIDRS: run with AWS access, or set VPC_CIDRS=\"10.0.0.0/16\" in envs/${ENV_NAME}.env"
if [[ -z "${KUBE_API_SVC_IP:-}" ]]; then
  if ${REACHABLE}; then
    KUBE_API_SVC_IP=$(k get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
    ok "kubernetes Service ClusterIP ${KUBE_API_SVC_IP}"
  elif [[ -f "${DEPLOY_DIR}/platform/facts" ]]; then
    KUBE_API_SVC_IP=$(sed -n 's/^# discovered KUBE_API_SVC_IP=//p' "${DEPLOY_DIR}/platform/facts")
  fi
fi
if ${REACHABLE}; then
  GW_CRDS=$(want_gateway_api_crds)
  [[ "${GW_CRDS}" == true ]] && ok "Gateway API ${GATEWAY_API_VERSION} CRDs will be installed" || ok "cluster already has Gateway API v1.5+: left alone"
elif [[ "${GATEWAY_API_CRDS}" != auto ]]; then
  GW_CRDS="${GATEWAY_API_CRDS}"
else
  GW_CRDS=$(sed -n 's/^# discovered GW_CRDS=//p' "${DEPLOY_DIR}/platform/facts" 2>/dev/null || true)
  GW_CRDS="${GW_CRDS:-true}"
  warn "cluster not reachable: Gateway API CRDs install=${GW_CRDS} (last known / default)"
fi
export VPC_CIDRS KUBE_API_SVC_IP GW_CRDS

log "Rendering deploy/${ENV_NAME}/ ($([[ ${IS_PROD} == true ]] && echo 'production rules ON' || echo non-production))"
python3 "${REPO_ROOT}/scripts/render.py"
printf '# Facts read from the live environment at the last configure (reused when offline).\n# discovered VPC_CIDRS=%s\n# discovered KUBE_API_SVC_IP=%s\n# discovered GW_CRDS=%s\n' \
  "${VPC_CIDRS:-}" "${KUBE_API_SVC_IP:-}" "${GW_CRDS}" > "${DEPLOY_DIR}/platform/facts"

if [[ "${DEPLOY_MODE}" == gitops ]]; then
  [[ "${GIT_REVISION}" =~ ^(main|master)$ ]] && warn "GIT_REVISION=${GIT_REVISION}: this environment follows the branch; pin a tag to control rollouts"
  log "Next: review, commit, tag (prod) and push - Argo CD reads from Git"
  echo "      git add -A && git commit -m 'configure ${ENV_NAME}' && git push"
  ${IS_PROD} && echo "      git tag ${GIT_REVISION} && git push origin ${GIT_REVISION}"
  echo "      make preflight install verify ENV=${ENV_NAME}"
else
  log "Next: make preflight install verify ENV=${ENV_NAME}"
fi
