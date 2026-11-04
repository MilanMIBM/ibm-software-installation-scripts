#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Applies a Kubecost CSV pricing file (Enterprise Custom Pricing) to an
# instance: checks the CSV, labels the nodes the CSV matches by resource
# profile (kubecost.pricing/profile), stores the CSV in ConfigMap
# <instance>-enterprise-pricing and turns enterpriseCustomPricing on in the
# Kubecost CR. Make the file with generate_kubecost_csv_pricing_template.sh.
#
# CSV pricing is an Enterprise feature: per the Kubecost docs, turning it on
# without a valid product key locks the application. Without a product key
# linked to the instance (product_key/link_kubecost_product_key.sh) this script stops,
# unless --force.
#
# Re-run it after editing prices or adding nodes: new nodes get their profile
# label (regenerate the template first if they bring a new profile).
#
#   apply_kubecost_csv_pricing.sh [<kubecost name>] [options]
#     -n, --namespace <ns>          default: the namespace holding that Kubecost CR
#   No name: KUBECOST_INSTANCE_NAME from configs/kubecost_config/kubecost_vars.sh,
#   else the only instance on the cluster (asks which one when there are several)
#     -f, --file <csv>              default configs/kubecost_config/<ns>/<instance>-pricing.csv
#     --no-retroactive              apply prices from now on only (default: also to history)
#     --disable                     turn CSV pricing off, delete the ConfigMap and the node labels
#     --force                       apply even without a linked product key
#     --dry-run                     check the CSV and show what would change
#     --no-wait                     don't wait for the operator to roll it out
#     --timeout <seconds>           wait at most this long (default 600)
#     --server/--token/-u/-p        log in first (see ocu_login); otherwise OC_LOGIN
#                                   from cpd_vars.sh, else the current oc session
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"

usage() { sed -n '/^# Applies a Kubecost CSV/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

CR_NAME=""
NAMESPACE=""
CSV_FILE=""
RETROACTIVE=true
DISABLE=false
FORCE=false
DRY_RUN=false
WAIT=true
TIMEOUT=600
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)    NAMESPACE="${2:?$1 needs a value}"; shift 2 ;;
        -f|--file)         CSV_FILE="${2:?$1 needs a value}"; shift 2 ;;
        --no-retroactive)  RETROACTIVE=false; shift ;;
        --disable)         DISABLE=true; shift ;;
        --force)           FORCE=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --no-wait)         WAIT=false; shift ;;
        --timeout)         TIMEOUT="${2:?$1 needs a value}"; shift 2 ;;
        --server)          LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)           LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username)     LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password)     LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        -*)                echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)                 [[ -z "${CR_NAME}" ]] || die "Unexpected argument: $1"; CR_NAME="$1"; shift ;;
    esac
done
[[ "${TIMEOUT}" == <-> ]] || die "--timeout needs a number of seconds."

ocu_login
kc_resolve_instance || exit 1
CR_JSON="$(oc get "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" -o json 2>/dev/null)" \
    || die "Kubecost instance '${CR_NAME}' not found in namespace '${NAMESPACE}'."
echo "[INFO] Kubecost instance: ${NAMESPACE}/${CR_NAME}"

CONFIGMAP="${CR_NAME}-enterprise-pricing"
CSV_KEY="pricing.csv"
MOUNT_URI="/var/configs/enterprise-pricing/${CSV_KEY}"   # the chart mounts the ConfigMap there
AGGREGATOR="statefulset/${CR_NAME}-aggregator"
CURRENT_ECP="$(jq -c '.spec.enterpriseCustomPricing // {}' <<<"${CR_JSON}")"
if [[ "${DISABLE}" != true ]] && jq -e '.enabled == true and (.configMapName // "") == "" and (.location.URI // "") == ""' <<<"${CURRENT_ECP}" >/dev/null; then
    echo "[INFO] CSV pricing is managed in the UI now; this hands it back to Helm (the CSV uploaded in the UI is no longer used)."
fi

