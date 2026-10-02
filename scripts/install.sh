#!/usr/bin/env bash
# Installs one environment on its existing EKS cluster:   ENV=prod scripts/install.sh
#   DEPLOY_MODE=gitops : Argo CD (existing or new) + root app; Argo CD pulls deploy/<env>/ from Git.
#   DEPLOY_MODE=direct : the same charts, values and manifests via Helm + kubectl (non-prod only).
# Then scripts/aws-setup.sh: VPC endpoint (if enabled), IAM role, pod identity association.
source "$(dirname "$0")/lib.sh"
need kubectl aws jq
[[ -f "${DEPLOY_DIR}/gitops/root.yaml" ]] || die "deploy/${ENV_NAME}/ not rendered: run make configure ENV=${ENV_NAME}"
if ${IS_PROD} && [[ "${DEPLOY_MODE}" != gitops ]]; then die "production installs are GitOps only (DEPLOY_MODE=gitops)"; fi

install_gitops() {
  grep -q "repoURL: ${GIT_REPO_URL}" "${DEPLOY_DIR}/gitops/root.yaml" \
    || die "deploy/${ENV_NAME}/gitops is not configured for ${GIT_REPO_URL}. Run make configure ENV=${ENV_NAME}, commit and push first."

  if k get statefulset argocd-application-controller -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
    log "Argo CD: reusing the existing install in '${ARGOCD_NAMESPACE}' (not modified)"
  else
    log "Argo CD ${ARGOCD_VERSION} -> '${ARGOCD_NAMESPACE}' (manages this cluster only)"
    k create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | k apply -f -
    k label namespace "${ARGOCD_NAMESPACE}" sre-agent/installed-argocd=true --overwrite >/dev/null
    k apply -n "${ARGOCD_NAMESPACE}" --server-side --force-conflicts \
      -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
    k rollout status -n "${ARGOCD_NAMESPACE}" deploy/argocd-repo-server --timeout=300s
    k rollout status -n "${ARGOCD_NAMESPACE}" statefulset/argocd-application-controller --timeout=300s
    # Only on an Argo CD we installed: let sync waves wait for child Applications to be Healthy.
    k patch configmap argocd-cm -n "${ARGOCD_NAMESPACE}" --type merge -p "$(cat <<'EOF'
{"data":{"resource.customizations.health.argoproj.io_Application":"hs = {}\nhs.status = \"Progressing\"\nhs.message = \"\"\nif obj.status ~= nil and obj.status.health ~= nil then\n  hs.status = obj.status.health.status\n  if obj.status.health.message ~= nil then hs.message = obj.status.health.message end\nend\nreturn hs\n"}}
EOF
)"
    k rollout restart -n "${ARGOCD_NAMESPACE}" statefulset/argocd-application-controller
    ok "Argo CD ready"
  fi

  log "AppProject 'sre-agent' + root application (deploy/${ENV_NAME}/gitops)"
  k apply -f "${DEPLOY_DIR}/gitops/project.yaml"
  k apply -f "${DEPLOY_DIR}/gitops/root.yaml"
  log "Waiting for Argo CD to sync the platform (first run: ~5-10 min)"
  wait_for "agentgateway proxy deployment exists" 900 k get deploy "${GATEWAY_NAME}" -n "${AGW_NS}"
}

