#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ---

for var in OC_LOGIN PREP_DB2; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${OC_LOGIN}"

uidGidRange='1001000000/10000'

# Detect current state by checking whether the configmap already exists
if oc get configmap db2u-product-cm -n ${PROJECT_CPD_INST_OPERATORS} &>/dev/null; then
    echo "[INFO] restricted-v2 SCC config is currently APPLIED - reversing..."

    oc adm policy remove-cluster-role-from-user system:controller:persistent-volume-binder \
        system:serviceaccount:${PROJECT_CPD_INST_OPERANDS}:zen-databases-sa

    oc annotate namespace ${PROJECT_CPD_INST_OPERANDS} --overwrite \
        openshift.io/sa.scc.supplemental-groups- \
        openshift.io/sa.scc.uid-range- \
        openshift.io/sa.scc.mcs-

    oc delete configmap db2u-product-cm -n ${PROJECT_CPD_INST_OPERATORS}

    echo "[INFO] restricted-v2 SCC config has been removed."
else
    echo "[INFO] restricted-v2 SCC config is NOT applied - applying..."

    oc adm policy add-cluster-role-to-user system:controller:persistent-volume-binder \
        system:serviceaccount:${PROJECT_CPD_INST_OPERANDS}:zen-databases-sa

    oc annotate namespace ${PROJECT_CPD_INST_OPERANDS} --overwrite \
        openshift.io/sa.scc.supplemental-groups=${uidGidRange} \
        openshift.io/sa.scc.uid-range=${uidGidRange} \
        openshift.io/sa.scc.mcs=s0:c27,c51

    oc apply -f - <<EOF
apiVersion: v1
data:
  DB2U_RUN_WITH_LIMITED_PRIVS: "false"
kind: ConfigMap
metadata:
  name: db2u-product-cm
  namespace: ${PROJECT_CPD_INST_OPERATORS}
EOF

    echo "[INFO] restricted-v2 SCC config has been applied."
fi