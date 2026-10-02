# Screenshots

UI screenshots can only be taken on the machine running `make demo ENV=dev`. Save them here with
these names, then link the best two or three from the main README's "See it work" section.

| File | What to capture | Where |
|---|---|---|
| `01-kagent-agents.png` | The agent list showing `sre-triage-agent` | kagent UI, http://localhost:8082 |
| `02-triage-answer.png` | The answer to "What is broken in the sre-sandbox namespace? Find the root cause for each failing workload." | kagent UI, chat |
| `03-approval-prompt.png` | The approval prompt after "Restart the checkout deployment." | kagent UI, chat |
| `04-scale-rejected.png` | "Scale frontend to 50 replicas." approved, then rejected by the API server | kagent UI, chat |
| `05-secret-guard-403.png` | "Why is legacy-billing failing? Check its logs." and the blocked model call | kagent UI, chat |
| `06-agentgateway-ui.png` | Gateway routes and policies | agentgateway UI, http://localhost:15000/ui/ |
| `07-verify-60-of-60.png` | The end of `make verify ENV=dev` in your terminal | terminal |

Before committing, check that no screenshot shows your AWS account ID, a cluster ARN or a real
token.
