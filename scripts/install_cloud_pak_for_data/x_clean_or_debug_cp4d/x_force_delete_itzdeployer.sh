#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# Everything below uses the local oc client, so log it in (CPDM_OC_LOGIN only
# logs in the cpd-cli container).
eval "${OC_LOGIN}"

# ---------------------------------------------------------------------------
# What gets removed, and in which order.
#
# On TechZone clusters the chain is:
#   TechZone hub ArgoCD (via ACM cluster-proxy, as
#   open-cluster-management-agent-addon:application-manager, self-heal on)
#     -> CatalogSource + Subscription (OLM) + Installation CR (techzone.techzone.ibm.com)
#   OLM -> itz-deployer-operator CSV (AllNamespaces: copied into every namespace)
#   operator -> "<cr>-status-banner" ConsoleNotification + "<cr>-ansible-runner" Job
#     -> cloud-pak-deployer namespace/job -> "cpd-console-banner" ConsoleNotification
#        (text = openshift[].console_banner from cloud-pak-deployer-config)
#
# Anything deleted while the hub can still create it comes straight back, so
# the reinstall block (ValidatingAdmissionPolicy) must be in place first.
# ---------------------------------------------------------------------------

ITZ_CSV_PATTERN="itz-deployer-operator"
ITZ_CRD_GROUP="techzone.techzone.ibm.com"
POLICY_NAME="block-itz-deployer"
BINDING_NAME="block-itz-deployer-binding"
EMPTY_FINALIZERS='[{"op":"replace","path":"/metadata/finalizers","value":[]}]'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_force_delete() {
    local kind="$1" name="$2" ns_flag="$3"
    echo "[DELETE] ${kind}/${name}"
    # Strip finalizers first so the API server won't block the delete
    oc patch "${kind}" "${name}" ${=ns_flag} \
        --type='json' -p="${EMPTY_FINALIZERS}" \
        2>/dev/null || true
    oc delete "${kind}" "${name}" ${=ns_flag} \
        --grace-period=0 --force --ignore-not-found 2>/dev/null || true
}

_force_delete_cluster() { _force_delete "$1" "$2" ""; }

