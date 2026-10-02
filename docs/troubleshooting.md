# What broke on a real EKS cluster, and how it was fixed

Everything below happened while deploying to the dev cluster `ac-ws-dev-use2` (EKS 1.36,
us-east-2, 3 × t3.small self-managed nodes at the start). Each fix is now built into the repo:
either a script change or a `make preflight` check that catches the problem before install.

| # | Symptom | Root cause | Fix | Now in the repo |
|---|---|---|---|---|
| 1 | Scripts failed on macOS (`mapfile: command not found`, bad substitution) | macOS ships bash 3.2 | Removed bash-4-only syntax (`mapfile`, `${x,,}`, empty-array loops) | All scripts run on bash 3.2+ |
| 2 | `helm install kagent-tools` failed: `duplicate entries for key [containerPort=8084]` | Helm 4 uses server-side apply, which rejects the chart's duplicate port (tools and metrics both on 8084) | `tools.metrics.port: 8085` in both tool servers' values; `helm uninstall` the failed release, install again | `helm-values/kagent-tools.yaml`, `kagent-executor.yaml` |
| 3 | OTel collector install printed `[DEPRECATION] Exporter 'otlphttp' has been renamed…` | Collector chart 0.174.0 renamed components | `otlphttp` → `otlp_http`, `k8sattributes` → `k8s_attributes` | `helm-values/otel-collector.yaml`, `render.py` |
| 4 | `kagent-controller` CrashLoopBackOff: `connect: connection refused` to Postgres; Postgres Pending: `unbound immediate PersistentVolumeClaims` | Cluster had no default StorageClass and no EBS CSI driver, so the bundled Postgres PVC never bound | EBS CSI add-on with a Pod Identity role, `gp3` set as default; deleted the stuck Postgres pod so it rescheduled | `make preflight` checks for a default StorageClass and warns if the EBS CSI driver is missing |
| 5 | Two `kagent-controller` pods Pending: `0/3 nodes are available: 3 Too many pods` | t3.small allows only 11 pods per node; system add-ons already used most slots | Opened the node ↔ cluster security groups, then added managed nodegroup `ng-t3-large` (2 × t3.large, AL2023) | `make preflight` checks for ≥19 free pod slots and ≥2.3 GiB of unrequested memory |
| 6 | `verify`: egress test reported `200200` (internet reachable) from kagent-tools and kagent-executor | VPC CNI "standard" network-policy mode leaves a new pod open for a few seconds; the test pod ran inside that window. Fast pods also made `kubectl run` print their output twice. | Test pod waits 8 s before calling out; only the first 3 characters of the status code are read | `scripts/verify.sh` |
| 7 | `verify`: diagnostics route showed 0 tools right after install | kagent had not finished discovering the tool server's tools yet | Passed on the next run without changes | — |
| 8 | `verify`: chat via gateway → Bedrock **500**, intermittently. Gateway log: `backend authentication failed: the credential provider was not enabled`, then IMDS timeouts | One of the two proxy pods was created before the new Pod Identity association reached EKS, so it never got `AWS_CONTAINER_CREDENTIALS_FULL_URI`. It fell back to IMDS, which egress lockdown correctly blocks. Requests were load-balanced, so roughly half failed. | `kubectl rollout restart deploy/agentgateway-proxy` | `aws-setup.sh` waits, restarts, and checks **every** proxy pod for the credential env var, restarting until all have it. `verify` checks each pod, not just one request. |
| 9 | kagent UI: `LLM error: STREAM_ERROR … 429 Too Many Requests` | The gateway's own budget (logged `"reason":"RateLimit"`): 60k tokens/min per replica. One triage resends the whole conversation each step: 10–20 calls of 10–30k tokens. | Budget raised to 400k tokens and 120 requests per minute per replica | `LLM_TOKENS_PER_MINUTE` / `LLM_REQUESTS_PER_MINUTE` in `envs/<env>.env`, rendered into the `llm-budget` policy |
| 10 | `Defaulted container "agentgateway" out of: …, opentelemetry-auto-instrumentation-java (init), …` | The cluster's CloudWatch Observability add-on injects Java/Node/Python/.NET auto-instrumentation into every pod | Harmless; it only slows gateway pod startup | Known; can be turned off for the platform namespaces |

## Evidence

| Log | Shows |
|---|---|
| [`01-install-fail-helm4-duplicate-port.log`](../evidence/01-install-fail-helm4-duplicate-port.log) | #2 and the OTel deprecation warnings (#3) |
| [`02-install-waiting-on-kagent.log`](../evidence/02-install-waiting-on-kagent.log) | Install rerun after the port fix, stuck waiting on kagent (#4) |
| [`03-kagent-postgres-pvc-pending.log`](../evidence/03-kagent-postgres-pvc-pending.log) | Controller crash loop, PVC with no StorageClass (#4) |
| [`04-install-success.log`](../evidence/04-install-success.log) | Full successful install |
| [`05-verify-58-of-59-bedrock-500.log`](../evidence/05-verify-58-of-59-bedrock-500.log) | Verify with the intermittent 500 (#8) |
| [`06-bedrock-500-one-pod-without-credentials.log`](../evidence/06-bedrock-500-one-pod-without-credentials.log) | One pod 200, the other `credential provider was not enabled` (#8) |
| [`07-verify-60-of-60-passed.log`](../evidence/07-verify-60-of-60-passed.log) | All 60 checks passing |
| [`08-llm-budget-429-rate-limit.log`](../evidence/08-llm-budget-429-rate-limit.log) | The 429 traced to the gateway's budget (#9) |
| [`09-demo-walkthrough.log`](../evidence/09-demo-walkthrough.log) | `make demo`, including the credential leak blocked with 403 |

Issues 1, 5, 6 and 7 were diagnosed from terminal output that was not saved; the commands used are
in [`commands.md`](commands.md) (steps 2f and 2g).

## Lessons

- **Check capacity and storage before installing an agent platform.** Small nodes and a missing
  default StorageClass are the most likely first failures on an existing cluster. Both are now
  preflight checks.
- **Pod Identity credentials are injected when a pod is created.** After creating a new
  association, restart the workload and check every pod, not just one request.
- **Egress lockdown turns a silent fallback into a visible failure.** Without it, the pod with no
  credentials could have fallen back to the node's instance role over IMDS.
- **Size the LLM budget for agent loops, not single chats.** Each step resends the whole
  conversation, so a single triage uses far more tokens than one question.
- **Make the test print the evidence.** Every check that can fail now prints the gateway's reply,
  so a failure explains itself.
