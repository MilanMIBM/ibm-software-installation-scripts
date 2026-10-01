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

eval "${CPDM_OC_LOGIN}"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# The CSV name pattern (version suffix can vary)
ITZ_CSV_PATTERN="itz-deployer-operator"

# The CRD owned by the operator
ITZ_CRD="deployments.techzone.techzone.ibm.com"

# The controller-manager deployment name
ITZ_DEPLOY_NAME="itz-deployer-operator-controller-manager"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_force_delete() {
    local kind="$1" name="$2" ns_flag="$3"
    echo "[DELETE] ${kind}/${name}"
    # Strip finalizers first so the API server won't block the delete
    oc patch "${kind}" "${name}" ${ns_flag} \
        --type='json' -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' \
        2>/dev/null || true
    oc delete "${kind}" "${name}" ${ns_flag} \
        --grace-period=0 --force --ignore-not-found 2>/dev/null || true
}

_force_delete_cluster() { _force_delete "$1" "$2" ""; }

# ---------------------------------------------------------------------------
# Phase 1: Suspend ArgoCD Applications that manage itz-deployer resources
# (ArgoCD will recreate deleted CRs on the next sync if not suspended first)
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 1: Suspend ArgoCD Applications managing itz-deployer resources ==="

ARGOCD_APP_NAMES=()
if oc get crd applications.argoproj.io &>/dev/null; then
    ALL_APPS=(${(f)"$(oc get application.argoproj.io --all-namespaces \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
        2>/dev/null || true)"})
    for APP_ENTRY in "${ALL_APPS[@]}"; do
        [[ -z "${APP_ENTRY:-}" ]] && continue
        APP_NS="${APP_ENTRY%%/*}"
        APP_NAME="${APP_ENTRY##*/}"
        MANAGES_ITZ=$(oc get application.argoproj.io "${APP_NAME}" -n "${APP_NS}" \
            -o jsonpath='{.status.resources[*].group}' 2>/dev/null \
            | grep -c "techzone.techzone.ibm.com" || true)
        if [[ "${MANAGES_ITZ}" -gt 0 ]]; then
            ARGOCD_APP_NAMES+=("${APP_ENTRY}")
            echo "[SUSPEND] ArgoCD Application ${APP_NAME} (ns: ${APP_NS})"
            oc patch application.argoproj.io "${APP_NAME}" -n "${APP_NS}" \
                --type='merge' -p='{"spec":{"syncPolicy":{"automated":null}}}' \
                2>/dev/null || true
        fi
    done
    if [[ ${#ARGOCD_APP_NAMES[@]} -eq 0 ]]; then
        echo "[INFO] No ArgoCD Applications found managing itz-deployer resources."
    fi
else
    echo "[INFO] ArgoCD CRD not present - skipping ArgoCD suspension."
fi

# ---------------------------------------------------------------------------
# Phase 2: Stop the operator - scale to zero then delete the Deployment
# (must happen before CRs so the controller can't recreate them)
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 2: Stop controller-manager Deployment (all namespaces) ==="

DEPLOY_ALL=(${(f)"$(oc get deployment --all-namespaces \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep "${ITZ_DEPLOY_NAME}" || true)"})

if [[ ${#DEPLOY_ALL[@]} -eq 0 || -z "${DEPLOY_ALL[1]:-}" ]]; then
    echo "[INFO] Deployment ${ITZ_DEPLOY_NAME} not found in any namespace."
else
    for ENTRY in "${DEPLOY_ALL[@]}"; do
        [[ -z "${ENTRY:-}" ]] && continue
        D_NS="${ENTRY%%/*}"
        D_NAME="${ENTRY##*/}"
        echo "[INFO] Scaling ${D_NAME} to 0 replicas (ns: ${D_NS})..."
        oc scale deployment "${D_NAME}" -n "${D_NS}" --replicas=0 2>/dev/null || true
        PODS=(${(f)"$(oc get pods -n "${D_NS}" \
            -l "app.kubernetes.io/name=itz-deployer-operator" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
            2>/dev/null || true)"})
        for POD in "${PODS[@]}"; do
            [[ -z "${POD:-}" ]] && continue
            echo "[DELETE] pod/${POD} (ns: ${D_NS})"
            oc delete pod "${POD}" -n "${D_NS}" --grace-period=0 --force --ignore-not-found 2>/dev/null || true
        done
        echo "[DELETE] deployment/${D_NAME} (ns: ${D_NS})"
        oc patch deployment "${D_NAME}" -n "${D_NS}" \
            --type='json' -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' \
            2>/dev/null || true
        oc delete deployment "${D_NAME}" -n "${D_NS}" \
            --grace-period=0 --force --ignore-not-found 2>/dev/null || true
    done
fi

# ---------------------------------------------------------------------------
# Phase 3: Delete ValidatingWebhookConfiguration
# Must happen before CR deletion - the webhook intercepts every write to the
# CRD and rejects it when the operator service has no endpoints.
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 3: Delete ValidatingWebhookConfiguration ==="

# Match by name pattern AND by service name reference to catch generated-suffix variants
WEBHOOK_NAMES=(${(f)"$(oc get validatingwebhookconfiguration \
    -o json 2>/dev/null \
    | jq -r '.items[] | select(
        (.metadata.name | test("itz-deployer|vdeployment\\.kb\\.io"; "i"))
        or
        (.webhooks[]?.clientConfig.service.name == "itz-deployer-operator-controller-manager-service")
      ) | .metadata.name' || true)"})

for WH in "${WEBHOOK_NAMES[@]}"; do
    [[ -z "${WH:-}" ]] && continue
    _force_delete_cluster "validatingwebhookconfiguration" "${WH}"
done

if [[ ${#WEBHOOK_NAMES[@]} -eq 0 || -z "${WEBHOOK_NAMES[1]:-}" ]]; then
    echo "[INFO] No itz-deployer ValidatingWebhookConfigurations found."
fi

# ---------------------------------------------------------------------------
# Phase 4: Custom resources (Deployment CRs owned by the operator)
# Strip both the ArgoCD tracking annotation and finalizers before deleting.
# Webhook is already gone so patches go through cleanly.
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 4: Delete itz-deployer Deployment CRs (techzone.techzone.ibm.com/v1alpha1) ==="

if oc get crd "${ITZ_CRD}" &>/dev/null; then
    CR_NAMES=(${(f)"$(oc get deployments.techzone.techzone.ibm.com \
        --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
        2>/dev/null || true)"})

    if [[ ${#CR_NAMES[@]} -gt 0 && -n "${CR_NAMES[1]:-}" ]]; then
        for ENTRY in "${CR_NAMES[@]}"; do
            [[ -z "${ENTRY:-}" ]] && continue
            CR_NS="${ENTRY%%/*}"
            CR_NAME="${ENTRY##*/}"
            echo "[DELETE] deployments.techzone.techzone.ibm.com/${CR_NAME} (ns: ${CR_NS})"
            # Remove ArgoCD tracking annotation so it won't be re-adopted on next sync
            oc annotate "deployments.techzone.techzone.ibm.com" "${CR_NAME}" -n "${CR_NS}" \
                "argocd.argoproj.io/tracking-id-" \
                2>/dev/null || true
            # Strip all finalizers (notably techzone.ibm.com/console-notification-cleanup)
            oc patch "deployments.techzone.techzone.ibm.com" "${CR_NAME}" -n "${CR_NS}" \
                --type='json' -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' \
                2>/dev/null || true
            oc delete "deployments.techzone.techzone.ibm.com" "${CR_NAME}" -n "${CR_NS}" \
                --grace-period=0 --force --ignore-not-found 2>/dev/null || true
        done
    else
        echo "[INFO] No Deployment CRs found."
    fi
else
    echo "[INFO] CRD ${ITZ_CRD} not present - skipping CR deletion."
fi

# ---------------------------------------------------------------------------
# Phase 5: Tekton PipelineRuns, TaskRuns, and Results records
# Scoped to runs that match the itz-deployer naming pattern.
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 5: Delete itz-deployer PipelineRuns / TaskRuns / Results ==="

TEKTON_PIPELINERUN_CRD_EXISTS=false
TEKTON_TASKRUN_CRD_EXISTS=false
oc get crd pipelineruns.tekton.dev &>/dev/null && TEKTON_PIPELINERUN_CRD_EXISTS=true || true
oc get crd taskruns.tekton.dev    &>/dev/null && TEKTON_TASKRUN_CRD_EXISTS=true    || true

if [[ "${TEKTON_PIPELINERUN_CRD_EXISTS}" == "false" && "${TEKTON_TASKRUN_CRD_EXISTS}" == "false" ]]; then
    echo "[INFO] Tekton CRDs not present - skipping."
else
    # Collect all live PipelineRuns matching the deployer pattern across all namespaces
    PR_DELETED=0
    TR_DELETED=0

    if [[ "${TEKTON_PIPELINERUN_CRD_EXISTS}" == "true" ]]; then
        PR_ALL=()
        { PR_ALL=(${(f)"$(oc get pipelinerun --all-namespaces \
            -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
            2>/dev/null)"}) } 2>/dev/null || true
        PR_MATCHES=(${(M)PR_ALL:#*run-deployer*})
        if [[ ${#PR_MATCHES[@]} -eq 0 || -z "${PR_MATCHES[1]:-}" ]]; then
            echo "[INFO] No itz-deployer PipelineRuns found."
        else
            for ENTRY in "${PR_MATCHES[@]}"; do
                [[ -z "${ENTRY:-}" ]] && continue
                PR_NS="${ENTRY%%/*}"
                PR_NAME="${ENTRY##*/}"
                echo "[DELETE] pipelinerun/${PR_NAME} (ns: ${PR_NS})"
                oc patch pipelinerun "${PR_NAME}" -n "${PR_NS}" \
                    --type='json' -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' \
                    2>/dev/null || true
                oc delete pipelinerun "${PR_NAME}" -n "${PR_NS}" \
                    --grace-period=0 --force --ignore-not-found 2>/dev/null || true
                (( PR_DELETED++ )) || true
            done
        fi
    fi

    if [[ "${TEKTON_TASKRUN_CRD_EXISTS}" == "true" ]]; then
        TR_ALL=()
        { TR_ALL=(${(f)"$(oc get taskrun --all-namespaces \
            -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
            2>/dev/null)"}) } 2>/dev/null || true
        TR_MATCHES=(${(M)TR_ALL:#*run-deployer*})
        if [[ ${#TR_MATCHES[@]} -eq 0 || -z "${TR_MATCHES[1]:-}" ]]; then
            echo "[INFO] No itz-deployer TaskRuns found."
        else
            for ENTRY in "${TR_MATCHES[@]}"; do
                [[ -z "${ENTRY:-}" ]] && continue
                TR_NS="${ENTRY%%/*}"
                TR_NAME="${ENTRY##*/}"
                echo "[DELETE] taskrun/${TR_NAME} (ns: ${TR_NS})"
                oc patch taskrun "${TR_NAME}" -n "${TR_NS}" \
                    --type='json' -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' \
                    2>/dev/null || true
                oc delete taskrun "${TR_NAME}" -n "${TR_NS}" \
                    --grace-period=0 --force --ignore-not-found 2>/dev/null || true
                (( TR_DELETED++ )) || true
            done
        fi
    fi

    echo "[INFO] Deleted ${PR_DELETED} PipelineRun(s) and ${TR_DELETED} TaskRun(s)."
fi

# ---------------------------------------------------------------------------
# Phase 5b: Delete archived Tekton Results records for itz-deployer runs
# These persist in the Results DB after the live PipelineRun is gone and
# show up as "fetched from Tekton Results" in the Pipelines UI.
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 5b: Delete archived Tekton Results records ==="

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

    if [[ ${#RECORD_NAMES[@]} -eq 0 || -z "${RECORD_NAMES[1]:-}" ]]; then
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
# Phase 6: Secrets created by the operator (webhook/metrics certs)
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 6: Delete operator-managed Secrets (all namespaces) ==="

for SECRET in "webhook-server-cert" "metrics-server-cert"; do
    SECRET_ALL=(${(f)"$(oc get secret --all-namespaces \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep "/${SECRET}$" || true)"})
    if [[ ${#SECRET_ALL[@]} -eq 0 || -z "${SECRET_ALL[1]:-}" ]]; then
        echo "[INFO] Secret ${SECRET} not found in any namespace."
    else
        for ENTRY in "${SECRET_ALL[@]}"; do
            [[ -z "${ENTRY:-}" ]] && continue
            S_NS="${ENTRY%%/*}"
            S_NAME="${ENTRY##*/}"
            echo "[DELETE] secret/${S_NAME} (ns: ${S_NS})"
            oc patch secret "${S_NAME}" -n "${S_NS}" \
                --type='json' -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' \
                2>/dev/null || true
            oc delete secret "${S_NAME}" -n "${S_NS}" \
                --grace-period=0 --force --ignore-not-found 2>/dev/null || true
        done
    fi
done

# ---------------------------------------------------------------------------
# Phase 7: CatalogSource
# Must be deleted FIRST - as long as a CatalogSource exists, OLM can resolve
# the Subscription and immediately recreate the CSV after it is deleted.
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 7: Delete CatalogSource ==="

# Match by name, displayName, or image - covers ibm-itz-deployer-operator-catalog and variants
CS_NAMES=(${(f)"$(oc get catalogsource --all-namespaces \
    -o json 2>/dev/null \
    | jq -r '.items[] | select(
        (.metadata.name | test("itz-deployer|ibm-itz-deployer|ibm-itz-deployer-operator-catalog"; "i"))
        or (.spec.displayName // "" | test("itz.deployer|ibm.technology.zone.deployer|technology.zone.deployer"; "i"))
        or (.spec.image // "" | test("itz-deployer"; "i"))
      ) | "\(.metadata.namespace)/\(.metadata.name)"' || true)"})
echo "[INFO] CatalogSources found matching itz-deployer: ${#CS_NAMES[@]}"

for ENTRY in "${CS_NAMES[@]}"; do
    [[ -z "${ENTRY:-}" ]] && continue
    CS_NS="${ENTRY%%/*}"
    CS="${ENTRY##*/}"
    echo "[DELETE] catalogsource/${CS} (ns: ${CS_NS})"
    oc delete catalogsource "${CS}" -n "${CS_NS}" --ignore-not-found 2>/dev/null || true
done

if [[ ${#CS_NAMES[@]} -eq 0 || -z "${CS_NAMES[1]:-}" ]]; then
    echo "[INFO] No itz-deployer CatalogSource found."
fi

# ---------------------------------------------------------------------------
# Phase 8: Subscription and its InstallPlans (all namespaces)
# Must be deleted before the CSV - OLM recreates the CSV from an active
# Subscription whenever it reconciles.
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 8: Delete Subscription and InstallPlans (all namespaces) ==="

# Match by resource name OR spec.name (package name) to catch any naming variant
SUB_ALL=(${(f)"$(oc get subscription --all-namespaces \
    -o json 2>/dev/null \
    | jq -r '.items[] | select(
        (.metadata.name | test("itz-deployer"; "i"))
        or (.spec.name // "" | test("itz-deployer"; "i"))
      ) | "\(.metadata.namespace)/\(.metadata.name)"' || true)"})
echo "[INFO] Subscriptions found matching itz-deployer: ${#SUB_ALL[@]}"

for ENTRY in "${SUB_ALL[@]}"; do
    [[ -z "${ENTRY:-}" ]] && continue
    SUB_NS="${ENTRY%%/*}"
    SUB="${ENTRY##*/}"
    # Collect InstallPlan names referenced by this subscription before deleting it
    IP_NAMES=(${(f)"$(oc get subscription "${SUB}" -n "${SUB_NS}" \
        -o jsonpath='{.status.installplan.name}' 2>/dev/null || true)"})
    # Remove ArgoCD tracking annotation before deleting
    oc annotate subscription "${SUB}" -n "${SUB_NS}" \
        "argocd.argoproj.io/tracking-id-" 2>/dev/null || true
    echo "[DELETE] subscription/${SUB} (ns: ${SUB_NS})"
    oc patch subscription "${SUB}" -n "${SUB_NS}" \
        --type='json' -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' \
        2>/dev/null || true
    oc delete subscription "${SUB}" -n "${SUB_NS}" \
        --grace-period=0 --force --ignore-not-found 2>/dev/null || true
    # Delete the referenced InstallPlan
    for IP in "${IP_NAMES[@]}"; do
        [[ -z "${IP:-}" ]] && continue
        echo "[DELETE] installplan/${IP} (ns: ${SUB_NS})"
        oc delete installplan "${IP}" -n "${SUB_NS}" --ignore-not-found 2>/dev/null || true
    done
done

# Also delete any InstallPlans in any namespace that reference the itz-deployer CSV directly
IP_ALL=(${(f)"$(oc get installplan --all-namespaces \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"})
for ENTRY in "${IP_ALL[@]}"; do
    [[ -z "${ENTRY:-}" ]] && continue
    IP_NS="${ENTRY%%/*}"
    IP="${ENTRY##*/}"
    REFERENCES_ITZ=$(oc get installplan "${IP}" -n "${IP_NS}" \
        -o jsonpath='{.spec.clusterServiceVersionNames}' 2>/dev/null \
        | grep -c "${ITZ_CSV_PATTERN}" || true)
    if [[ "${REFERENCES_ITZ}" -gt 0 ]]; then
        echo "[DELETE] installplan/${IP} (ns: ${IP_NS}, references itz-deployer CSV)"
        oc delete installplan "${IP}" -n "${IP_NS}" --ignore-not-found 2>/dev/null || true
    fi
done

if [[ ${#SUB_ALL[@]} -eq 0 || -z "${SUB_ALL[1]:-}" ]]; then
    echo "[INFO] No itz-deployer Subscriptions found in any namespace."
fi

# Also delete OperatorConditions OLM creates per-CSV (blocks CSV GC if present)
OC_ALL=(${(f)"$(oc get operatorcondition --all-namespaces \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep "${ITZ_CSV_PATTERN}" || true)"})
for ENTRY in "${OC_ALL[@]}"; do
    [[ -z "${ENTRY:-}" ]] && continue
    OC_NS="${ENTRY%%/*}"
    OC_NAME="${ENTRY##*/}"
    echo "[DELETE] operatorcondition/${OC_NAME} (ns: ${OC_NS})"
    oc patch operatorcondition "${OC_NAME}" -n "${OC_NS}" \
        --type='json' -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' \
        2>/dev/null || true
    oc delete operatorcondition "${OC_NAME}" -n "${OC_NS}" --ignore-not-found 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# Phase 8b: ClusterServiceVersion (CSV) - all namespaces
# OLM copies CSVs to every namespace when an operator is AllNamespaces-scoped.
# Delete after CatalogSource+Subscription are gone so OLM cannot recreate it.
# Wait up to 30s for Subscription to confirm gone before deleting CSV.
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 8b: Delete ClusterServiceVersion (all namespaces) ==="

# Helper: wipe alm-examples + finalizers then delete a CSV
_wipe_csv() {
    local csv_ns="$1" csv_name="$2"
    echo "[DELETE] csv/${csv_name} (ns: ${csv_ns})"
    # Clear alm-examples annotation unconditionally (prevents console from showing stale CRs)
    oc patch csv "${csv_name}" -n "${csv_ns}" \
        --type='json' \
        -p='[{"op":"replace","path":"/metadata/annotations/alm-examples","value":"[]"}]' \
        2>/dev/null || true
    # Strip OLM finalizer so the API server won't block the delete
    oc patch csv "${csv_name}" -n "${csv_ns}" \
        --type='json' -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' \
        2>/dev/null || true
    oc delete csv "${csv_name}" -n "${csv_ns}" \
        --grace-period=0 --force --ignore-not-found 2>/dev/null || true
}

# Wait for Subscription to be confirmed gone (OLM reconcile race protection)
echo "[INFO] Waiting for Subscription to be fully removed..."
for _i in 1 2 3 4 5 6; do
    REMAINING=$(oc get subscription --all-namespaces 2>/dev/null \
        | grep "${ITZ_CSV_PATTERN}" || true)
    [[ -z "${REMAINING}" ]] && break
    echo "[INFO] Subscription still present, waiting 5s..."
    sleep 5
done

CSV_ALL=(${(f)"$(oc get csv --all-namespaces \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep "${ITZ_CSV_PATTERN}" || true)"})

if [[ ${#CSV_ALL[@]} -eq 0 || -z "${CSV_ALL[1]:-}" ]]; then
    echo "[INFO] No itz-deployer CSVs found."
else
    for ENTRY in "${CSV_ALL[@]}"; do
        [[ -z "${ENTRY:-}" ]] && continue
        _wipe_csv "${ENTRY%%/*}" "${ENTRY##*/}"
    done
fi

# Wait up to 30s and verify CSV is actually gone, re-delete if it reappears
echo "[INFO] Verifying CSV removal..."
for _i in 1 2 3 4 5 6; do
    REMAINING=$(oc get csv --all-namespaces 2>/dev/null \
        | grep "${ITZ_CSV_PATTERN}" || true)
    [[ -z "${REMAINING}" ]] && break
    echo "[INFO] CSV still present, force-deleting again..."
    while IFS= read -r LINE; do
        [[ -z "${LINE}" ]] && continue
        _wipe_csv "$(echo "${LINE}" | awk '{print $1}')" "$(echo "${LINE}" | awk '{print $2}')"
    done <<< "${REMAINING}"
    sleep 5
done

# ---------------------------------------------------------------------------
# Phase 9: CRD itself
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 9: Delete CRD ==="

if oc get crd "${ITZ_CRD}" &>/dev/null; then
    _force_delete_cluster "crd" "${ITZ_CRD}"
else
    echo "[INFO] CRD ${ITZ_CRD} not present."
fi

# ---------------------------------------------------------------------------
# Phase 10: ClusterRoleBindings and ServiceAccount
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 10: Delete ClusterRoleBindings and ServiceAccount ==="

CRB_NAMES=(${(f)"$(oc get clusterrolebinding \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep "${ITZ_CSV_PATTERN}" || true)"})

for CRB in "${CRB_NAMES[@]}"; do
    [[ -z "${CRB:-}" ]] && continue
    _force_delete_cluster "clusterrolebinding" "${CRB}"
done

if [[ ${#CRB_NAMES[@]} -eq 0 || -z "${CRB_NAMES[1]:-}" ]]; then
    echo "[INFO] No itz-deployer ClusterRoleBindings found."
fi

SA_NAME="itz-deployer-operator-controller-manager"
SA_ALL=(${(f)"$(oc get serviceaccount --all-namespaces \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep "/${SA_NAME}$" || true)"})
if [[ ${#SA_ALL[@]} -eq 0 || -z "${SA_ALL[1]:-}" ]]; then
    echo "[INFO] ServiceAccount ${SA_NAME} not found in any namespace."
else
    for ENTRY in "${SA_ALL[@]}"; do
        [[ -z "${ENTRY:-}" ]] && continue
        SA_NS="${ENTRY%%/*}"
        echo "[DELETE] serviceaccount/${SA_NAME} (ns: ${SA_NS})"
        oc patch serviceaccount "${SA_NAME}" -n "${SA_NS}" \
            --type='json' -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' \
            2>/dev/null || true
        oc delete serviceaccount "${SA_NAME}" -n "${SA_NS}" \
            --grace-period=0 --force --ignore-not-found 2>/dev/null || true
    done
fi

# ---------------------------------------------------------------------------
# Phase 10b: Delete deployer status banner ConsoleNotifications
# These are cluster-scoped resources - the operator sets a finalizer
# (techzone.ibm.com/console-notification-cleanup) that blocks deletion when
# the operator is already gone.
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 10b: Delete deployer ConsoleNotifications ==="

CN_NAMES=(${(f)"$(oc get consolenotification \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep "deployer" || true)"})

if [[ ${#CN_NAMES[@]} -eq 0 || -z "${CN_NAMES[1]:-}" ]]; then
    echo "[INFO] No deployer ConsoleNotifications found."
else
    for CN in "${CN_NAMES[@]}"; do
        [[ -z "${CN:-}" ]] && continue
        _force_delete_cluster "consolenotification" "${CN}"
    done
fi

# ---------------------------------------------------------------------------
# Phase 11: Strip cpd-sa requester annotation and force-delete namespaces
# created by cloud-pak-deployer (identified by openshift.io/requester =
# system:serviceaccount:cloud-pak-deployer:cpd-sa), plus any namespace
# whose name contains "cloud-pak-deployer".
# The requester annotation itself does not block deletion, but the namespace
# may carry finalizers or terminating resources that do - strip those too.
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 11: Strip cpd-sa requester annotation and delete cloud-pak-deployer namespaces ==="

CPD_SA_REQUESTER="system:serviceaccount:cloud-pak-deployer:cpd-sa"

# Collect namespaces created by cpd-sa (requester annotation matches)
CPD_SA_NS_ALL=(${(f)"$(oc get namespace \
    -o json 2>/dev/null \
    | jq -r --arg req "${CPD_SA_REQUESTER}" \
        '.items[] | select(.metadata.annotations["openshift.io/requester"] == $req) | .metadata.name' \
    || true)"})

# Also collect namespaces whose name contains "cloud-pak-deployer"
CPD_NAME_NS_ALL=(${(f)"$(oc get namespace \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep "cloud-pak-deployer" || true)"})

# Merge both lists, deduplicate
typeset -A _SEEN_NS
CPD_NS_COMBINED=()
for _NS in "${CPD_SA_NS_ALL[@]}" "${CPD_NAME_NS_ALL[@]}"; do
    [[ -z "${_NS:-}" ]] && continue
    if [[ -z "${_SEEN_NS[${_NS}]:-}" ]]; then
        _SEEN_NS[${_NS}]=1
        CPD_NS_COMBINED+=("${_NS}")
    fi
done

if [[ ${#CPD_NS_COMBINED[@]} -eq 0 ]]; then
    echo "[INFO] No cloud-pak-deployer namespaces found."
else
    for CPD_NS in "${CPD_NS_COMBINED[@]}"; do
        [[ -z "${CPD_NS:-}" ]] && continue
        echo "[INFO] Processing namespace: ${CPD_NS}"

        # Strip the cpd-sa requester annotation so nothing re-adopts this namespace
        oc annotate namespace "${CPD_NS}" \
            "openshift.io/requester-" \
            2>/dev/null || true

        # Strip finalizers from all resources in the namespace to unblock termination
        for RESOURCE_KIND in $(oc api-resources --verbs=list --namespaced -o name 2>/dev/null); do
            ITEMS=(${(f)"$(oc get "${RESOURCE_KIND}" -n "${CPD_NS}" \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"})
            for ITEM in "${ITEMS[@]}"; do
                [[ -z "${ITEM:-}" ]] && continue
                oc patch "${RESOURCE_KIND}" "${ITEM}" -n "${CPD_NS}" \
                    --type='json' -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' \
                    2>/dev/null || true
            done
        done

        # Strip metadata.finalizers on the namespace object itself
        oc patch namespace "${CPD_NS}" \
            --type='json' -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' \
            2>/dev/null || true

        # Clear spec.finalizers via the /finalize subresource - this is the only way to
        # unblock a namespace already stuck in Terminating (oc patch on metadata.finalizers
        # does not touch spec.finalizers, which is what the namespace controller waits on).
        NS_JSON=$(oc get namespace "${CPD_NS}" -o json 2>/dev/null || true)
        if [[ -n "${NS_JSON}" ]]; then
            FINALIZE_BODY=$(echo "${NS_JSON}" | jq 'del(.spec.finalizers) | .spec.finalizers = []')
            oc replace --raw "/api/v1/namespaces/${CPD_NS}/finalize" \
                -f - <<< "${FINALIZE_BODY}" 2>/dev/null || true
        fi

        echo "[DELETE] namespace/${CPD_NS}"
        oc delete namespace "${CPD_NS}" \
            --grace-period=0 --force --ignore-not-found 2>/dev/null || true

        # Confirm gone - if still present after 10s, re-apply the finalize trick
        for _WAIT in 1 2; do
            sleep 5
            NS_PHASE=$(oc get namespace "${CPD_NS}" \
                -o jsonpath='{.status.phase}' 2>/dev/null || true)
            [[ -z "${NS_PHASE}" ]] && break
            echo "[INFO] namespace/${CPD_NS} still ${NS_PHASE}, re-clearing spec.finalizers..."
            NS_JSON=$(oc get namespace "${CPD_NS}" -o json 2>/dev/null || true)
            if [[ -n "${NS_JSON}" ]]; then
                FINALIZE_BODY=$(echo "${NS_JSON}" | jq 'del(.spec.finalizers) | .spec.finalizers = []')
                oc replace --raw "/api/v1/namespaces/${CPD_NS}/finalize" \
                    -f - <<< "${FINALIZE_BODY}" 2>/dev/null || true
            fi
        done
    done
fi

# ---------------------------------------------------------------------------
echo ""
echo "[DONE] itz-deployer-operator and dependents force-deleted."