# Prints "<ns>/<name>" for every object of a namespaced kind.
_list_ns_names() {
    oc get "$1" --all-namespaces \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
        2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Phase 0: Make sure reinstall is blocked (runs the disable script if not)
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 0: Check that itz-deployer reinstall is blocked ==="

_block_in_place() {
    # Current policy version (covers the techzone CRs) and its binding exist...
    oc get validatingadmissionpolicy "${POLICY_NAME}" -o json 2>/dev/null \
        | jq -e --arg g "${ITZ_CRD_GROUP}" \
            '[.spec.matchConstraints.resourceRules[]?.apiGroups[]?] | index($g) != null' \
            >/dev/null 2>&1 || return 1
    oc get validatingadmissionpolicybinding "${BINDING_NAME}" &>/dev/null || return 1
    # ...and the API server actually denies an itz-deployer Subscription.
    local out
    out=$(oc create --dry-run=server -o name -f - 2>&1 <<'EOF' || true
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: itz-deployer-operator
  namespace: openshift-operators
spec:
  name: itz-deployer-operator
  source: does-not-exist
  sourceNamespace: openshift-marketplace
EOF
)
    [[ "${out}" == *"is blocked on this cluster"* ]]
}

if _block_in_place; then
    echo "[INFO] ${POLICY_NAME} is in place and denying itz-deployer creates."
else
    echo "[INFO] Reinstall block missing or outdated - running x_force_disable_itzdeployer_reinstall.sh first..."
    "${SCRIPT_DIR}/x_force_disable_itzdeployer_reinstall.sh"
    if ! _block_in_place; then
        echo "[ERROR] Reinstall block still not effective - aborting (deleted objects would be recreated)." >&2
        exit 1
    fi
    echo "[INFO] Reinstall block verified."
fi

# ---------------------------------------------------------------------------
# Phase 1: Discover everything up front (some of it is only findable while
# its parent still exists, e.g. banner names derived from CR names)
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 1: Discover itz-deployer resources ==="

# CRDs in the techzone group (Installation on current deployer versions,
# Deployment on older ones)
ITZ_CRDS=(${(f)"$(oc get crd -o json 2>/dev/null \
    | jq -r --arg g "${ITZ_CRD_GROUP}" '.items[] | select(.spec.group == $g) | .metadata.name' \
    || true)"})
echo "[INFO] techzone CRDs: ${ITZ_CRDS[*]:-none}"

# CRs as "<crd>|<ns>|<name>"
ITZ_CRS=()
for CRD in "${ITZ_CRDS[@]}"; do
    [[ -z "${CRD:-}" ]] && continue
    for ENTRY in ${(f)"$(_list_ns_names "${CRD}")"}; do
        [[ -z "${ENTRY:-}" ]] && continue
        ITZ_CRS+=("${CRD}|${ENTRY%%/*}|${ENTRY##*/}")
    done
done
echo "[INFO] techzone CRs: ${#ITZ_CRS[@]}"

# Namespaces the operator itself runs in (parent CSV, not OLM's copies)
OPERATOR_NAMESPACES=(${(f)"$(oc get clusterserviceversions.operators.coreos.com --all-namespaces \
    -l '!olm.copiedFrom' -o json 2>/dev/null \
    | jq -r --arg p "${ITZ_CSV_PATTERN}" '.items[] | select(.metadata.name | startswith($p)) | .metadata.namespace' \
    | sort -u || true)"})
echo "[INFO] Operator namespace(s): ${OPERATOR_NAMESPACES[*]:-none}"

# Console banners: the operator's per-CR status banner, cloud-pak-deployer's
# banner (fixed name + configured text), and anything named *deployer*.
BANNER_NAMES=("cpd-console-banner")
for ENTRY in "${ITZ_CRS[@]}"; do
    BANNER_NAMES+=("${ENTRY##*|}-status-banner")
done
BANNER_TEXTS=(${(f)"$(oc get configmap --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.name == "cloud-pak-deployer-config") | .data[]?' \
    | sed -n 's/^[[:space:]]*console_banner:[[:space:]]*//p' \
    | sed -e 's/^["'"'"']//' -e 's/["'"'"'][[:space:]]*$//' \
    | sort -u || true)"})
CN_NAMES=()
for LINE in ${(f)"$(oc get consolenotification -o json 2>/dev/null \
    | jq -r '.items[] | "\(.metadata.name)\t\(.spec.text // "")"' || true)"}; do
    [[ -z "${LINE:-}" ]] && continue
    CN_NAME="${LINE%%$'\t'*}"
    CN_TEXT="${LINE#*$'\t'}"
    if (( ${BANNER_NAMES[(Ie)${CN_NAME}]} )) || (( ${BANNER_TEXTS[(Ie)${CN_TEXT}]} )) \
        || [[ "${CN_NAME}" == *deployer* ]]; then
        CN_NAMES+=("${CN_NAME}")
    fi
done
echo "[INFO] Console banners to remove: ${CN_NAMES[*]:-none}"

# Report who keeps (re)creating these objects
WRITERS=$( {
    oc get subscriptions.operators.coreos.com,catalogsources.operators.coreos.com --all-namespaces \
        -o json --show-managed-fields 2>/dev/null \
        | jq -r --arg p "itz-deployer" '.items[] | select(.metadata.name | contains($p)) | .metadata.managedFields[]?.manager' || true
    for ENTRY in "${ITZ_CRS[@]}"; do
        IFS='|' read -r CRD CR_NS CR_NAME <<< "${ENTRY}"
        oc get "${CRD}" "${CR_NAME}" -n "${CR_NS}" -o json --show-managed-fields 2>/dev/null \
            | jq -r '.metadata.managedFields[]?.manager' || true
    done
} | sort -u | tr '\n' ' ')
if [[ "${WRITERS}" == *argocd* ]]; then
    if oc get crd applications.argoproj.io &>/dev/null; then
        echo "[INFO] Written by ArgoCD (field managers: ${WRITERS})."
    else
        echo "[INFO] Written by an ArgoCD that is NOT on this cluster (TechZone hub via ACM; field managers: ${WRITERS})."
        echo "[INFO] It cannot be suspended from here - the ${POLICY_NAME} policy is what stops it."
    fi
fi

# ---------------------------------------------------------------------------
# Phase 2: Suspend local ArgoCD Applications that manage techzone resources
# (only relevant when ArgoCD runs on this cluster)
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 2: Suspend local ArgoCD Applications managing itz-deployer resources ==="

if oc get crd applications.argoproj.io &>/dev/null; then
    ARGOCD_APP_NAMES=()
    for APP_ENTRY in ${(f)"$(_list_ns_names application.argoproj.io)"}; do
        [[ -z "${APP_ENTRY:-}" ]] && continue
        APP_NS="${APP_ENTRY%%/*}"
        APP_NAME="${APP_ENTRY##*/}"
        APP_GROUPS=$(oc get application.argoproj.io "${APP_NAME}" -n "${APP_NS}" \
            -o jsonpath='{.status.resources[*].group}' 2>/dev/null || true)
        if [[ "${APP_GROUPS}" == *"${ITZ_CRD_GROUP}"* ]]; then
            ARGOCD_APP_NAMES+=("${APP_ENTRY}")
            echo "[SUSPEND] ArgoCD Application ${APP_NAME} (ns: ${APP_NS})"
            oc patch application.argoproj.io "${APP_NAME}" -n "${APP_NS}" \
                --type='merge' -p='{"spec":{"syncPolicy":{"automated":null}}}' \
                2>/dev/null || true
        fi
    done
    if [[ ${#ARGOCD_APP_NAMES[@]} -eq 0 ]]; then
        echo "[INFO] No local ArgoCD Applications found managing itz-deployer resources."
    fi
else
    echo "[INFO] ArgoCD CRD not present - skipping (an external ArgoCD is handled by Phase 0)."
fi

# ---------------------------------------------------------------------------
# Phase 3: Delete the techzone CRs
# Done while the operator still runs, so its finalizer
# (techzone.ibm.com/console-notification-cleanup) removes the status banner and
# the ansible-runner Job itself. Anything left after the wait is forced.
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 3: Delete techzone CRs (${#ITZ_CRS[@]}) ==="

if [[ ${#ITZ_CRS[@]} -eq 0 ]]; then
    echo "[INFO] No techzone CRs found."
else
    for ENTRY in "${ITZ_CRS[@]}"; do
        IFS='|' read -r CRD CR_NS CR_NAME <<< "${ENTRY}"
        echo "[DELETE] ${CRD}/${CR_NAME} (ns: ${CR_NS})"
        # Remove ArgoCD tracking annotation so a local ArgoCD won't re-adopt it
        oc annotate "${CRD}" "${CR_NAME}" -n "${CR_NS}" "argocd.argoproj.io/tracking-id-" \
            2>/dev/null || true
        oc delete "${CRD}" "${CR_NAME}" -n "${CR_NS}" --wait=false --ignore-not-found \
            2>/dev/null || true
    done

    _remaining_crs() {
        local n=0 ENTRY CRD CR_NS CR_NAME
        for ENTRY in "${ITZ_CRS[@]}"; do
            IFS='|' read -r CRD CR_NS CR_NAME <<< "${ENTRY}"
            oc get "${CRD}" "${CR_NAME}" -n "${CR_NS}" &>/dev/null && (( n++ )) || true
        done
        echo "${n}"
    }

    echo "[INFO] Waiting up to 60s for the operator to finalize the CRs..."
    for _i in {1..12}; do
        LEFT=$(_remaining_crs)
        echo "[INFO] CRs finalized: $(( ${#ITZ_CRS[@]} - LEFT ))/${#ITZ_CRS[@]} ($(( (${#ITZ_CRS[@]} - LEFT) * 100 / ${#ITZ_CRS[@]} ))%)"
        [[ "${LEFT}" -eq 0 ]] && break
        sleep 5
    done

    if [[ "$(_remaining_crs)" -gt 0 ]]; then
        echo "[INFO] Operator did not finalize everything - forcing."
        # The operator's validating webhook rejects writes when the operator is
        # down, which would block the finalizer patch.
        for WH in ${(f)"$(oc get validatingwebhookconfiguration,mutatingwebhookconfiguration -o json 2>/dev/null \
            | jq -r --arg p "${ITZ_CSV_PATTERN}" '.items[] | select(
                ((.metadata.labels["olm.owner"] // "") | startswith($p))
                or ([.webhooks[]?.clientConfig.service.name // ""] | any(startswith($p)))
              ) | "\(.kind | ascii_downcase)/\(.metadata.name)"' || true)"}; do
            [[ -z "${WH:-}" ]] && continue
            _force_delete_cluster "${WH%%/*}" "${WH##*/}"
        done
        for ENTRY in "${ITZ_CRS[@]}"; do
            IFS='|' read -r CRD CR_NS CR_NAME <<< "${ENTRY}"
            oc get "${CRD}" "${CR_NAME}" -n "${CR_NS}" &>/dev/null || continue
            _force_delete "${CRD}" "${CR_NAME}" "-n ${CR_NS}"
        done
    fi
fi

# ---------------------------------------------------------------------------
# Phase 4: OLM - Subscription, InstallPlans, CatalogSource, CSV
# Deleting the parent CSV is enough: OLM removes the copied CSVs (one per
# namespace), the operator Deployment, its webhooks and its RBAC. Deleting the
# copies directly just makes OLM recreate them.
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 4: Delete Subscription / InstallPlans / CatalogSource / CSV ==="

SUB_ALL=(${(f)"$(oc get subscriptions.operators.coreos.com --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(
        (.metadata.name | test("itz-deployer"; "i"))
        or (.spec.name // "" | test("itz-deployer"; "i"))
      ) | "\(.metadata.namespace)/\(.metadata.name)"' || true)"})
for ENTRY in "${SUB_ALL[@]}"; do
    [[ -z "${ENTRY:-}" ]] && continue
    SUB_NS="${ENTRY%%/*}"
    SUB="${ENTRY##*/}"
    echo "[DELETE] subscription/${SUB} (ns: ${SUB_NS})"
    oc delete subscriptions.operators.coreos.com "${SUB}" -n "${SUB_NS}" --ignore-not-found \
        2>/dev/null || true
done
[[ -z "${SUB_ALL[1]:-}" ]] && echo "[INFO] No itz-deployer Subscriptions found."

for ENTRY in ${(f)"$(oc get installplans.operators.coreos.com --all-namespaces -o json 2>/dev/null \
    | jq -r --arg p "${ITZ_CSV_PATTERN}" '.items[]
        | select([.spec.clusterServiceVersionNames[]? | startswith($p)] | any)
        | "\(.metadata.namespace)/\(.metadata.name)"' || true)"}; do
    [[ -z "${ENTRY:-}" ]] && continue
    echo "[DELETE] installplan/${ENTRY##*/} (ns: ${ENTRY%%/*})"
    oc delete installplans.operators.coreos.com "${ENTRY##*/}" -n "${ENTRY%%/*}" --ignore-not-found \
        2>/dev/null || true
done

CS_NAMES=(${(f)"$(oc get catalogsource --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(
        (.metadata.name | test("itz-deployer"; "i"))
        or (.spec.displayName // "" | test("itz.deployer|technology.zone.deployer"; "i"))
        or (.spec.image // "" | test("itz-deployer"; "i"))
      ) | "\(.metadata.namespace)/\(.metadata.name)"' || true)"})
for ENTRY in "${CS_NAMES[@]}"; do
    [[ -z "${ENTRY:-}" ]] && continue
    echo "[DELETE] catalogsource/${ENTRY##*/} (ns: ${ENTRY%%/*})"
    oc delete catalogsource "${ENTRY##*/}" -n "${ENTRY%%/*}" --ignore-not-found 2>/dev/null || true
done
[[ -z "${CS_NAMES[1]:-}" ]] && echo "[INFO] No itz-deployer CatalogSource found."

# Parent CSV(s) only
for ENTRY in ${(f)"$(oc get clusterserviceversions.operators.coreos.com --all-namespaces \
    -l '!olm.copiedFrom' -o json 2>/dev/null \
    | jq -r --arg p "${ITZ_CSV_PATTERN}" '.items[] | select(.metadata.name | startswith($p))
        | "\(.metadata.namespace)/\(.metadata.name)"' || true)"}; do
    [[ -z "${ENTRY:-}" ]] && continue
    echo "[DELETE] csv/${ENTRY##*/} (ns: ${ENTRY%%/*})"
    oc delete clusterserviceversions.operators.coreos.com "${ENTRY##*/}" -n "${ENTRY%%/*}" \
        --wait=false --ignore-not-found 2>/dev/null || true
done

_count_csvs() {
    oc get clusterserviceversions.operators.coreos.com --all-namespaces -o json 2>/dev/null \
        | jq --arg p "${ITZ_CSV_PATTERN}" '[.items[] | select(.metadata.name | startswith($p))] | length' \
        || echo 0
}
CSV_TOTAL=$(_count_csvs)
if [[ "${CSV_TOTAL}" -gt 0 ]]; then
    echo "[INFO] Waiting up to 3m for OLM to remove ${CSV_TOTAL} CSV copies..."
    for _i in {1..36}; do
        LEFT=$(_count_csvs)
        echo "[INFO] CSVs removed: $(( CSV_TOTAL - LEFT ))/${CSV_TOTAL} ($(( (CSV_TOTAL - LEFT) * 100 / CSV_TOTAL ))%)"
        [[ "${LEFT}" -eq 0 ]] && break
        sleep 5
    done
    # Copies that outlived their parent are orphans OLM won't recreate
    for ENTRY in ${(f)"$(_list_ns_names clusterserviceversions.operators.coreos.com | grep "/${ITZ_CSV_PATTERN}" || true)"}; do
        [[ -z "${ENTRY:-}" ]] && continue
        _force_delete "clusterserviceversions.operators.coreos.com" "${ENTRY##*/}" "-n ${ENTRY%%/*}"
    done
else
    echo "[INFO] No itz-deployer CSVs found."
fi

for ENTRY in ${(f)"$(_list_ns_names operatorcondition | grep "/${ITZ_CSV_PATTERN}" || true)"}; do
    [[ -z "${ENTRY:-}" ]] && continue
    _force_delete "operatorcondition" "${ENTRY##*/}" "-n ${ENTRY%%/*}"
done

for OP in ${(f)"$(oc get operators.operators.coreos.com -o name 2>/dev/null | grep "/${ITZ_CSV_PATTERN}" || true)"}; do
    [[ -z "${OP:-}" ]] && continue
    echo "[DELETE] ${OP}"
    oc delete "${OP}" --ignore-not-found 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# Phase 5: Leftovers OLM didn't clean up - Deployment, webhooks, RBAC, SA,
# operator certs (only in the operator's namespace: the secret names are
# kubebuilder defaults shared with other operators)
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 5: Delete operator leftovers ==="

for ENTRY in ${(f)"$(_list_ns_names deployment | grep "/${ITZ_CSV_PATTERN}-controller-manager$" || true)"}; do
    [[ -z "${ENTRY:-}" ]] && continue
    _force_delete "deployment" "${ENTRY##*/}" "-n ${ENTRY%%/*}"
done

for WH in ${(f)"$(oc get validatingwebhookconfiguration,mutatingwebhookconfiguration -o json 2>/dev/null \
    | jq -r --arg p "${ITZ_CSV_PATTERN}" '.items[] | select(
        ((.metadata.labels["olm.owner"] // "") | startswith($p))
        or ([.webhooks[]?.clientConfig.service.name // ""] | any(startswith($p)))
      ) | "\(.kind | ascii_downcase)/\(.metadata.name)"' || true)"}; do
    [[ -z "${WH:-}" ]] && continue
    _force_delete_cluster "${WH%%/*}" "${WH##*/}"
done

# ClusterRoles/Bindings labelled as owned by the CSV (includes the
# openshift-gitops-* bindings it ships), plus the cluster-admin binding for
# default:pipeline that the operator creates at runtime.
for RB in ${(f)"$(oc get clusterrole,clusterrolebinding -o json 2>/dev/null \
    | jq -r --arg p "${ITZ_CSV_PATTERN}" '.items[] | select(
        ((.metadata.labels["olm.owner"] // "") | startswith($p))
        or (.metadata.name | startswith($p))
        or (.kind == "ClusterRoleBinding" and .metadata.name == "pipeline-clusteradmin-crb"
            and .roleRef.name == "cluster-admin"
            and ([.subjects[]? | "\(.namespace)/\(.name)"] == ["default/pipeline"]))
      ) | "\(.kind | ascii_downcase)/\(.metadata.name)"' || true)"}; do
    [[ -z "${RB:-}" ]] && continue
    _force_delete_cluster "${RB%%/*}" "${RB##*/}"
done

for OP_NS in "${OPERATOR_NAMESPACES[@]}"; do
    [[ -z "${OP_NS:-}" ]] && continue
    _force_delete "serviceaccount" "${ITZ_CSV_PATTERN}-controller-manager" "-n ${OP_NS}"
    for SECRET in "webhook-server-cert" "metrics-server-cert"; do
        oc get secret "${SECRET}" -n "${OP_NS}" &>/dev/null || continue
        _force_delete "secret" "${SECRET}" "-n ${OP_NS}"
    done
done

# ---------------------------------------------------------------------------
# Phase 6: Runner Jobs, Tekton PipelineRuns/TaskRuns and Results records
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 6: Delete itz-deployer runner Jobs / PipelineRuns / TaskRuns / Results ==="

# <cr>-ansible-runner Jobs (owned by the CR, normally garbage-collected with it)
for ENTRY in ${(f)"$(oc get job --all-namespaces -l app=ansible-runner \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"}; do
    [[ -z "${ENTRY:-}" ]] && continue
    echo "[DELETE] job/${ENTRY##*/} (ns: ${ENTRY%%/*})"
    oc delete job "${ENTRY##*/}" -n "${ENTRY%%/*}" --cascade=foreground --wait=false \
        --ignore-not-found 2>/dev/null || true
done

TEKTON_PIPELINERUN_CRD_EXISTS=false
TEKTON_TASKRUN_CRD_EXISTS=false
oc get crd pipelineruns.tekton.dev &>/dev/null && TEKTON_PIPELINERUN_CRD_EXISTS=true || true
oc get crd taskruns.tekton.dev    &>/dev/null && TEKTON_TASKRUN_CRD_EXISTS=true    || true

if [[ "${TEKTON_PIPELINERUN_CRD_EXISTS}" == "false" && "${TEKTON_TASKRUN_CRD_EXISTS}" == "false" ]]; then
    echo "[INFO] Tekton CRDs not present - skipping."
else
    PR_DELETED=0
    TR_DELETED=0
    for KIND in pipelinerun taskrun; do
        [[ "${KIND}" == "pipelinerun" && "${TEKTON_PIPELINERUN_CRD_EXISTS}" == "false" ]] && continue
        [[ "${KIND}" == "taskrun" && "${TEKTON_TASKRUN_CRD_EXISTS}" == "false" ]] && continue
        RUN_ALL=(${(f)"$(_list_ns_names "${KIND}")"})
        RUN_MATCHES=(${(M)RUN_ALL:#*run-deployer*})
        if [[ -z "${RUN_MATCHES[1]:-}" ]]; then
            echo "[INFO] No itz-deployer ${KIND}s found."
            continue
        fi
        for ENTRY in "${RUN_MATCHES[@]}"; do
            [[ -z "${ENTRY:-}" ]] && continue
            _force_delete "${KIND}" "${ENTRY##*/}" "-n ${ENTRY%%/*}"
            if [[ "${KIND}" == "pipelinerun" ]]; then (( PR_DELETED++ )) || true; else (( TR_DELETED++ )) || true; fi
        done
    done
    echo "[INFO] Deleted ${PR_DELETED} PipelineRun(s) and ${TR_DELETED} TaskRun(s)."
fi

# Archived Tekton Results records persist after the live PipelineRun is gone
# and show up as "fetched from Tekton Results" in the Pipelines UI.
RESULTS_SVC=$(oc get svc -n openshift-pipelines --no-headers 2>/dev/null \
    | awk '/tekton-results.*api/{print $1}' | head -1 || true)

if [[ -z "${RESULTS_SVC:-}" ]]; then
    echo "[INFO] Tekton Results service not found - skipping."
else
    RESULTS_TOKEN=$(oc whoami -t 2>/dev/null || true)
    LOCAL_PORT=18443

    echo "[INFO] Port-forwarding ${RESULTS_SVC}:8443 → localhost:${LOCAL_PORT}..."
    oc port-forward -n openshift-pipelines "svc/${RESULTS_SVC}" "${LOCAL_PORT}:8443" &>/dev/null &
    PF_PID=$!
    sleep 3

    RECORD_NAMES=()
    { RECORD_NAMES=(${(f)"$(curl -sk -H "Authorization: Bearer ${RESULTS_TOKEN}" \
        "https://localhost:${LOCAL_PORT}/apis/results.tekton.dev/v1alpha2/parents/-/results/-/records" \
        | jq -r '.records[] | select(.name | test("run-deployer")) | .name' 2>/dev/null)"}) } 2>/dev/null || true

    if [[ -z "${RECORD_NAMES[1]:-}" ]]; then
        echo "[INFO] No itz-deployer records found in Tekton Results."
    else
        for RECORD in "${RECORD_NAMES[@]}"; do
            [[ -z "${RECORD:-}" ]] && continue
            echo "[DELETE] results record: ${RECORD}"
            curl -sk -X DELETE -H "Authorization: Bearer ${RESULTS_TOKEN}" \
                "https://localhost:${LOCAL_PORT}/apis/results.tekton.dev/v1alpha2/parents/${RECORD}" \
                2>/dev/null || true
            # Also delete the parent Result (strip /records/<id> suffix)
            RESULT_PARENT="${RECORD%/records/*}"
            curl -sk -X DELETE -H "Authorization: Bearer ${RESULTS_TOKEN}" \
                "https://localhost:${LOCAL_PORT}/apis/results.tekton.dev/v1alpha2/parents/${RESULT_PARENT}" \
                2>/dev/null || true
        done
    fi

    kill $PF_PID 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Phase 7: Console banners (ConsoleNotifications found in Phase 1)
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 7: Delete deployer ConsoleNotifications ==="

if [[ ${#CN_NAMES[@]} -eq 0 ]]; then
    echo "[INFO] No deployer ConsoleNotifications found."
else
    for CN in "${CN_NAMES[@]}"; do
        [[ -z "${CN:-}" ]] && continue
        _force_delete_cluster "consolenotification" "${CN}"
    done
fi

# ---------------------------------------------------------------------------
# Phase 8: techzone CRDs
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 8: Delete techzone CRDs ==="

if [[ ${#ITZ_CRDS[@]} -eq 0 || -z "${ITZ_CRDS[1]:-}" ]]; then
    echo "[INFO] No techzone CRDs present."
else
    for CRD in "${ITZ_CRDS[@]}"; do
        [[ -z "${CRD:-}" ]] && continue
        _force_delete_cluster "crd" "${CRD}"
    done
fi

# ---------------------------------------------------------------------------
# Phase 9: Force-delete namespaces created by cloud-pak-deployer
# (openshift.io/requester = any service account in the cloud-pak-deployer
# namespace, e.g. cloud-pak-deployer-sa or cpd-sa), plus any namespace whose
# name contains "cloud-pak-deployer". Namespaces named in the loaded config
# (PROJECT_* variables, i.e. your own CP4D install) are never touched.
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 9: Delete cloud-pak-deployer namespaces ==="

CPD_SA_REQUESTER_PREFIX="system:serviceaccount:cloud-pak-deployer:"

PROTECTED_NS=(default)
for _V in ${(k)parameters[(I)PROJECT_*]}; do
    [[ -n "${(P)_V:-}" ]] && PROTECTED_NS+=("${(P)_V}")
done

CPD_NS_COMBINED=(${(f)"$(oc get namespace -o json 2>/dev/null \
    | jq -r --arg req "${CPD_SA_REQUESTER_PREFIX}" '.items[] | select(
        ((.metadata.annotations["openshift.io/requester"] // "") | startswith($req))
        or (.metadata.name | contains("cloud-pak-deployer"))
      ) | .metadata.name' | sort -u || true)"})

CPD_NS_TARGETS=()
for _NS in "${CPD_NS_COMBINED[@]}"; do
    [[ -z "${_NS:-}" ]] && continue
    if (( ${PROTECTED_NS[(Ie)${_NS}]} )) || [[ "${_NS}" == openshift* || "${_NS}" == kube-* ]]; then
        echo "[SKIP] namespace/${_NS} (protected by the loaded config)"
        continue
    fi
    CPD_NS_TARGETS+=("${_NS}")
done

if [[ ${#CPD_NS_TARGETS[@]} -eq 0 ]]; then
    echo "[INFO] No cloud-pak-deployer namespaces found."
else
    echo "[INFO] Namespaces to delete: ${CPD_NS_TARGETS[*]}"

    # Start deleting all of them at once
    for CPD_NS in "${CPD_NS_TARGETS[@]}"; do
        oc annotate namespace "${CPD_NS}" "openshift.io/requester-" 2>/dev/null || true
        echo "[DELETE] namespace/${CPD_NS} (started)"
        oc delete namespace "${CPD_NS}" --wait=false --ignore-not-found 2>/dev/null || true
    done

    # Strip finalizers from everything inside so termination can't hang on a
    # controller that is already gone. One list call per kind covers all target
    # namespaces (-A, filtered in jq), and SWEEP_PARALLEL kinds run at a time.
    NS_KINDS=(${(f)"$(oc api-resources --verbs=list --namespaced -o name 2>/dev/null || true)"})
    TARGETS_JSON=$(printf '%s\n' "${CPD_NS_TARGETS[@]}" | jq -R . | jq -cs .)
    SWEEP_PARALLEL="${SWEEP_PARALLEL:-8}"

    _sweep_kind() {
        local kind="$1" ENTRY
        for ENTRY in ${(f)"$(oc get "${kind}" --all-namespaces -o json 2>/dev/null \
            | jq -r --argjson ns "${TARGETS_JSON}" '.items[]?
                | select((.metadata.namespace | IN($ns[])) and ((.metadata.finalizers // []) | length > 0))
                | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || true)"}; do
            [[ -z "${ENTRY:-}" ]] && continue
            oc patch "${kind}" "${ENTRY##*/}" -n "${ENTRY%%/*}" \
                --type='json' -p="${EMPTY_FINALIZERS}" >/dev/null 2>&1 || true
        done
    }

    echo "[INFO] Finalizer sweep: ${#NS_KINDS[@]} kinds x ${#CPD_NS_TARGETS[@]} namespaces, ${SWEEP_PARALLEL} kinds in parallel"
    KIND_DONE=0
    for RESOURCE_KIND in "${NS_KINDS[@]}"; do
        _sweep_kind "${RESOURCE_KIND}" &
        (( KIND_DONE++ )) || true
        if (( KIND_DONE % SWEEP_PARALLEL == 0 || KIND_DONE == ${#NS_KINDS[@]} )); then
            wait
            echo "[INFO]   finalizer sweep: ${KIND_DONE}/${#NS_KINDS[@]} kinds ($(( KIND_DONE * 100 / ${#NS_KINDS[@]} ))%)"
        fi
    done

    # Clear spec.finalizers via the /finalize subresource - the only way to
    # unblock a namespace stuck in Terminating
    for _WAIT in 1 2 3; do
        NS_LEFT=0
        for CPD_NS in "${CPD_NS_TARGETS[@]}"; do
            NS_JSON=$(oc get namespace "${CPD_NS}" -o json 2>/dev/null || true)
            [[ -z "${NS_JSON}" ]] && continue
            (( NS_LEFT++ )) || true
            echo "[INFO] namespace/${CPD_NS} still $(echo "${NS_JSON}" | jq -r '.status.phase'), clearing spec.finalizers..."
            echo "${NS_JSON}" | jq '.spec.finalizers = []' \
                | oc replace --raw "/api/v1/namespaces/${CPD_NS}/finalize" -f - >/dev/null 2>&1 || true
        done
        [[ "${NS_LEFT}" -eq 0 ]] && break
        sleep 5
    done
    for CPD_NS in "${CPD_NS_TARGETS[@]}"; do
        oc get namespace "${CPD_NS}" &>/dev/null \
            && echo "[WARN] namespace/${CPD_NS} still present" \
            || echo "[DELETE] namespace/${CPD_NS} gone"
    done
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Verification ==="
LEFTOVERS=$( {
    oc get subscriptions.operators.coreos.com,catalogsources.operators.coreos.com --all-namespaces --no-headers 2>/dev/null | grep -i "itz-deployer" || true
    oc get clusterserviceversions.operators.coreos.com --all-namespaces --no-headers 2>/dev/null | grep "${ITZ_CSV_PATTERN}" || true
    oc get crd -o name 2>/dev/null | grep "${ITZ_CRD_GROUP}" || true
    for CN in "${CN_NAMES[@]}"; do oc get consolenotification "${CN}" -o name 2>/dev/null || true; done
} )
if [[ -n "${LEFTOVERS}" ]]; then
    echo "[WARN] Still present:"
    echo "${LEFTOVERS}"
else
    echo "[OK] No itz-deployer Subscription, CatalogSource, CSV, CRD or banner left."
fi

echo ""
echo "[DONE] itz-deployer-operator and dependents force-deleted. ${POLICY_NAME} stays in place to keep it out."