# Applies the CR patch when it changes something, then waits; when only the
# ConfigMap changed, restarts the aggregator so it reads the new CSV.
apply_and_wait() {   # <patch json> <configmap changed: true|false>
    local patch="$1" cm_changed="$2" desired start_rev start_ts
    desired="$(jq -c --argjson cur "${CURRENT_ECP}" '$cur * .spec.enterpriseCustomPricing' <<<"${patch}")"
    if [[ "${desired}" != "${CURRENT_ECP}" ]]; then
        start_rev="$(kc_release_revision "${CR_NAME}" "${NAMESPACE}")"
        start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        oc patch "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" --type merge -p "${patch}" >/dev/null
        echo "[OK] Kubecost CR updated: enterpriseCustomPricing $(jq -c . <<<"${desired}")"
        [[ "${WAIT}" == true ]] || return 0
        kc_wait_for_release "${CR_NAME}" "${NAMESPACE}" "${start_rev}" "${start_ts}" "${TIMEOUT}" || exit 1
    elif [[ "${cm_changed}" == true ]]; then
        oc rollout restart "${AGGREGATOR}" -n "${NAMESPACE}" >/dev/null
        echo "[OK] CR unchanged; restarted ${AGGREGATOR} to load the new CSV."
        [[ "${WAIT}" == true ]] || return 0
    else
        echo "[OK] Nothing to change."
        return 0
    fi
    echo "[INFO] Waiting for ${AGGREGATOR} (up to ${TIMEOUT}s)..."
    oc rollout status "${AGGREGATOR}" -n "${NAMESPACE}" --timeout="${TIMEOUT}s" 2>&1 | sed 's/^/  /' \
        || die "${AGGREGATOR} did not become ready."
}

# --- Disable -------------------------------------------------------------------
if [[ "${DISABLE}" == true ]]; then
    PATCH='{"spec":{"enterpriseCustomPricing":{"enabled":false,"configMapName":"","location":{"URI":""}}}}'
    labelled="$(oc get nodes -l "${KC_PROFILE_LABEL}" -o name | wc -l | tr -d ' ')"
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[DRY-RUN] Would turn CSV pricing off, delete ConfigMap ${CONFIGMAP} and remove ${KC_PROFILE_LABEL} from ${labelled} node(s)."
        exit 0
    fi
    apply_and_wait "${PATCH}" false
    oc delete configmap "${CONFIGMAP}" -n "${NAMESPACE}" --ignore-not-found >/dev/null
    oc label nodes -l "${KC_PROFILE_LABEL}" "${KC_PROFILE_LABEL}-" >/dev/null 2>&1 || true
    echo "[OK] CSV pricing off; ConfigMap removed; label removed from ${labelled} node(s)."
    kc_save_instance_details "${CR_NAME}" "${NAMESPACE}" false >/dev/null
    exit 0
fi

# --- CSV -----------------------------------------------------------------------
CSV_FILE="${CSV_FILE:-${KC_CONFIG_DIR}/${NAMESPACE}/${CR_NAME}-pricing.csv}"
[[ -r "${CSV_FILE}" ]] || die "No CSV at ${CSV_FILE#${_CP4D_REPO_ROOT}/}. Make one with generate_kubecost_csv_pricing_template.sh ${CR_NAME}."
echo "[INFO] CSV: ${CSV_FILE#${_CP4D_REPO_ROOT}/}"

