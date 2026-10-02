#!/usr/bin/env bash
# Proves every control on one environment's cluster, without the UI:  ENV=prod scripts/verify.sh
# Writes nothing to the cluster except short-lived test pods and a temporary namespace;
# every mutating check is a server-side dry run.
source "$(dirname "$0")/lib.sh"
need kubectl

PASS=0; FAIL=0; WARN=0
OUTSIDER_NS="sre-verify-outsider"
check() {  # check <description> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; PASS=$((PASS+1))
  else printf '\033[1;31m  ✗ %s (expected %s, got %s)\033[0m\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}
netcheck() {  # netcheck <description> <http code>  - 000 means the connection was blocked
  set -- "$1" "${2:0:3}"   # kubectl run --rm -i can print a fast pod's output twice ("200200")
  if [[ "$2" == "000" ]]; then ok "$1"; PASS=$((PASS+1))
  elif [[ -z "$2" ]]; then printf '\033[1;31m  ✗ %s (test pod did not run)\033[0m\n' "$1"; FAIL=$((FAIL+1))
  elif ${IS_PROD}; then printf '\033[1;31m  ✗ %s (got HTTP %s: NetworkPolicy not enforced)\033[0m\n' "$1" "$2"; FAIL=$((FAIL+1))
  else warn "$1: got HTTP $2 - NetworkPolicy not enforced on this cluster (see preflight)"; WARN=$((WARN+1)); fi
}
# Run a shell snippet in a throwaway pod. Namespace decides the network position.
incluster() {  # incluster <namespace> <script>
  k run "verify-$RANDOM" -n "$1" --rm -i --quiet --restart=Never --pod-running-timeout=2m \
    --image=curlimages/curl:8.10.1 --command -- sh -c "$2" 2>/dev/null | tail -n 1 || true
}
# Server-side dry run of a manifest; prints "denied" if admission rejects it with the expected message.
denied() {  # denied <expected message fragment>  (manifest on stdin)
  local out; out=$(k apply --dry-run=server -f - 2>&1) && { echo "allowed"; return; }
  grep -q "$1" <<<"$out" && echo "denied" || echo "error: ${out:0:160}"
}
# Server-side dry run of a kubectl command AS the executor. allowed | denied | error.
as_exec() {  # as_exec <expected denial fragment or -> <kubectl args...>
  local frag="$1"; shift
  local out; out=$(k "$@" --dry-run=server --as="${EXEC_SA}" 2>&1) && { echo "allowed"; return; }
  [[ "$frag" != "-" ]] && grep -q "$frag" <<<"$out" && { echo "denied"; return; }
  echo "error: ${out:0:200}"
}
# One MCP tools/call through the gateway from an agent-side pod; prints the raw reply.
mcp_call() {  # mcp_call <path> <tool> <json arguments>
  incluster "${KAGENT_NS}" "
H='-H content-type:application/json -H accept:application/json,text/event-stream'
SID=\$(curl -s -D - -o /dev/null ${GW_URL}$1 \$H -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"verify\",\"version\":\"1\"}}}' | tr -d '\r' | awk -F': ' 'tolower(\$1)==\"mcp-session-id\"{print \$2}')
curl -s -o /dev/null ${GW_URL}$1 \$H -H \"mcp-session-id: \$SID\" -d '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}'
curl -s ${GW_URL}$1 \$H -H \"mcp-session-id: \$SID\" -d '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3}}' | tr -d '\n'
"
}
tools_of() { k get remotemcpserver "$1" -n "${KAGENT_NS}" -o jsonpath='{range .status.discoveredTools[*]}{.name}{"\n"}{end}' 2>/dev/null | sort; }
cleanup() { k delete namespace "${OUTSIDER_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

read -r -a NSS <<<"${APP_NAMESPACES}"
APP_NS="${NSS[0]:-}"
TARGET=""
if [[ "${DEMO_APP}" == true ]]; then TARGET="frontend"; APP_NS="${DEMO_NS}"
elif [[ -n "${APP_NS}" ]]; then TARGET=$(k get deploy -n "${APP_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); fi

log "Identity: the gateway reaches Bedrock with its own AWS role (no API key anywhere)"
if [[ "${AWS_AUTH_MODE}" == "pod-identity" ]]; then CRED_VAR=AWS_CONTAINER_CREDENTIALS_FULL_URI; else CRED_VAR=AWS_WEB_IDENTITY_TOKEN_FILE; fi
NOCRED=$(k get pods -n "${AGW_NS}" -l gateway.networking.k8s.io/gateway-name="${GATEWAY_NAME}" --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[0].env[*].name}{"\n"}{end}' | grep -v " .*${CRED_VAR}" | awk 'NF{print $1}' || true)
check "every proxy pod has AWS credentials injected (${CRED_VAR})" "$([[ -z "${NOCRED}" ]] && echo yes || echo "no: ${NOCRED//$'\n'/ }")" "yes"
[[ -z "${NOCRED}" ]] || echo "      fix: ENV=${ENV_NAME} scripts/aws-setup.sh   (restarts the proxy until every pod has credentials)"
OUT=$(incluster "${KAGENT_NS}" "curl -s -m 60 -w '\nHTTP_CODE=%{http_code}' ${GW_URL}/v1/chat/completions -H 'content-type: application/json' \
  -d '{\"model\":\"any\",\"max_tokens\":10,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK\"}]}'")
CODE=$(sed -n 's/^HTTP_CODE=\([0-9][0-9][0-9]\).*/\1/p' <<<"${OUT}" | head -1)
check "chat completion via gateway -> Bedrock returns 200" "${CODE}" "200"
[[ "${CODE}" == 200 ]] || echo "      gateway reply: $(grep -v '^HTTP_CODE=' <<<"${OUT}" | head -c 400)"

log "LLM route: secret guard and budget"
CODE=$(incluster "${KAGENT_NS}" "curl -s -o /dev/null -w '%{http_code}' ${GW_URL}/v1/chat/completions -H 'content-type: application/json' \
  -d '{\"model\":\"any\",\"max_tokens\":10,\"messages\":[{\"role\":\"user\",\"content\":\"why does this fail: aws_access_key_id=AKIAIOSFODNN7EXAMPLE\"}]}'")
check "prompt containing an AWS access key returns 403" "${CODE}" "403"
H=$(incluster "${KAGENT_NS}" "curl -s -D - -o /dev/null ${GW_URL}/v1/chat/completions -H 'content-type: application/json' \
  -d '{\"model\":\"any\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"OK\"}]}' | grep -ci '^x-ratelimit-limit' ")
check "x-ratelimit-limit header returned" "$([[ ${H:-0} -ge 1 ]] && echo yes || echo no)" "yes"

log "MCP routes: 7 diagnostics tools + 2 remediation tools"
DIAG=$(tools_of k8s-diagnostics); EXEC=$(tools_of k8s-remediation)
echo "      diagnostics: $(tr '\n' ' ' <<<"${DIAG}")"
echo "      remediation: $(tr '\n' ' ' <<<"${EXEC}")"
check "diagnostics route exposes exactly 7 tools" "$(grep -c . <<<"${DIAG}" || true)" "7"
check "remediation route exposes exactly k8s_rollout + k8s_scale" "$(tr '\n' ' ' <<<"${EXEC}")" "k8s_rollout k8s_scale "
check "no write tool on the diagnostics route" "$(grep -Eq 'rollout|scale|patch|delete|apply' <<<"${DIAG}" && echo found || echo none)" "none"
OUT=$(mcp_call /mcp/exec k8s_delete_resource "{\"resource_type\":\"deployment\",\"resource_name\":\"${TARGET:-none}\",\"namespace\":\"${APP_NS:-none}\"}")
REFUSED='unauthori|not allowed|not found|unknown tool|denied|forbidden|"isError": *true'
R=$(grep -qiE "${REFUSED}" <<<"${OUT}" && echo refused || echo "not refused")
check "direct tools/call k8s_delete_resource on /mcp/exec is refused" "${R}" "refused"
[[ "${R}" == refused ]] || echo "      gateway reply: ${OUT:0:300}"
OUT=$(mcp_call /mcp/diag k8s_scale "{\"name\":\"${TARGET:-none}\",\"namespace\":\"${APP_NS:-none}\",\"replicas\":3}")
R=$(grep -qiE "${REFUSED}" <<<"${OUT}" && echo refused || echo "not refused")
check "direct tools/call k8s_scale on /mcp/diag is refused" "${R}" "refused"
[[ "${R}" == refused ]] || echo "      gateway reply: ${OUT:0:300}"
[[ -n "${TARGET}" ]] && check "${APP_NS}/${TARGET} still exists" "$(k get deploy "${TARGET}" -n "${APP_NS}" >/dev/null 2>&1 && echo present || echo deleted)" "present"

log "Identity split: what each tool identity can do"
if [[ -n "${APP_NS}" ]]; then
  check "reader: can list pods in ${APP_NS}"           "$(k auth can-i list pods -n "${APP_NS}" --as="${TOOLS_SA}")" "yes"
  check "reader: cannot patch deployments"             "$(k auth can-i patch deployments -n "${APP_NS}" --as="${TOOLS_SA}")" "no"
  check "executor: can patch deployments in ${APP_NS}" "$(k auth can-i patch deployments -n "${APP_NS}" --as="${EXEC_SA}")" "yes"
  check "executor: cannot read pod logs"               "$(k auth can-i get pods/log -n "${APP_NS}" --as="${EXEC_SA}")" "no"
  for sa in "${TOOLS_SA}" "${EXEC_SA}"; do
    who=${sa##*:}
    check "${who}: cannot read Secrets"       "$(k auth can-i get secrets -n "${APP_NS}" --as="${sa}")" "no"
    check "${who}: cannot delete deployments" "$(k auth can-i delete deployments -n "${APP_NS}" --as="${sa}")" "no"
    check "${who}: cannot exec into pods"     "$(k auth can-i create pods/exec -n "${APP_NS}" --as="${sa}")" "no"
    check "${who}: cannot create RoleBindings" "$(k auth can-i create rolebindings -n "${APP_NS}" --as="${sa}")" "no"
    check "${who}: cannot see kube-system"    "$(k auth can-i list pods -n kube-system --as="${sa}")" "no"
  done
fi
for ns in ${APP_NAMESPACES_READONLY}; do   # plain word list: works with macOS bash 3.2
  check "read-only namespace ${ns}: reader can list pods"  "$(k auth can-i list pods -n "${ns}" --as="${TOOLS_SA}")" "yes"
  check "read-only namespace ${ns}: executor cannot patch" "$(k auth can-i patch deployments -n "${ns}" --as="${EXEC_SA}")" "no"
done

if [[ -n "${TARGET}" ]]; then
  log "Remediation guard: what the executor's patch/scale may change (dry run as ${EXEC_SA})"
  CUR=$(k get deploy "${TARGET}" -n "${APP_NS}" -o jsonpath='{.spec.replicas}')
  CTR=$(k get deploy "${TARGET}" -n "${APP_NS}" -o jsonpath='{.spec.template.spec.containers[0].name}')
  RESTART="{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kubectl.kubernetes.io/restartedAt\":\"$(date -u +%FT%TZ)\"}}}}}"
  check "rollout restart is allowed"     "$(as_exec - patch "deploy/${TARGET}" -n "${APP_NS}" -p "${RESTART}")" "allowed"
  check "image change is denied"         "$(as_exec 'pod spec' set image "deploy/${TARGET}" "${CTR}=public.ecr.aws/docker/library/busybox:evil" -n "${APP_NS}")" "denied"
  check "env var injection is denied"    "$(as_exec 'pod spec' set env "deploy/${TARGET}" -c "${CTR}" INJECTED=1 -n "${APP_NS}")" "denied"
  check "rollout pause/resume is denied" "$(as_exec 'spec field' patch "deploy/${TARGET}" -n "${APP_NS}" --type merge -p '{"spec":{"paused":true}}')" "denied"
  check "replicas via patch is denied"   "$(as_exec 'spec field' patch "deploy/${TARGET}" -n "${APP_NS}" --type merge -p '{"spec":{"replicas":1}}')" "denied"
  check "scale to 0 is denied"           "$(as_exec 'to zero' scale "deploy/${TARGET}" --replicas=0 -n "${APP_NS}")" "denied"
  check "scale above MAX_REPLICAS (${MAX_REPLICAS}) is denied" "$(as_exec 'at most' scale "deploy/${TARGET}" --replicas=$((MAX_REPLICAS + 1)) -n "${APP_NS}")" "denied"
  if (( CUR >= 1 && CUR + 1 <= MAX_REPLICAS && CUR + 1 <= CUR * 2 )); then
    check "scale ${CUR} -> $((CUR + 1)) is allowed" "$(as_exec - scale "deploy/${TARGET}" --replicas=$((CUR + 1)) -n "${APP_NS}")" "allowed"
  fi
  check "people are not affected (image change as you: allowed)" \
    "$(k set image "deploy/${TARGET}" "${CTR}=public.ecr.aws/docker/library/busybox:1.36" -n "${APP_NS}" --dry-run=server >/dev/null 2>&1 && echo allowed || echo denied)" "allowed"
else
  warn "no Deployment in a remediable namespace: remediation guard checks skipped"; WARN=$((WARN+1))
fi

log "NetworkPolicies: only the intended callers can connect"
k create namespace "${OUTSIDER_NS}" >/dev/null 2>&1 || true
netcheck "a pod in another namespace cannot reach the gateway" \
  "$(incluster "${OUTSIDER_NS}" "curl -s -m 5 -o /dev/null -w '%{http_code}' ${GW_URL}/v1/chat/completions || true")"
netcheck "a pod in another namespace cannot reach kagent's A2A/API" \
  "$(incluster "${OUTSIDER_NS}" "curl -s -m 5 -o /dev/null -w '%{http_code}' http://kagent-controller.${KAGENT_NS}.svc.cluster.local:8083/api/agents || true")"
netcheck "an agent-side pod cannot bypass the gateway to kagent-tools" \
  "$(incluster "${KAGENT_NS}" "curl -s -m 5 -o /dev/null -w '%{http_code}' http://kagent-tools.${TOOLS_NS}.svc.cluster.local:8084/mcp || true")"
netcheck "an agent-side pod cannot bypass the gateway to kagent-executor" \
  "$(incluster "${KAGENT_NS}" "curl -s -m 5 -o /dev/null -w '%{http_code}' http://kagent-executor.${EXEC_NS}.svc.cluster.local:8084/mcp || true")"

if [[ "${EGRESS_LOCKDOWN}" == true ]]; then
  log "Egress lockdown: platform pods reach only what they need"
  # (each test pod waits 8s: in VPC CNI's default "standard" mode a new pod is open until its policies attach)
  for ns in "${TOOLS_NS}" "${EXEC_NS}" "${KAGENT_NS}"; do
    netcheck "${ns}: the internet is unreachable" \
      "$(incluster "${ns}" "sleep 8; curl -s -m 5 -o /dev/null -w '%{http_code}' https://example.com || true")"
  done
  CODE=$(incluster "${TOOLS_NS}" "sleep 8; curl -sk -m 5 -o /dev/null -w '%{http_code}' https://kubernetes.default.svc/version || true")
  CODE="${CODE:0:3}"
  check "kagent-tools: the Kubernetes API is reachable" "$([[ -n "${CODE}" && "${CODE}" != 000 ]] && echo reachable || echo "blocked (${CODE:-no pod})")" "reachable"
fi

log "Pod Security labels"
for ns in "${PLATFORM_NAMESPACES[@]}"; do
  check "${ns}: enforce=baseline, warn=restricted" \
    "$(k get ns "${ns}" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}/{.metadata.labels.pod-security\.kubernetes\.io/warn}' 2>/dev/null)" "baseline/restricted"
done

log "Admission policies (server-side dry run)"
check "ModelConfig straight to a provider is denied" "$(denied 'must use provider OpenAI' <<'YAML'
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata: { name: verify-direct, namespace: kagent }
spec: { provider: Anthropic, model: claude-x, apiKeySecret: agentgateway-placeholder-key, apiKeySecretKey: key }
YAML
)" "denied"
check "Agent not using governed-llm is denied" "$(denied 'governed-llm' <<'YAML'
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata: { name: verify-rogue, namespace: kagent }
spec: { type: Declarative, declarative: { modelConfig: default-model-config, systemMessage: hi } }
YAML
)" "denied"
check "Agent using remediation tools without approval is denied" "$(denied 'requireApproval' <<'YAML'
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata: { name: verify-no-approval, namespace: kagent }
spec:
  type: Declarative
  declarative:
    modelConfig: governed-llm
    systemMessage: hi
    tools:
      - type: McpServer
        mcpServer: { apiGroup: kagent.dev, kind: RemoteMCPServer, name: k8s-remediation, toolNames: [k8s_rollout] }
YAML
)" "denied"
check "RemoteMCPServer bypassing the gateway is denied" "$(denied 'must go through agentgateway' <<YAML
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata: { name: verify-bypass, namespace: kagent }
spec: { description: bypass test, protocol: STREAMABLE_HTTP, url: "http://kagent-executor.${EXEC_NS}.svc.cluster.local:8084/mcp" }
YAML
)" "denied"
check "public LoadBalancer in ${AGW_NS} is denied" "$(denied 'INTERNAL load balancer' <<YAML
apiVersion: v1
kind: Service
metadata: { name: verify-public, namespace: ${AGW_NS} }
spec: { type: LoadBalancer, selector: { app: none }, ports: [{ port: 80 }] }
YAML
)" "denied"
if ${IS_PROD}; then
  check "prod: RBAC escalation guard installed" \
    "$(k get validatingadmissionpolicybinding sre-rbac-escalation-guard -o jsonpath='{.spec.paramRef.name}' 2>/dev/null)" "sre-cluster-settings"
  check "prod: only Argo CD (or break-glass) may change the agent's RBAC" \
    "$(k get cm sre-cluster-settings -n "${KAGENT_NS}" -o jsonpath='{.data.ARGOCD_CONTROLLER}' 2>/dev/null)" "system:serviceaccount:${ARGOCD_NAMESPACE}:argocd-application-controller"
fi

log "Scaling, retention & observability"
check "proxy HPA present (min 2)" "$(k get hpa -n "${AGW_NS}" -o jsonpath='{.items[0].spec.minReplicas}' 2>/dev/null)" "2"
check "proxy PDB present" "$(k get pdb -n "${AGW_NS}" -o name 2>/dev/null | grep -c . || true)" "1"
check "tool server PDBs present" "$(k get pdb kagent-tools -n "${TOOLS_NS}" >/dev/null 2>&1 && k get pdb kagent-executor -n "${EXEC_NS}" >/dev/null 2>&1 && echo yes || echo no)" "yes"
check "proxy Service is ClusterIP" "$(k get svc "${GATEWAY_NAME}" -n "${AGW_NS}" -o jsonpath='{.spec.type}' 2>/dev/null)" "ClusterIP"
check "kagent session retention 30 days" "$(k get cm kagent-controller -n "${KAGENT_NS}" -o jsonpath='{.data.SESSION_RETENTION_DAYS}' 2>/dev/null)" "30"
check "OTel collector available" "$(k get deploy opentelemetry-collector -n "${OBS_NS}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q '[1-9]' && echo yes || echo no)" "yes"
check "sre-triage-agent Ready" "$(k get agent sre-triage-agent -n "${KAGENT_NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" "True"

log "Result: ${PASS} passed, ${FAIL} failed, ${WARN} warnings"
(( FAIL == 0 ))