install_direct() {
  need helm
  if [[ "$(want_gateway_api_crds)" == true ]]; then
    log "Gateway API ${GATEWAY_API_VERSION} CRDs"
    k apply --server-side --force-conflicts \
      -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  else
    log "Gateway API CRDs: keeping the cluster's own (v1.5+)"
  fi

  log "CRDs: agentgateway ${AGENTGATEWAY_VERSION}, kagent ${KAGENT_VERSION}"
  h upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
    --version "${AGENTGATEWAY_VERSION}" -n "${AGW_NS}" --create-namespace --wait
  h upgrade -i kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
    --version "${KAGENT_VERSION}" -n "${KAGENT_NS}" --create-namespace --wait

  log "agentgateway control plane"
  h upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway --version "${AGENTGATEWAY_VERSION}" \
    -n "${AGW_NS}" -f "${REPO_ROOT}/helm-values/agentgateway.yaml" --wait

  log "Namespaces with Pod Security labels (enforce baseline, audit + warn restricted)"
  local ns
  for ns in "${PLATFORM_NAMESPACES[@]}"; do
    k create namespace "${ns}" --dry-run=client -o yaml | k apply -f - >/dev/null
    k label namespace "${ns}" --overwrite pod-security.kubernetes.io/enforce=baseline \
      pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted >/dev/null
  done

  log "OpenTelemetry collector"
  h upgrade -i otel-collector opentelemetry-collector \
    --repo https://open-telemetry.github.io/opentelemetry-helm-charts --version "${OTEL_COLLECTOR_VERSION}" \
    -n "${OBS_NS}" -f "${REPO_ROOT}/helm-values/otel-collector.yaml" -f "${DEPLOY_DIR}/values/otel-collector.yaml" --wait

  log "kagent-tools (read-only diagnostics) and kagent-executor (restart/scale)"
  h upgrade -i kagent-tools oci://ghcr.io/kagent-dev/tools/helm/kagent-tools --version "${KAGENT_TOOLS_VERSION}" \
    -n "${TOOLS_NS}" -f "${REPO_ROOT}/helm-values/kagent-tools.yaml" --wait
  h upgrade -i kagent-executor oci://ghcr.io/kagent-dev/tools/helm/kagent-tools --version "${KAGENT_TOOLS_VERSION}" \
    -n "${EXEC_NS}" -f "${REPO_ROOT}/helm-values/kagent-executor.yaml" --wait

  log "kagent"
  local vals=(-f "${REPO_ROOT}/helm-values/kagent.yaml" -f "${DEPLOY_DIR}/values/kagent.yaml")
  [[ "${KAGENT_OIDC}" == true ]] && vals+=(-f "${REPO_ROOT}/helm-values/optional/kagent-oidc.yaml")
  [[ "${KAGENT_EXTERNAL_DB}" == true ]] && vals+=(-f "${REPO_ROOT}/helm-values/optional/kagent-external-postgres.yaml")
  h upgrade -i kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent --version "${KAGENT_VERSION}" \
    -n "${KAGENT_NS}" "${vals[@]}" --wait --timeout 10m

  log "Platform: gateway, routes, policies, RBAC, NetworkPolicies, admission, agent (deploy/${ENV_NAME}/platform)"
  k apply --server-side --force-conflicts -k "${DEPLOY_DIR}/platform"
  if [[ "${DEMO_APP}" == true ]]; then
    log "Sample apps in ${DEMO_NS} (DEMO_APP=true)"
    k apply -k "${DEPLOY_DIR}/demo"
  fi
  wait_for "agentgateway proxy deployment exists" 300 k get deploy "${GATEWAY_NAME}" -n "${AGW_NS}"
}

case "${DEPLOY_MODE}" in
  gitops) install_gitops ;;
  direct) install_direct ;;
  *) die "DEPLOY_MODE must be gitops or direct" ;;
esac
k rollout status deploy/"${GATEWAY_NAME}" -n "${AGW_NS}" --timeout=300s

log "AWS: Bedrock endpoint, IAM role, pod identity (the gateway is the only workload allowed to call the model)"
"${REPO_ROOT}/scripts/aws-setup.sh"

wait_for "kagent-tools ready"     600 k rollout status deploy/kagent-tools -n "${TOOLS_NS}" --timeout=10s
wait_for "kagent-executor ready"  600 k rollout status deploy/kagent-executor -n "${EXEC_NS}" --timeout=10s
wait_for "sre-triage-agent Ready" 900 bash -c "kubectl --context '${KUBE_CONTEXT}' get agent sre-triage-agent -n ${KAGENT_NS} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True"

if [[ "${DEPLOY_MODE}" == gitops ]]; then
  log "Argo CD applications"
  k get applications -n "${ARGOCD_NAMESPACE}" \
    -o custom-columns='APP:.metadata.name,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,SYNC:.status.sync.status,HEALTH:.status.health.status' \
    | awk 'NR==1 || $1 ~ /^sre-agent-/'
fi
ok "Installed. Next: make verify ENV=${ENV_NAME}"
