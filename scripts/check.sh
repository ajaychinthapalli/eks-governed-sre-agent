#!/usr/bin/env bash
# shellcheck disable=SC2015  # echo always returns 0, so "A && echo || fail" is safe
# Offline consistency checks for every environment (CI runs this on each pull request):
#   1. envs/<env>.env re-renders to exactly the committed deploy/<env>/ (no hand edits, no drift)
#   2. every platform overlay and the demo app build with kustomize
#   3. every generated Argo CD manifest parses
#   4. shell scripts lint clean
# Uses the facts saved by the last online configure (deploy/<env>/platform/facts); needs no cluster.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
KUSTOMIZE=(kustomize build); command -v kustomize >/dev/null 2>&1 || KUSTOMIZE=(kubectl kustomize)
fail=0
for f in envs/*.env; do
  env="$(basename "$f" .env)"
  printf '\n== %s\n' "${env}"
  facts="deploy/${env}/platform/facts"
  if [[ ! -d "deploy/${env}" ]]; then echo "  ! not rendered yet: run make configure ENV=${env} with cluster access, then commit deploy/${env}"; continue; fi
  [[ -f "${facts}" ]] || { echo "  ✗ ${facts} missing: run make configure ENV=${env} once with cluster access"; fail=1; continue; }
  before=$(mktemp -d); cp -r "deploy/${env}" "${before}/"
  VPC_CIDRS="$(sed -n 's/^# discovered VPC_CIDRS=//p' "${facts}")" \
  KUBE_API_SVC_IP="$(sed -n 's/^# discovered KUBE_API_SVC_IP=//p' "${facts}")" \
  KUBECONFIG=/dev/null ENV="${env}" ./scripts/configure.sh >/dev/null || { echo "  ✗ render failed"; fail=1; continue; }
  if diff -r "${before}/${env}" "deploy/${env}" >/dev/null; then echo "  ✓ deploy/${env} matches envs/${env}.env"
  else echo "  ✗ deploy/${env} differs from what envs/${env}.env renders: run make configure ENV=${env} and commit"; diff -r "${before}/${env}" "deploy/${env}" | head -20; fail=1; fi
  rm -rf "${before}"
  "${KUSTOMIZE[@]}" "deploy/${env}/platform" >/dev/null && echo "  ✓ platform overlay builds" || { echo "  ✗ platform overlay does not build"; fail=1; }
  python3 - "deploy/${env}/gitops" <<'PY' && echo "  ✓ gitops manifests parse" || fail=1
import glob, sys, yaml
for p in glob.glob(sys.argv[1] + "/**/*.yaml", recursive=True):
    list(yaml.safe_load_all(open(p)))
PY
done
printf '\n== shared\n'
"${KUSTOMIZE[@]}" apps/demo-shop >/dev/null && echo "  ✓ demo app builds" || fail=1
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -P scripts -e SC1091 scripts/*.sh && echo "  ✓ scripts lint clean" || fail=1
else
  echo "  ! shellcheck not installed: skipped"
fi
exit "${fail}"