# Same rules as Kubecost's parser (docs + UI validation), reported per line.
CHECK="$(jq -R -s -c '
    def v1: ["Version","AssetClass","InstanceType","Region","LabelName","LabelValue","Unit","PricePerUnit"];
    def v2: v1[:6] + ["SecondaryLabelName","SecondaryLabelValue","TertiaryLabelName","TertiaryLabelValue","Unit","PricePerUnit"];
    def units: {node: ["hour","cpucorehour","ramgbhour"], gpu: ["hour"], volume: ["gbhour"], loadbalancer: ["hour"]};
    (split("\n") | map(sub("\r$"; "")) | to_entries | map(select(.value | test("\\S")))) as $lines
    | ($lines[0].value | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $hdr
    | (if $hdr == v1 then "v1" elif $hdr == v2 then "v2" else null end) as $ver
    | if $ver == null then {errors: ["line 1: header must be \(v1 | join(","))"], rows: []}
      else
        [ $lines[1:][] | (.key + 1) as $n | (.value | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $f
          | if (.value | test("\"")) then {n: $n, err: "quoted fields are not supported"}
            elif ($f | length) != ($hdr | length) then {n: $n, err: "\($f | length) fields, expected \($hdr | length)"}
            else ([$hdr, $f] | transpose | map({key: .[0], value: .[1]}) | from_entries) as $r
            | {n: $n, r: $r, err: (
                if $r.Version != $ver then "Version \($r.Version | tojson) (the header is \($ver); rows cannot mix versions)"
                elif (units[$r.AssetClass] == null) then "AssetClass \($r.AssetClass | tojson): use node, gpu, volume or loadbalancer"
                elif (units[$r.AssetClass] | index($r.Unit)) == null then "Unit \($r.Unit | tojson) is not valid for \($r.AssetClass) (\(units[$r.AssetClass] | join(", ")))"
                elif $r.PricePerUnit == "" then "PricePerUnit is empty"
                elif ($r.PricePerUnit | test("^[0-9]+(\\.[0-9]+)?$") | not) then "PricePerUnit \($r.PricePerUnit | tojson) is not a number"
                elif $r.LabelValue != "" and $r.LabelName == "" then "label value present without name"
                elif $r.AssetClass == "loadbalancer" and ([$r.InstanceType, $r.Region, $r.LabelName] | any(. != "")) then "loadbalancer rows take no InstanceType, Region or label"
                else null end)} end ]
        | {version: $ver,
           errors: [.[] | select(.err != null) | "line \(.n): \(.err)"],
           rows: [.[] | select(.err == null) | .r]}
        | .errors += ([.rows[] | [.AssetClass, .InstanceType, .Region, .LabelName, .LabelValue, .Unit] | join(",")]
                      | group_by(.) | map(select(length > 1) | "duplicate row: \(.[0])"))
      end' "${CSV_FILE}")"
errors=("${(@f)$(jq -r '.errors[]' <<<"${CHECK}")}"); errors=(${errors:#})
if (( ${#errors[@]} > 0 )); then
    echo "[ERROR] The CSV has ${#errors[@]} problem(s):" >&2
    printf '  %s\n' "${errors[@]}" >&2
    exit 1
fi
ROWS="$(jq -c '.rows' <<<"${CHECK}")"
(( $(jq length <<<"${ROWS}") > 0 )) || die "The CSV has no rows."
echo "[OK] CSV valid: $(jq -r 'group_by(.AssetClass) | map("\(length) \(.[0].AssetClass)") | join(", ")' <<<"${ROWS}") row(s)"

# --- Product key ---------------------------------------------------------------
kc_product_key_status "${CR_JSON}" "${NAMESPACE}"
if [[ "${KC_KEY_LINKED}" != true ]]; then
    echo "[WARN] CSV pricing (Enterprise Custom Pricing) is a Kubecost Enterprise feature, and no product key is"
    echo "[WARN] linked to '${CR_NAME}' (${KC_KEY_SOURCE}). Per the Kubecost docs, enabling it without a valid"
    echo "[WARN] key locks the application. Link one first: product_key/link_kubecost_product_key.sh ${CR_NAME} -k <key>"
    [[ "${FORCE}" == true ]] || die "Stopped. --force applies it anyway."
    echo "[WARN] --force: applying anyway."
else
    echo "[INFO] Product key: ${KC_KEY_SOURCE}"
fi

# --- Coverage and node labels --------------------------------------------------
NODES="$(kc_node_profiles)"
COVERAGE="$(jq -c -n --argjson nodes "${NODES}" --argjson rows "${ROWS}" --arg label "${KC_PROFILE_LABEL}" '
    [$rows[] | select(.AssetClass == "node")] as $nr
    | [$nr[] | select(.LabelName == $label) | .LabelValue] as $labelled
    | [$nodes[] | . as $n
       | {node: .node, profile: .profile, current: .currentProfile,
          by_label: ($labelled | index($n.profile) != null),
          by_type: ([$nr[] | select(.InstanceType != "" and .InstanceType == $n.instanceType
                                    and (.Region == "" or .Region == $n.region))] | length > 0),
          by_other_label: ([$nr[] | select(.LabelName != "" and .LabelName != $label)] | length > 0)}]')"
uncovered="$(jq -r '[.[] | select((.by_label or .by_type or .by_other_label) | not) | "\(.node) (\(.profile))"] | join(", ")' <<<"${COVERAGE}")"
[[ -z "${uncovered}" ]] || echo "[WARN] Nodes no node row matches (they keep default pricing; regenerate the template?): ${uncovered}"
unused="$(jq -r -n --argjson nodes "${NODES}" --argjson rows "${ROWS}" --arg label "${KC_PROFILE_LABEL}" '
    [$rows[] | select(.AssetClass == "node" and .LabelName == $label) | .LabelValue] | unique
    | map(select(. as $p | [$nodes[].profile] | index($p) | not)) | join(", ")')"
[[ -z "${unused}" ]] || echo "[WARN] Profiles in the CSV that no node has now: ${unused}"

# Nodes to label: those whose profile is priced by label and whose label is not set to it yet.
TO_LABEL=("${(@f)$(jq -r '.[] | select(.by_label and .current != .profile) | "\(.node)\t\(.profile)"' <<<"${COVERAGE}")}")
TO_LABEL=(${TO_LABEL:#})

# --- ConfigMap -------------------------------------------------------------------
current_csv="$(oc get configmap "${CONFIGMAP}" -n "${NAMESPACE}" -o json 2>/dev/null | jq -r --arg k "${CSV_KEY}" '.data[$k] // empty' || true)"
CM_CHANGED=false
[[ "${current_csv}" == "$(<"${CSV_FILE}")" ]] || CM_CHANGED=true

PATCH="$(jq -cn --arg cm "${CONFIGMAP}" --arg uri "${MOUNT_URI}" --argjson retro "${RETROACTIVE}" \
    '{spec: {enterpriseCustomPricing: {enabled: true, configMapName: $cm, location: {URI: $uri}, applyRetroactively: $retro}}}')"

if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY-RUN] Would label ${#TO_LABEL[@]} node(s) with ${KC_PROFILE_LABEL}:"
    printf '            %s\n' "${TO_LABEL[@]//$'\t'/ -> }"
    echo "[DRY-RUN] ConfigMap ${CONFIGMAP}: $([[ "${CM_CHANGED}" == true ]] && echo "would be written" || echo "unchanged")"
    echo "[DRY-RUN] Would merge-patch ${KC_RESOURCE}/${CR_NAME}: $(jq -c . <<<"${PATCH}")"
    exit 0
fi

if (( ${#TO_LABEL[@]} > 0 )); then
    i=0
    for entry in "${TO_LABEL[@]}"; do
        (( ++i ))
        oc label node "${entry%%$'\t'*}" "${KC_PROFILE_LABEL}=${entry#*$'\t'}" --overwrite >/dev/null
        print -r -- "  [${i}/${#TO_LABEL[@]} $(( i * 100 / ${#TO_LABEL[@]} ))%] ${entry%%$'\t'*} -> ${entry#*$'\t'}"
    done
    echo "[OK] Labelled ${#TO_LABEL[@]} node(s) with ${KC_PROFILE_LABEL}."
fi

if [[ "${CM_CHANGED}" == true ]]; then
    oc create configmap "${CONFIGMAP}" -n "${NAMESPACE}" --from-file="${CSV_KEY}=${CSV_FILE}" --dry-run=client -o json \
        | jq '.metadata.labels["kubecost-pricing/managed"] = "true"' | oc apply -f - >/dev/null
    echo "[OK] ConfigMap ${CONFIGMAP} written."
fi

apply_and_wait "${PATCH}" "${CM_CHANGED}"

if [[ "${WAIT}" == true ]]; then
    # Best effort: what the aggregator said about the pricing spec since it started.
    log="$(oc logs "${AGGREGATOR#statefulset/}-0" -n "${NAMESPACE}" -c aggregator 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' | grep -i -E 'pricing|csv' | tail -5 || true)"
    [[ -z "${log}" ]] || { echo "[INFO] Aggregator log (pricing):"; print -r -- "${log}" | cut -c1-220 | sed 's/^/  /'; }
fi

kc_save_instance_details "${CR_NAME}" "${NAMESPACE}" false >/dev/null
echo "[OK] CSV pricing applied to '${CR_NAME}'. Check it in the UI under Settings > Enterprise Custom Pricing."
