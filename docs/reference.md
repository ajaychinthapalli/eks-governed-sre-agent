# Reference: Governed SRE Agent on existing Amazon EKS clusters (v2, production profile)

An on-call SRE agent ([kagent](https://kagent.dev)) for your **existing EKS clusters**. Every model
call and every tool call goes through [agentgateway](https://agentgateway.dev).

- The agent reads only the namespaces you grant.
- It runs as two separate identities: one that can only read, and one that can only restart or
  scale a Deployment.
- A person approves every write, and the Kubernetes API server rejects anything beyond a restart
  or a bounded scale.

v2 adds the production profile:
- one env file per cluster;
- GitOps-only production pinned to release tags;
- the read/write identity split;
- default-deny egress, with Bedrock reached over a VPC endpoint;
- Pod Security labels;
- an RBAC-escalation guard.

AWS resources are created with idempotent AWS CLI scripts. There is no Terraform.

```
 You ── port-forward / OIDC ──▶ kagent (UI, controller, sre-triage-agent)      ns kagent
                                   │ LLM + MCP                                   ingress: own pods only
                                   ▼                                             egress: DNS, API, gateway, collector
             agentgateway-proxy (ClusterIP, HPA 2-6, PDB)                        ns agentgateway-system
   ├─ /v1/chat/completions  budget · secret guard ─▶ Bedrock VPC endpoint ─▶ Amazon Bedrock (role: InvokeModel
   │                                                  (private DNS, in-VPC)     only via that endpoint)
   ├─ /mcp/diag  7 read tools ─▶ kagent-tools     --read-only, RBAC get/list/watch        ns kagent-tools
   └─ /mcp/exec  2 tools      ─▶ kagent-executor  RBAC get+patch, restart/scale only       ns kagent-executor
                                   │                approval required (admission-enforced)
                                   ▼
     Kubernetes API ── admission: restart-only, scale 1..MAX (at most x2), gateway-only wiring,
                       prod: only Argo CD / break-glass may change the agent's RBAC
                                   ▼
     your namespaces: APP_NAMESPACES (read + remediate) · APP_NAMESPACES_READONLY (read only)
```

## What makes it production-grade

| Control | How | Proven by `make verify` |
|---|---|---|
| **Read and write are different identities** | Diagnostics: `kagent-tools --read-only` (write tools not even registered), RBAC get/list/watch. Remediation: `kagent-executor`, RBAC get+patch on workloads and `deployments/scale` only, no read of pods, logs or Secrets. | reader cannot patch; executor cannot read logs; neither can read Secrets, delete, exec, see `kube-system` or create RoleBindings |
| **9 tools, split by route** | `/mcp/diag` allows 7 read tools; `/mcp/exec` allows `k8s_rollout` and `k8s_scale` only | 7 + 2 discovered; `k8s_delete_resource` on `/mcp/exec` and `k8s_scale` on `/mcp/diag` refused |
| **Every write approved by a person** | `requireApproval` in the agent, enforced by admission: an agent that uses `k8s-remediation` tools without approval is rejected | agent without approval denied |
| **A write can only restart or scale** | `remediation-guard.yaml`, matched to the executor's requests only. Updates may change only the `restartedAt` annotation, so undo, pause, image, env and ServiceAccount changes are rejected. Scale must be 1..`MAX_REPLICAS` and at most double per step. | restart and 1-step scale allowed; image, env, pause, replicas-by-patch, scale 0 and scale > max denied; your own changes unaffected |
| **Read-only namespaces** | `APP_NAMESPACES_READONLY` gets the read binding only | executor cannot patch there |
| **Nothing reaches the platform except its callers** | Ingress NetworkPolicies: kagent from its own pods; gateway from kagent; tool servers from the gateway; collector from the platform | outsider → gateway / kagent API blocked; agent pod → tool servers blocked |
| **Default-deny egress** | Generated per VPC in `deploy/<env>/platform/egress.yaml`. Every platform namespace may reach DNS, the API server (VPC CIDRs + `kubernetes` ClusterIP, 443) and its listed peers. The proxy also reaches the Bedrock endpoint, and the Pod Identity agent (169.254.170.23:80). | internet unreachable from tools, executor and kagent; API reachable |
| **Bedrock never over the internet** (prod) | `scripts/aws-setup.sh` creates or reuses a `bedrock-runtime` interface endpoint with private DNS. The gateway's IAM policy requires `aws:SourceVpce` = that endpoint, so the credentials are useless anywhere else. | chat via gateway 200 with egress locked |
| **Only Git changes the agent's RBAC** (prod) | `sre-rbac-escalation-guard`: bindings that name the tool identities or `sre-agent-*` roles may be changed only by Argo CD or `BREAKGLASS_GROUPS`. Other RBAC in the cluster is unaffected. | guard + parameters present |
| **Pod Security** | Platform namespaces: `enforce=baseline`, `audit`/`warn=restricted`. Tool servers and collector run `restricted` (non-root, read-only root FS, no capabilities, seccomp). | labels on all 5 namespaces |
| **GitOps-only production on tags** | `make configure ENV=prod` refuses unless `DEPLOY_MODE=gitops`, `GIT_REVISION` is a tag or SHA, `DEMO_APP=false`, `EGRESS_LOCKDOWN=true` and `BEDROCK_PRIVATE_ENDPOINT=true`. Optional Argo CD sync window. | `install.sh` refuses direct mode for prod |
| **No drift between env files and manifests** | `make check` (also CI) re-renders every env and fails if `deploy/<env>/` differs | — |
| Also kept from v1 | Gateway budget (429; `LLM_TOKENS_PER_MINUTE` / `LLM_REQUESTS_PER_MINUTE` per replica, default 400k / 120), secret guard (403), gateway-only wiring and no public LB (admission), HPA 2–6 + PDBs, 30-day session retention, OTel to your backend | — |

## Repository layout

```
envs/<env>.env               one file per cluster (dev.env, prod.env): the ONLY thing you edit per environment
deploy/<env>/                generated by `make configure ENV=<env>`; committed; what Argo CD reads
  platform/                  kustomize overlay: base + settings + scope + egress (+ prod guardrails, + IRSA)
  values/                    per-env Helm values (collector identity/exporters, kagent)
  gitops/                    AppProject, root app, child apps (9, or 10 with the demo)
platform/base/               environment-neutral: gateway, routes, allowlists, agent, RBAC, ingress policies, admission
platform/components/         prod-guardrails (RBAC escalation guard), irsa
helm-values/                 shared Helm values (kagent, kagent-tools, kagent-executor, collector, agentgateway, optional/)
apps/demo-shop/              broken sample workloads; deploy/<env>/demo places them in DEMO_NAMESPACE (non-prod)
scripts/                     configure · preflight · install · aws-setup · verify · demo · cleanup · check · render.py
```

## Environments

| Setting | dev (example) | prod (example) | Notes |
|---|---|---|---|
| `ENVIRONMENT` | `nonprod` | `prod` | `prod` turns on the production rules and guardrails |
| `DEPLOY_MODE` | `direct` | `gitops` (required) | direct = Helm + kubectl from your machine |
| `GIT_REVISION` | `main` | `v2.0.0` (tag or SHA required) | promote by moving prod to a new tag |
| `APP_NAMESPACES` | `sre-sandbox` | `payments checkout` | read + restart/scale with approval |
| `APP_NAMESPACES_READONLY` | `radar` | `ledger` | read only |
| `DEMO_APP` | `true` | `false` (required) | sample broken apps for the demo and `verify` |
| `DEMO_NAMESPACE` | `sre-sandbox` | — | the repo creates this namespace, owns it and deploys the sample apps there; it must also be in `APP_NAMESPACES` |
| `EGRESS_LOCKDOWN` | `true` | `true` (required) | needs NetworkPolicy enforcement on the cluster |
| `BEDROCK_PRIVATE_ENDPOINT` | `false` | `true` (required) | VPC endpoint is created or reused by `aws-setup.sh` |
| `BREAKGLASS_GROUPS` | — | `system:masters,sre-breakglass` | Kubernetes groups that may change the agent's RBAC outside Git |
| `SYNC_WINDOW_CRON` | — | empty | e.g. `0 14 * * 1-4`: auto-sync and self-heal only in that window |
| `KAGENT_OIDC`, `KAGENT_EXTERNAL_DB` | `false` | recommended `true` | preflight warns in prod |

## Install

Prerequisites per cluster:
- EKS 1.30+.
- The `eks-pod-identity-agent` add-on.
- NetworkPolicy enforcement: the VPC CNI with `enableNetworkPolicy: "true"`, or Calico/Cilium.
- Bedrock model access in the region.
- `enableDnsHostnames` on the VPC, for the endpoint's private DNS.
- Control-plane `audit` logs (recommended).

CLIs: `kubectl`, `aws`, `jq`, `python3`, `git`, plus `helm` for direct mode.

**Non-production (direct):**

```bash
vi envs/dev.env                       # context, cluster, region, account, model, namespaces
make configure ENV=dev                # renders deploy/dev/ (reads the VPC CIDRs and API ClusterIP)
make preflight install verify ENV=dev
make demo ENV=dev
```

**Production (GitOps, tagged):**

```bash
vi envs/prod.env
make configure ENV=prod               # refuses if a production rule is not met
git add -A && git commit -m "prod-1: configure" && git push
git tag v2.0.0 && git push origin v2.0.0     # the tag in GIT_REVISION
make preflight ENV=prod               # read-only; also checks the tag exists and nothing is uncommitted
make install ENV=prod                 # Argo CD (reused if present) + project + root app, then aws-setup.sh
make verify ENV=prod                  # NetworkPolicy gaps FAIL in prod (they only warn elsewhere)
```

**Promote a change to production:**
1. Merge it to `main`.
2. Dev follows `main`; run `make verify ENV=dev`.
3. Tag the commit, set `GIT_REVISION` in `envs/prod.env` to the new tag, `make configure ENV=prod`, commit and push.

Argo CD rolls prod forward. Roll back by pointing `GIT_REVISION` at the previous tag.

**Private repository:** give Argo CD read access once (`argocd repo add … --username git --password <read-only token>`).

## What `aws-setup.sh` does (AWS CLI, idempotent, tagged)

1. **Bedrock VPC endpoint** (`BEDROCK_PRIVATE_ENDPOINT=true`).
   - Reuses an existing `com.amazonaws.<region>.bedrock-runtime` endpoint in the VPC.
   - Otherwise it creates one in the cluster's subnets (one per AZ), with private DNS and a security
     group allowing 443 from the VPC CIDRs.
   - With IRSA, it also creates an `sts` endpoint.
   - Everything it creates is tagged `sre-agent/cluster=<cluster>`.
2. **IAM role** `GATEWAY_IAM_ROLE_NAME` with `bedrock:InvokeModel` and
   `InvokeModelWithResponseStream` only, conditioned on `aws:SourceVpce` when the endpoint is used.
3. **Binding:** an EKS Pod Identity association to the gateway's ServiceAccount, or, for IRSA, the
   annotation rendered into `deploy/<env>/platform`.

`make clean ENV=<env>` removes the association, the role, and only the endpoints and security
groups carrying that tag.

## Day-2

- **Add a namespace:** add it to `APP_NAMESPACES` or `APP_NAMESPACES_READONLY`, then
  `make configure ENV=<env>`, commit, and push (prod) or `make install` (direct).
- **VPC CIDR added:** preflight fails until you re-run `make configure ENV=<env>`, which regenerates
  the egress rules.
- **Allow another tool:**
  1. Add it to the right allowlist in `platform/base/agentgateway/policies.yaml` and to the agent's
     `toolNames`.
  2. Read tools go to the diagnostics server. Write tools need the executor, `requireApproval`, an
     RBAC change and a `remediation-guard.yaml` rule.
- **Upgrade versions:** bump them in `scripts/lib.sh`, run `make configure` for every env, verify
  on dev, then tag for prod.
- **Break-glass:** members of `BREAKGLASS_GROUPS` can change the agent's RBAC directly. Map an EKS
  access entry to `sre-breakglass` for on-call admins. Everyone else changes it in Git.

## What leaves the cluster

| Data | Goes to | Notes |
|---|---|---|
| Prompts: your question plus logs, events and YAML the agent read | Amazon Bedrock in `AWS_REGION` via the VPC endpoint | Cross-region inference profiles may route within their geography. Credentials matching the secret guard are blocked first. |
| Traces, metrics, logs | `CENTRAL_OTLP_ENDPOINT` (egress limited to `CENTRAL_OTLP_CIDRS`) | kagent's OTel logging can include conversation content. Turn `otel.logging` off in `helm-values/kagent.yaml` if needed. |
| Conversations | kagent's PostgreSQL (bundled, or RDS with `KAGENT_EXTERNAL_DB=true`) | deleted after 30 idle days |

## Known limits

- **The audit log records the executor, not the approver.** User identity is not yet propagated to
  the tool servers, so the audit log shows `kagent-executor` as the actor. Correlate approvals with
  kagent's session record by time.
- **Some charts may not meet Pod Security `restricted`.** The kagent and agentgateway charts are not
  all verified against it, which is why namespaces enforce `baseline` and only warn on
  `restricted`. Run `kubectl get events -A | grep -i podsecurity` after install to see what would
  fail.
- **Gateway rate limits apply per proxy replica.**
- **No alert-driven investigations yet.** The agent is driven by people through the UI or A2A.

## Troubleshooting

| Symptom | Look at |
|---|---|
| verify: chat call not 200 after egress lockdown | Is the endpoint private DNS on? `aws ec2 describe-vpc-endpoints --filters Name=service-name,Values=com.amazonaws.<region>.bedrock-runtime`. Does the gateway resolve `bedrock-runtime.<region>.amazonaws.com` to VPC IPs? Gateway logs show the error. An `AccessDenied` mentioning `aws:SourceVpce` means traffic is not using the endpoint. |
| Pods fail DNS after egress lockdown | NodeLocal DNSCache in use: set `DNS_EXTRA_CIDRS="169.254.20.10/32"` in the env file and re-run `make configure`. |
| kagent controller cannot reach the API | Check `KUBE_API_SVC_IP` and `VPC_CIDRS` in `deploy/<env>/platform/facts`, then re-run `make configure`. |
| An RBAC change is denied with "managed by GitOps only" (prod) | Working as designed: change it in Git, or use a `BREAKGLASS_GROUPS` member. |
| `make configure ENV=prod` refuses | It lists every production rule that is not met. |
| `make check` says deploy differs | Someone edited `deploy/` by hand, or forgot to re-render: run `make configure ENV=<env>` and commit. |
| Tool counts wrong | `kubectl get remotemcpserver -n kagent k8s-diagnostics k8s-remediation -o yaml`; `kubectl get agentgatewaypolicy -n agentgateway-system`. |

## Versions

Pinned and checked on 2026-10-01: Gateway API v1.6.0, agentgateway v1.5.0, kagent 0.10.1,
kagent-tools 0.3.0, OpenTelemetry Collector chart 0.174.0, Argo CD v3.5.3 (installed only if none
exists).

Validated against a real kube-apiserver v1.33 with the projects' published CRDs. Both
environments' manifests and Argo CD apps are accepted, and all 7 admission policies type-check.
These tests pass:
- **Identity split:** the reader cannot patch; the executor cannot read pods, logs or Secrets,
  cannot delete, and cannot patch in read-only namespaces.
- **Remediation guard:** restart and 2→4 are allowed; image change, 2→5, scale 0, and a restart in
  a read-only namespace are denied.
- **RBAC escalation guard:**
  - a cluster-admin outside break-glass binding `edit` to the executor is denied, and so is editing
    `sre-agent-*` roles;
  - a break-glass group member and Argo CD are allowed;
  - unrelated bindings are unaffected.
- **Approval rule:** an agent using remediation tools without approval is denied, and a
  RemoteMCPServer pointing straight at the executor is denied.

Runtime checks (Bedrock through the endpoint, NetworkPolicy enforcement, tool discovery) need your
clusters: run `make verify ENV=<env>`.
