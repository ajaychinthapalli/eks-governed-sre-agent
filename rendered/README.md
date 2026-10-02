# Rendered manifests (dev)

The exact Kubernetes objects applied to the dev cluster, generated from the source with:

```bash
make configure ENV=dev
kubectl kustomize deploy/dev/platform > rendered/dev/platform.yaml
kubectl kustomize deploy/dev/demo     > rendered/dev/demo-apps.yaml
```

Read these to see the whole platform in one place. Don't edit them: change `envs/dev.env` or
`platform/`, then render again. The Helm charts (kagent, kagent-tools ×2, agentgateway,
OTel collector) are installed separately with the values in `helm-values/` and `deploy/dev/values/`.

| Kind | Count | Purpose |
|---|---|---|
| Gateway, HTTPRoute ×3, ReferenceGrant | 5 | agentgateway listener and the `/v1/chat/completions`, `/mcp/diag`, `/mcp/exec` routes |
| AgentgatewayBackend ×3, AgentgatewayParameters | 4 | Bedrock provider, the two MCP tool servers, proxy settings |
| AgentgatewayPolicy ×5 | 5 | LLM budget, secret guard, the two tool allowlists, tracing |
| ModelConfig, RemoteMCPServer ×2, Agent | 4 | `governed-llm`, `k8s-diagnostics`, `k8s-remediation`, `sre-triage-agent` |
| ClusterRole ×3, ClusterRoleBinding, RoleBinding ×3 | 7 | Read and remediate roles, bound per namespace |
| ValidatingAdmissionPolicy ×6 + bindings | 12 | Remediation guard (restart-only, scale bounds), approval rule, gateway-only wiring (models, MCP), no public LB |
| NetworkPolicy ×10 | 10 | Ingress allowlists and default-deny egress |
| PodDisruptionBudget ×2, ConfigMap, Namespace, Secret | 5 | Tool server PDBs, cluster settings, `sre-sandbox`, a placeholder key (`not-a-real-key`; Bedrock uses Pod Identity) |
