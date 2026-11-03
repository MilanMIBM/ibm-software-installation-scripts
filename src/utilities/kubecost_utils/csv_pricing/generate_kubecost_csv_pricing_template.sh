#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Writes a Kubecost CSV pricing template (Enterprise Custom Pricing, format v1)
# for the cluster, to fill in with your own prices and apply with
# apply_kubecost_csv_pricing.sh. Read-only on the cluster.
#
#   configs/kubecost_config/<namespace>/<instance>-pricing.csv
#       Version,AssetClass,InstanceType,Region,LabelName,LabelValue,Unit,PricePerUnit
#       One row (or one per unit) for each:
#       - node profile: nodes with the same role, cores, RAM, GPUs and architecture
#         share one profile (e.g. worker-32c-126gib-amd64) and one price. Matched
#         on the instance-type label when the profile's nodes all have the same
#         one (and no other profile uses it), else on the node label
#         kubecost.pricing/profile=<profile>, which the apply script sets.
#       - GPU product (nvidia.com/gpu.product)
#       - storage class (and __local__ for local volumes without one), per GB-hour
#       - load balancers (one price for all), when the cluster has any
#       PricePerUnit is left empty: fill it in.
#   configs/kubecost_config/<namespace>/<instance>-pricing-profiles.txt
#       what each row covers: nodes, cores, RAM, PV counts, and how to price it.
#
# Re-running keeps the prices already filled in for rows that still exist,
# adds rows for new profiles and drops rows that no longer match anything (the
# previous file is kept as <file>.<time>.bak).
#
# Node price units (--node-units):
#   split (default)  cpucorehour + ramgbhour rows per profile; Kubecost
#                    recommends these ('hour' prices can be off by 1-5%)
#   hour             one price per node-hour per profile
#
#   generate_kubecost_csv_pricing_template.sh <kubecost name> [options]
#     -n, --namespace <ns>         default: the namespace holding that Kubecost CR
#     --node-units split|hour
#     --reset                      start from scratch (drop prices already filled in)
#     -o, --output <file>          default configs/kubecost_config/<ns>/<instance>-pricing.csv
#     --server/--token/-u/-p       log in first (see ocu_login); otherwise OC_LOGIN
#                                  from cpd_vars.sh, else the current oc session
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"

usage() { sed -n '/^# Writes a Kubecost CSV/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

CR_NAME=""
NAMESPACE=""
NODE_UNITS="split"
RESET=false
OUTPUT=""
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)  NAMESPACE="${2:?$1 needs a value}"; shift 2 ;;
        --node-units)    NODE_UNITS="${2:?$1 needs a value}"; shift 2 ;;
        --reset)         RESET=true; shift ;;
        -o|--output)     OUTPUT="${2:?$1 needs a value}"; shift 2 ;;
        --server)        LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)         LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username)   LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password)   LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        -*)              echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)               [[ -z "${CR_NAME}" ]] || die "Unexpected argument: $1"; CR_NAME="$1"; shift ;;
    esac
done
[[ -n "${CR_NAME}" ]] || { usage >&2; die "Name the Kubecost instance (the Kubecost CR)."; }
[[ "${NODE_UNITS}" == (split|hour) ]] || die "--node-units must be split or hour."

ocu_login
[[ -n "${NAMESPACE}" ]] || NAMESPACE="$(kc_find_instance_namespace "${CR_NAME}")" || exit 1
oc get "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" &>/dev/null \
    || die "Kubecost instance '${CR_NAME}' not found in namespace '${NAMESPACE}'."
OUTPUT="${OUTPUT:-${KC_CONFIG_DIR}/${NAMESPACE}/${CR_NAME}-pricing.csv}"
PROFILES_FILE="${OUTPUT%.csv}-profiles.txt"
echo "[INFO] Kubecost instance: ${NAMESPACE}/${CR_NAME}"
CURRENCY="$(oc get "${KC_RESOURCE}" "${CR_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.kubecostProductConfigs.currencyCode}')"
CURRENCY="${CURRENCY:-USD}"

