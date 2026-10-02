#!/usr/bin/env bash
# Guided walkthrough (needs DEMO_APP=true). Port-forwards the kagent UI and the
# agentgateway admin UI ("Port-forward for development" in the diagram).
source "$(dirname "$0")/lib.sh"
need kubectl
[[ "${DEMO_APP}" == true ]] || die "the demo needs DEMO_APP=true in envs/${ENV_NAME}.env (non-production)"

UI_PORT=8082
AGW_PORT=15000
PIDS=()
stop_forwards() { local p; for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap stop_forwards EXIT
pause() { read -r -p $'\n  Press Enter to continue... ' _; }

log "kagent UI       -> http://localhost:${UI_PORT}"
k port-forward -n "${KAGENT_NS}" svc/kagent-ui "${UI_PORT}":8080 >/dev/null 2>&1 & PIDS+=($!)
log "agentgateway UI -> http://localhost:${AGW_PORT}/ui/"
k port-forward -n "${AGW_NS}" deploy/"${GATEWAY_NAME}" "${AGW_PORT}":15000 >/dev/null 2>&1 & PIDS+=($!)
sleep 3

cat <<EOF

  SCENE 1 - Triage
  ----------------
  Open "sre-triage-agent" and ask:
      What is broken in the ${DEMO_NS} namespace? Find the root cause for each failing workload.
  Expect, with quoted evidence:
    checkout     CrashLoopBackOff -> env var PAYMENTS_API_URL missing     (logs)
    catalog      ImagePullBackOff -> image tag typo "1.27-alpne"          (events)
    recommender  OOMKilled        -> needs ~200Mi, limit is 64Mi          (last state)
    frontend     healthy
EOF
pause
cat <<'EOF'

  SCENE 2 - Human approval and hard limits
  ----------------------------------------
      Restart the checkout deployment.     -> kagent pauses for YOUR approval (k8s_rollout);
                                              approve it, the agent then checks it with k8s_wait
                                              (it will tell you a restart can't fix a missing env var)
      Scale frontend to 50 replicas.       -> even if you approve, the API server rejects it
                                              (remediation guard: at most double, at most MAX_REPLICAS)
      Fix the catalog image tag.           -> no tool can change an image (allowlist + admission);
                                              the agent gives you the exact change to make
      Delete the catalog deployment.       -> no delete tool exists for the agent (gateway allowlist)
      Show me the pods in kube-system.     -> RBAC: the tool server can only see granted namespaces
EOF
pause

log "SCENE 3 - Credential leak stopped at the gateway"
sed "s/namespace: shop-demo/namespace: ${DEMO_NS}/" "${REPO_ROOT}/apps/demo-shop/leaky-logs.yaml" | k apply -f -
echo "      deployed ${DEMO_NS}/legacy-billing (its logs print a fake AWS key); waiting 30s..."
sleep 30
cat <<'EOF'
  Ask:
      Why is legacy-billing failing? Check its logs.
  The agent reads the logs and tries to send them to the model; agentgateway sees the
  AKIA... key and rejects the call (403). The credential never leaves the cluster.
EOF
pause
k logs -n "${AGW_NS}" -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" --tail=300 \
  | grep -E '"http.status":403|status=403' | tail -n 3 || echo "      (no 403 yet - ask the agent first)"

log "SCENE 4 - Telemetry and audit"
cat <<EOF
  Every LLM and MCP call is a span tagged k8s.cluster.name=${CLUSTER_NAME}, sent to
  ${CENTRAL_OTLP_ENDPOINT:-the collector log (CENTRAL_OTLP_ENDPOINT not set)}.
  Local look:  kubectl --context ${KUBE_CONTEXT} logs -n ${OBS_NS} deploy/opentelemetry-collector | tail
  Every write the agent made (or tried) is in the EKS audit log as
  user.username = ${EXEC_SA}; in CloudWatch Logs Insights on /aws/eks/${CLUSTER_NAME}/cluster:
    fields @timestamp, verb, objectRef.resource, objectRef.name, responseStatus.code
    | filter user.username = "${EXEC_SA}" and verb in ["patch","update"]
EOF
pause

k delete deployment legacy-billing -n "${DEMO_NS}" --ignore-not-found
ok "Demo complete"
