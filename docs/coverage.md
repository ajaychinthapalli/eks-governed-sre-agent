# Coverage: the EKS half of the architecture diagram

Status on the dev cluster `ac-ws-dev-use2` after `make verify ENV=dev` (60/60) and `make demo ENV=dev`.
The same data, with filters and live counts, is in [coverage.xlsx](coverage.xlsx).

| Area | Met | Exceeds | Partial | Not met |
|---|---|---|---|---|
| Inside the EKS box | 11 | — | — | — |
| Beyond the diagram | — | 6 | — | — |
| Fleet layer and frame | — | — | 4 | 2 |

## Inside the EKS box: built and proven

| Diagram component | On the cluster | Proof |
|---|---|---|
| kagent UI, controller, triage agent | `kagent` namespace, `sre-triage-agent` Ready | verify |
| Port-forward for development | `make demo` port-forwards the UI on 8082 | demo |
| agentgateway-proxy: ClusterIP, 2+ replicas | ClusterIP, HPA min 2, PDB | verify |
| LLM route: token and request budgets | `llm-budget` policy (429 when over) | 429 traced to `"reason":"RateLimit"` |
| LLM route: secret guard (AKIA…, PEM, gh…) | Regex guardrail | verify 403; demo log `"reason":"Guardrail"` |
| MCP route: tool allowlist, 9 tools | 7 diagnostics + 2 remediation; anything else refused | verify |
| Bedrock: SigV4, Pod Identity / IAM role, gateway only | Pod Identity role with InvokeModel only; no API keys | verify |
| kagent-tools: MCP server :8084 | Read-only, 2 replicas | verify |
| NetworkPolicy: only from agentgateway-proxy | Bypass attempts blocked | verify |
| Kubernetes API: ServiceAccount + namespace RBAC | Tools see only `sre-sandbox` and `radar` | verify |
| Application namespace ("arc systems") | `sre-sandbox` (act), `radar` (read-only) | verify |

## Beyond the diagram

| Control | What it adds |
|---|---|
| Split tool identities | Read-only server (7 tools) and executor (2 tools), each with its own ServiceAccount and RBAC |
| Remediation limits in the API server | Restart only; scale 1..`MAX_REPLICAS`, at most doubling; image/env/pause changes rejected even after approval |
| Human approval on every write | `requireApproval`, enforced by an admission policy |
| Egress lockdown | Platform pods cannot reach the internet |
| Pod Security | `enforce=baseline`, `warn`/`audit=restricted` |
| Gateway-only wiring | Admission rejects agents, model configs or MCP servers that bypass the gateway, and public LoadBalancers |

## Not met yet

| Diagram says | Dev today | To close it |
|---|---|---|
| Users: OIDC + RBAC | `KAGENT_OIDC=false`; UI only via port-forward by cluster admins | `KAGENT_OIDC=true` with your IdP (supported, not yet tested here) |
| TLS in transit | Gateway → Bedrock is TLS; in-cluster hops are HTTP behind NetworkPolicies | Gateway TLS listeners or a service mesh |
| GitOps per-cloud overlays | Overlays exist; dev runs `DEPLOY_MODE=direct` | `DEPLOY_MODE=gitops` (required for prod) |
| Policy & audit (OPA) | ValidatingAdmissionPolicy (built into Kubernetes), audit logs on | Same purpose, different engine |
| Central observability | Collector runs; `CENTRAL_OTLP_ENDPOINT` empty | Point it at a backend |
| Node autoscaling, multi-zone | Gateway HPA; fixed 2 × t3.large nodegroup | Karpenter or Cluster Autoscaler |
