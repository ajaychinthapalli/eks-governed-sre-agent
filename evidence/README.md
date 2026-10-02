# Evidence: real terminal output from the dev cluster

Unedited output from deploying to `ac-ws-dev-use2` (EKS 1.36, us-east-2) on 2026-10-01/02. The only
changes: the AWS account ID is masked as `111122223333`, and the Pod Identity association ID is
replaced with `a-0example000000000`.

| File | Step | What it shows |
|---|---|---|
| `01-install-fail-helm4-duplicate-port.log` | First `make install` | Gateway API, agentgateway and kagent CRDs install; kagent-tools fails on Helm 4 server-side apply (duplicate port 8084); OTel component renames |
| `02-install-waiting-on-kagent.log` | `make install` after the port fix | Both tool servers install; waits on kagent |
| `03-kagent-postgres-pvc-pending.log` | Diagnosing the wait | Controller crash loop (Postgres refused), PVC with no StorageClass |
| `04-install-success.log` | `make install` after storage and node fixes | Full install, IAM role, Pod Identity association, sre-triage-agent Ready |
| `05-verify-58-of-59-bedrock-500.log` | `make verify` | Everything passes except the Bedrock call (500) |
| `06-bedrock-500-one-pod-without-credentials.log` | Diagnosing the 500 | Pod A: 200 from Bedrock. Pod B: `credential provider was not enabled`, IMDS blocked |
| `07-verify-60-of-60-passed.log` | `make verify` after the fix | **60 passed, 0 failed, 0 warnings** |
| `08-llm-budget-429-rate-limit.log` | First triage in the UI | 429 from the gateway's own budget (`"reason":"RateLimit"`) |
| `09-demo-walkthrough.log` | `make demo` | Demo scenes, and the 403 `Guardrail` log line when the agent tried to send a leaked key to the model |

Gateway log lines are JSON, one per request. The useful fields are `route`, `http.status`,
`reason`, `error`, `gen_ai.tool.name` and `gen_ai.usage.*`.