# --- Cluster inventory -----------------------------------------------------------
echo "[INFO] Reading nodes, storage classes, volumes and load balancers..."
NODES="$(kc_node_profiles)"
STORAGE="$(jq -cn --argjson sc "$(oc get storageclass -o json)" --argjson pv "$(oc get pv -o json)" '
    # Object bucket classes (.../obc) provision buckets, not volumes.
    ([$sc.items[] | select(.provisioner | endswith("/obc") | not) | .metadata.name]
     + [$pv.items[] | .spec.storageClassName // empty]) | unique as $classes
    | [$pv.items[] | if (.spec.storageClassName // "") == "" then "__local__" else .spec.storageClassName end] as $used
    | [($classes + (if ($used | index("__local__")) then ["__local__"] else [] end))[]
       | . as $c | {class: $c,
                    pvs: ([$used[] | select(. == $c)] | length),
                    gib: ([$pv.items[] | select((.spec.storageClassName // "__local__") == $c)
                           | .spec.capacity.storage // "0"
                           | if test("Ti$") then (rtrimstr("Ti") | tonumber * 1024)
                             elif test("Gi$") then (rtrimstr("Gi") | tonumber)
                             elif test("Mi$") then (rtrimstr("Mi") | tonumber / 1024)
                             else (tonumber? // 0) / 1073741824 end] | add // 0 | round)}]')"
LB_COUNT="$(oc get svc -A -o json | jq '[.items[] | select(.spec.type == "LoadBalancer")] | length')"

# --- Rows ------------------------------------------------------------------------
ROWS="$(jq -cn --argjson nodes "${NODES}" --argjson storage "${STORAGE}" --argjson lbs "${LB_COUNT}" \
    --arg units "${NODE_UNITS}" --arg label "${KC_PROFILE_LABEL}" '
    def row($cls; $it; $region; $ln; $lv; $unit; $covers):
        {cls: $cls, it: $it, region: $region, ln: $ln, lv: $lv, unit: $unit, covers: $covers};
    ($nodes | group_by(.profile)) as $groups
    # instance type -> number of profiles using it
    | ([$nodes[] | select(.instanceType != "") | {it: .instanceType, p: .profile}] | unique
       | group_by(.it) | map({key: .[0].it, value: length}) | from_entries) as $itProfiles
    | [ $groups[] | . as $g | $g[0].profile as $p
        | ([$g[].instanceType] | unique) as $its
        | ([$g[].region] | unique) as $regions
        | (if ($its | length) == 1 and $its[0] != "" and $itProfiles[$its[0]] == 1
           then {it: $its[0], region: (if ($regions | length) == 1 then $regions[0] else "" end), ln: "", lv: ""}
           else {it: "", region: "", ln: $label, lv: $p} end) as $m
        | (if $units == "hour" then ["hour"] else ["cpucorehour", "ramgbhour"] end)[]
        | row("node"; $m.it; $m.region; $m.ln; $m.lv; .; "\($g | length) node(s) of profile \($p)")
      ]
    + [ $nodes | map(select(.gpus > 0)) | group_by(.gpuProduct)[] | . as $g
        | if $g[0].gpuProduct != "" then
              row("gpu"; $g[0].gpuProduct; ""; ""; ""; "hour"; "\([$g[].gpus] | add) GPU(s) \($g[0].gpuProduct)")
          else
              ($g | group_by(.profile)[]
               | row("gpu"; ""; ""; $label; .[0].profile; "hour"; "\([.[].gpus] | add) GPU(s) without a product label, profile \(.[0].profile)"))
          end ]
    + [ $storage[] | row("volume"; .class; ""; ""; ""; "gbhour"; "\(.pvs) PV(s), \(.gib) GiB") ]
    + (if $lbs > 0 then [row("loadbalancer"; ""; ""; ""; ""; "hour"; "\($lbs) LoadBalancer service(s)")] else [] end)')"

# Prices already filled in, by row key (empty with --reset or no file).
OLD_PRICES='{}'
if [[ -f "${OUTPUT}" && "${RESET}" == false ]]; then
    OLD_PRICES="$(jq -R -s -c '
        [split("\n")[1:][] | select(length > 0) | split(",") | select(length >= 8)
         | {key: (.[1:7] | join("|")), value: .[7]}] | from_entries' "${OUTPUT}")"
fi

CSV="$(jq -r --argjson rows "${ROWS}" --argjson old "${OLD_PRICES}" -n '
    "Version,AssetClass,InstanceType,Region,LabelName,LabelValue,Unit,PricePerUnit",
    ($rows[] | [.cls, .it, .region, .ln, .lv, .unit] as $k
     | (["v1"] + $k + [$old[$k | join("|")] // ""]) | join(","))')"

kept="$(jq -n --argjson rows "${ROWS}" --argjson old "${OLD_PRICES}" \
    '[$rows[] | [.cls, .it, .region, .ln, .lv, .unit] | join("|") | $old[.] // "" | select(. != "")] | length')"
dropped="$(jq -r -n --argjson rows "${ROWS}" --argjson old "${OLD_PRICES}" \
    '([$rows[] | [.cls, .it, .region, .ln, .lv, .unit] | join("|")]) as $now
     | $old | keys[] | select(. as $k | $now | index($k) | not)')"

if [[ -f "${OUTPUT}" ]] && [[ "$(<"${OUTPUT}")" != "${CSV}" ]]; then
    backup="${OUTPUT}.$(date -u +%Y%m%dT%H%M%SZ).bak"
    cp -p "${OUTPUT}" "${backup}"
    echo "[INFO] Previous template kept as ${backup#${_CP4D_REPO_ROOT}/}"
fi
print -r -- "${CSV}" | _kc_write_private "${OUTPUT}"

# --- Profiles sheet --------------------------------------------------------------
{
    print -r -- "Kubecost CSV pricing template for ${CR_NAME} (${NAMESPACE}), cluster $(oc whoami --show-server)"
    print -r -- "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by ${SCRIPT_FILE:t}; prices go in ${OUTPUT:t}"
    print
    print -r -- "NODE PROFILES (nodes with the same role, cores, RAM, GPUs and architecture share a price)"
    jq -r --arg label "${KC_PROFILE_LABEL}" '
        group_by(.profile)[] | . as $g
        | "  \($g[0].profile)\n"
          + "    \($g | length) node(s), \($g[0].cores) cores, \($g[0].memGiB) GiB RAM, \($g[0].gpus) GPU(s), \($g[0].arch), role \($g[0].role)\n"
          + "    matched on: \(if ([$g[].instanceType] | unique | length) == 1 and $g[0].instanceType != ""
                             then "instance type \($g[0].instanceType) (if no other profile uses it)"
                             else "node label \($label)=\($g[0].profile) (set by apply_kubecost_csv_pricing.sh)" end)\n"
          + "    nodes: \([$g[].node] | join(", "))\n"' <<<"${NODES}"
    print -r -- "STORAGE (PricePerUnit per GB-hour)"
    jq -r '.[] | "  \(.class): \(.pvs) PV(s), \(.gib) GiB"' <<<"${STORAGE}"
    print -r -- "LOAD BALANCERS: ${LB_COUNT} (one price per hour each, if listed)"
    print
    print -r -- "HOW TO PRICE"
    if [[ "${NODE_UNITS}" == split ]]; then
        print -r -- "  Node rows: cpucorehour = price per core per hour, ramgbhour = price per GB of RAM per hour."
        print -r -- "  A node of a profile then costs  cores x cpucorehour + GiB x ramgbhour  per hour."
        jq -r --arg cur "${CURRENCY}" '"  e.g. to price a \(.cores)-core / \(.memGiB) GiB node at 1.00 \($cur)/hour with 70% of the cost on CPU:\n"
               + "       cpucorehour = 0.70 / \(.cores) = \(0.70 / .cores * 100000 | round / 100000),"
               + "  ramgbhour = 0.30 / \(.memGiB) = \(0.30 / .memGiB * 100000 | round / 100000)"' \
            <<<"$(jq -c 'map(select(.role == "worker")) | first // empty' <<<"${NODES}")" 2>/dev/null || true
    else
        print -r -- "  Node rows: price per node per hour."
    fi
    print -r -- "  Monthly to hourly: divide by 730. Prices are in ${CURRENCY} (the instance's currency; currency/set_kubecost_currency.sh"
    print -r -- "  changes it). Kubecost does not convert: enter prices in that currency."
    print -r -- "  Leave no PricePerUnit empty; rows you don't want to price can be deleted (those assets keep default pricing)."
} | _kc_write_private "${PROFILES_FILE}"

rows_total="$(jq length <<<"${ROWS}")"
echo "[OK] Template: ${OUTPUT#${_CP4D_REPO_ROOT}/} (${rows_total} rows, ${kept} with a price kept)"
echo "[OK] Profiles: ${PROFILES_FILE#${_CP4D_REPO_ROOT}/}"
jq -r 'group_by(.profile)[] | "       \(.[0].profile): \(length) node(s)"' <<<"${NODES}"
if [[ -n "${dropped}" ]]; then
    echo "[WARN] Rows dropped (no longer match the cluster):"
    print -r -- "${dropped}" | sed 's/^/         /; s/|/,/g'
fi
echo
echo "Fill in PricePerUnit, then apply: apply_kubecost_csv_pricing.sh ${CR_NAME}"
