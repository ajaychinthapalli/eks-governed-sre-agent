#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # ok/warn always return 0; JMESPath backticks are literal
# Removes one environment's SRE agent platform and its AWS resources:  ENV=dev scripts/cleanup.sh
# Only touches what this repo created: your app namespaces keep everything except the agent's
# RoleBindings, an Argo CD that existed before is left running, a VPC endpoint that existed
# before is left alone, and Gateway API CRDs are kept.
source "$(dirname "$0")/lib.sh"
need kubectl aws

if ${IS_PROD}; then
  read -r -p "PRODUCTION. Type the cluster name (${CLUSTER_NAME}) to remove the SRE agent platform: " a
  [[ "$a" == "${CLUSTER_NAME}" ]] || { echo "aborted"; exit 1; }
else
  read -r -p "Remove the SRE agent platform from ${CLUSTER_NAME} (${KUBE_CONTEXT})? [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] || exit 0
fi

if k get application sre-agent-root -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
  log "Argo CD: delete sre-agent-root (cascades to every sre-agent-* app and its resources)"
  # Detach the Gateway API CRDs app first so its resources (the CRDs) are not deleted.
  k patch application sre-agent-gateway-api-crds -n "${ARGOCD_NAMESPACE}" --type json \
    -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  k delete application sre-agent-gateway-api-crds -n "${ARGOCD_NAMESPACE}" --ignore-not-found --wait=true || true
  k delete application sre-agent-root -n "${ARGOCD_NAMESPACE}" --wait=true --timeout=15m || true
  k delete appproject sre-agent -n "${ARGOCD_NAMESPACE}" --ignore-not-found
  for s in agentgateway kagent kagent-tools; do k delete secret "sre-agent-repo-${s}-oci" -n "${ARGOCD_NAMESPACE}" --ignore-not-found >/dev/null; done
fi

if command -v helm >/dev/null 2>&1; then
  log "Helm releases (direct mode)"
  [[ -d "${DEPLOY_DIR}/demo" ]] && { k delete -k "${DEPLOY_DIR}/demo" --ignore-not-found 2>/dev/null || true; }
  k delete -k "${DEPLOY_DIR}/platform" --ignore-not-found --wait=false 2>/dev/null || true
  for r in kagent:${KAGENT_NS} kagent-tools:${TOOLS_NS} kagent-executor:${EXEC_NS} otel-collector:${OBS_NS} agentgateway:${AGW_NS} \
           kagent-crds:${KAGENT_NS} agentgateway-crds:${AGW_NS}; do
    h uninstall "${r%%:*}" -n "${r#*:}" --wait 2>/dev/null && ok "uninstalled ${r%%:*}" || true
  done
fi

log "Namespaces created by this repo"
k delete namespace "${PLATFORM_NAMESPACES[@]}" --ignore-not-found --wait=false
if [[ "${DEMO_APP}" == true ]]; then k delete namespace "${DEMO_NS}" --ignore-not-found --wait=false; fi
for ns in ${APP_NAMESPACES} ${APP_NAMESPACES_READONLY}; do
  k delete rolebinding sre-agent-read sre-agent-remediate -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true
done
k delete validatingadmissionpolicybinding,validatingadmissionpolicy -l app.kubernetes.io/part-of=governed-sre-agent --ignore-not-found
k delete clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=governed-sre-agent --ignore-not-found

log "AWS: pod identity association, IAM role ${GATEWAY_IAM_ROLE_NAME}, endpoints created by this repo"
for id in $(awsr eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
              --namespace "${AGW_NS}" --query 'associations[].associationId' --output text 2>/dev/null); do
  awsr eks delete-pod-identity-association --cluster-name "${CLUSTER_NAME}" --association-id "$id" >/dev/null
done
EPS=$(awsr ec2 describe-vpc-endpoints --filters "Name=tag:sre-agent/cluster,Values=${CLUSTER_NAME}" \
        --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)
if [[ -n "${EPS}" ]]; then
  # shellcheck disable=SC2086  # list of ids
  awsr ec2 delete-vpc-endpoints --vpc-endpoint-ids ${EPS} >/dev/null && ok "deleted VPC endpoints ${EPS}"
  for _ in $(seq 1 40); do
    # shellcheck disable=SC2086
    [[ -z "$(awsr ec2 describe-vpc-endpoints --vpc-endpoint-ids ${EPS} --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' --output text 2>/dev/null)" ]] && break
    sleep 15
  done
fi
for sg in $(awsr ec2 describe-security-groups --filters "Name=tag:sre-agent/cluster,Values=${CLUSTER_NAME}" \
              --query 'SecurityGroups[].GroupId' --output text 2>/dev/null); do
  awsr ec2 delete-security-group --group-id "${sg}" 2>/dev/null && ok "deleted security group ${sg}" || warn "security group ${sg} still in use; delete it later"
done
aws iam delete-role-policy --role-name "${GATEWAY_IAM_ROLE_NAME}" --policy-name "${GATEWAY_IAM_ROLE_NAME}-invoke" 2>/dev/null || true
aws iam delete-role --role-name "${GATEWAY_IAM_ROLE_NAME}" 2>/dev/null || true
ok "IAM role and pod identity association removed"

if [[ "$(k get ns "${ARGOCD_NAMESPACE}" -o jsonpath='{.metadata.labels.sre-agent/installed-argocd}' 2>/dev/null)" == true ]]; then
  read -r -p "Argo CD in '${ARGOCD_NAMESPACE}' was installed by this repo. Remove it too? [y/N] " b
  [[ "$b" =~ ^[Yy]$ ]] && k delete namespace "${ARGOCD_NAMESPACE}" --wait=false
fi
ok "Cleanup complete. Gateway API CRDs were kept (other gateways may use them)."
