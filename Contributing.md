# Contributing

Thanks for helping improve the Governed SRE Agent on Amazon EKS.

## Workflow

1. Fork the repository and create a branch from `main`.
2. Keep changes focused on one problem or feature at a time.
3. Update the relevant docs when behavior, commands, or architecture change.
4. Validate before opening a pull request.

## Local validation

This repository is centered around a live EKS validation flow, so the usual command is:

```bash
make verify ENV=dev
```

If you are changing only a local script or documentation, run the smallest relevant check first. For cluster-related changes, validate the specific environment and note the result in the PR.

## Security and secrets

- Never commit AWS credentials, IAM role data, kubeconfig files, API tokens, or private keys.
- Keep local-only configuration outside Git; use untracked local files rather than editing tracked templates.
- Redact any secrets before attaching logs, screenshots, or terminal output to issues or pull requests.

## Pull request guidance

- Explain the problem, the fix, and how it was validated.
- Include links to relevant docs or evidence when behavior changes.
- Avoid unrelated formatting churn; keep diffs easy to review.
- Prefer small, well-tested increments over large refactors.

## Repository focus

This project is intentionally opinionated about safe AI operations on Kubernetes:

- enforce controls at the gateway and cluster boundary
- prefer read-only and approved write paths
- avoid privileged access or secret leakage in examples and docs

Thank you for helping keep the project governed, transparent, and production-safe.
