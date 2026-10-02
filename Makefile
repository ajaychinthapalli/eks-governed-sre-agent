# Governed SRE agent on existing EKS clusters. One env file per cluster: envs/<env>.env
#   make configure ENV=dev        render deploy/dev/ (commit it)
#   make preflight install verify ENV=dev
ENV ?=
export ENV

.PHONY: configure preflight install verify demo clean render check aws-setup

configure: ; ./scripts/configure.sh
preflight: ; ./scripts/preflight.sh
install:   ; ./scripts/install.sh
verify:    ; ./scripts/verify.sh
demo:      ; ./scripts/demo.sh
clean:     ; ./scripts/cleanup.sh
aws-setup: ; ./scripts/aws-setup.sh

# Show exactly what gets applied for this environment's platform layer (no cluster needed).
render:    ; kubectl kustomize deploy/$(ENV)/platform

# Offline, same as CI: every env re-renders to exactly what is committed, manifests build, scripts lint.
check:     ; ./scripts/check.sh
