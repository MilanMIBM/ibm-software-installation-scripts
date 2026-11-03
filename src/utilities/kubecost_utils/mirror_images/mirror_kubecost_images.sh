#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Mirrors the IBM Kubecost operator's images to a private registry, for
# private-registry and air-gapped installs (install_kubecost_operator.sh
# --source private|local). The image list comes from the Red Hat certified
# operator catalog the OpenShift operator is published in
# (registry.redhat.io/redhat/certified-operator-index:v<OCP>, package
# kubecost-operator): every image pinned by digest, as the operator uses them.
#
#   required  frontend, cost-model, finops-agent, cluster-controller
#   optional  network-costs, forecasting (modeling), mcp
#   operator  the operator manager and its bundle (always, unless --no-operator)
#
# Required and optional are both mirrored unless --images required,
# --exclude or KUBECOST_MIRROR_IMAGES / KUBECOST_MIRROR_EXCLUDE say otherwise.
# Images keep their digests and source path: <registry>/<path>/kubecost/<image>.
# Settings: configs/kubecost_config/kubecost_vars.sh when it exists, else
# cpd_vars.sh (PRIVATE_REGISTRY_LOCATION and push credentials).
#
# Phases:
#   list    show what would be mirrored where (default; changes nothing)
#   mirror  copy straight from Red Hat to the registry (workstation reaches both)
#   save    copy to a directory (air gap, outside): images + catalog/bundle data
#   load    copy that directory into the registry (air gap, inside)
#   verify  check that the registry holds every mirrored image
# mirror and load record the result in configs/kubecost_config/mirror/<version>/,
# which the install reads (destination images, bundle manifests).
#
#   mirror_kubecost_images.sh [--phase <phase>] [options]
#     --version <x.y.z>        operator version (default KUBECOST_OPERATOR_VERSION,
#                              else the channel's newest; load/verify: the newest mirrored)
#     --channel <name>         default KUBECOST_OPERATOR_CHANNEL, else the package default
#     --images all|required    default KUBECOST_MIRROR_IMAGES, else all
#     --exclude <c1,c2>        leave components out too (names as listed above)
#     --no-operator            leave the operator and bundle images out
#     --registry <location>    host[:port][/path]; default from the config
#     --dir <dir>              save/load directory (default KUBECOST_MIRROR_DIR,
#                              else kubecost_workspace/mirror/<version>)
#     --ocp-version <4.x>      catalog version (default KUBECOST_OCP_VERSION,
#                              else the logged-in cluster's)
#     --dry-run                mirror/save/load: show the copies, copy nothing
#     --server/--token/-u/-p   log in first (see ocu_login); the cluster is only
#                              used for its pull secret and version, so no login
#                              is needed with KUBECOST_REDHAT_PULL_SECRET_FILE
#                              and KUBECOST_OCP_VERSION set
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/${0:t}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/kubecost_install_helpers.sh"

usage() { sed -n '/^# Mirrors the IBM Kubecost operator/,/^#     -h, --help/p' "${SCRIPT_FILE}" | sed 's/^# \{0,1\}//'; }
die() { echo "[ERROR] $*" >&2; exit 1; }

PHASE="list"
VERSION=""
CHANNEL=""
IMAGES=""
EXCLUDE=""
NO_OPERATOR=false
REGISTRY_OPT=""
DIR=""
DRY_RUN=false
LOGIN_SERVER=""
LOGIN_TOKEN=""
LOGIN_USERNAME=""
LOGIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)         PHASE="${2:?$1 needs a value}"; shift 2 ;;
        --phase=*)       PHASE="${1#*=}"; shift ;;
        --version)       VERSION="${${2:?$1 needs a value}#v}"; shift 2 ;;
        --channel)       CHANNEL="${2:?$1 needs a value}"; shift 2 ;;
        --images)        IMAGES="${2:?$1 needs all or required}"; shift 2 ;;
        --exclude)       EXCLUDE="${2:?$1 needs component names}"; shift 2 ;;
        --no-operator)   NO_OPERATOR=true; shift ;;
        --registry)      REGISTRY_OPT="${2:?$1 needs host[:port][/path]}"; shift 2 ;;
        --dir)           DIR="${2:?$1 needs a directory}"; shift 2 ;;
        --ocp-version)   export KUBECOST_OCP_VERSION="${2:?$1 needs a version}"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --server)        LOGIN_SERVER="${2:?--server needs the API URL}"; shift 2 ;;
        --token)         LOGIN_TOKEN="${2:?--token needs a token}"; shift 2 ;;
        -u|--username)   LOGIN_USERNAME="${2:?--username needs a username}"; shift 2 ;;
        -p|--password)   LOGIN_PASSWORD="${2:?--password needs a password}"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done
[[ "${PHASE}" == (list|mirror|save|load|verify) ]] || die "--phase must be list, mirror, save, load or verify."

kc_install_settings
[[ -n "${REGISTRY_OPT}" ]] && KC_REGISTRY="${${REGISTRY_OPT#https://}%/}"
IMAGES="${IMAGES:-${KUBECOST_MIRROR_IMAGES:-all}}"
[[ "${IMAGES}" == (all|required) ]] || die "--images must be all or required (not '${IMAGES}')."
EXCLUDE_LIST=(${=${EXCLUDE//,/ }} ${=${KUBECOST_MIRROR_EXCLUDE:-}//,/ })
VALID_COMPONENTS=(${${(v)KC_IMAGE_CLASS}%% *})
for c in "${EXCLUDE_LIST[@]}"; do
    (( ${VALID_COMPONENTS[(Ie)${c}]} )) || die "--exclude: unknown component '${c}' ($(print -rl -- "${VALID_COMPONENTS[@]}" | grep -vx operator | sort | paste -sd, -))."
done
echo "[INFO] Settings: ${KC_VARS_FROM}; registry ${KC_REGISTRY:-none}${KC_REGISTRY:+ (images under $(kc_dest_root)/)}"
[[ "${PHASE}" == (mirror|load|verify) && -z "${KC_REGISTRY}" ]] \
    && die "No private registry: set KUBECOST_PRIVATE_REGISTRY_LOCATION (kubecost_vars.sh), PRIVATE_REGISTRY_LOCATION (cpd_vars.sh) or --registry."

# The cluster only gives the Red Hat pull secret and the OpenShift version.
if [[ "${PHASE}" != load && "${PHASE}" != verify ]]; then
    if [[ -n "${LOGIN_TOKEN}${LOGIN_USERNAME}" ]]; then
        ocu_login
    elif ! oc whoami &>/dev/null && [[ -n "${OC_LOGIN:-}" ]]; then
        eval "${OC_LOGIN}" >/dev/null 2>&1 || echo "[WARN] OC_LOGIN failed; going on without the cluster."
    fi
fi

WORK="$(mktemp -d "${${TMPDIR:-/tmp}%/}/kc-mirror.XXXXXX")"
chmod 700 "${WORK}"
trap 'rm -rf "${WORK}"' EXIT
AUTH="${WORK}/auth.json"
REG_FLAGS=($(kc_oc_registry_flags))

# Copies one image with progress; <i> <n> <label> <oc image mirror args...>
copy_image() {
    local i="$1" n="$2" label="$3"; shift 3
    printf '[%d/%d %3d%%] %s\n' "${i}" "${n}" $(( i * 100 / n )) "${label}"
    if [[ "${DRY_RUN}" == true ]]; then
        print -r -- "    oc image mirror ${*}"
        return 0
    fi
    local log="${WORK}/copy-${i}.log"
    if oc image mirror -a "${AUTH}" --keep-manifest-list=true "$@" >"${log}" 2>&1; then
        # oc's last lines: "<digest> <destination>" and "info: Mirroring completed in ..."
        grep -E '^info: Mirroring completed' "${log}" | sed 's/^info: /    /' || true
        return 0
    fi
    tail -10 "${log}" | sed 's/^/    /' >&2
    return 1
}

# --- Image table: from the catalog (list/mirror/save) or a saved record ------------
if [[ "${PHASE}" == (list|mirror|save) ]]; then
    kc_write_authfile "${AUTH}" "$([[ "${PHASE}" == mirror ]] && echo true || echo false)"
    TAG="$(kc_ocp_index_tag)" || exit 1
    INDEX="${KC_INDEX_REPO}:${TAG}"
    echo "[INFO] Reading ${KC_PACKAGE} from ${INDEX} (pull secret: ${KC_AUTH_SOURCE})..."
    mkdir -p "${WORK}/fbc"
    oc image extract "${INDEX}" -a "${AUTH}" --filter-by-os=linux/amd64 \
        --path "/configs/${KC_PACKAGE}/:${WORK}/fbc" --confirm >/dev/null 2>"${WORK}/extract.err" \
        || die "Could not read the catalog: $(tail -1 "${WORK}/extract.err")"
    [[ -f "${WORK}/fbc/catalog.json" ]] || die "No configs/${KC_PACKAGE}/catalog.json in ${INDEX}."
    jq -s '{package: (map(select(.schema == "olm.package"))[0] | del(.icon)),
            channels: [.[] | select(.schema == "olm.channel") | {name, entries: [.entries[].name]}],
            bundles: [.[] | select(.schema == "olm.bundle") | {name, image, relatedImages,
                       version: ([.properties[] | select(.type == "olm.package") | .value.version][0])}]}' \
        "${WORK}/fbc/catalog.json" > "${WORK}/package.json"
    CHANNEL="${CHANNEL:-${KUBECOST_OPERATOR_CHANNEL:-$(jq -r '.package.defaultChannel' "${WORK}/package.json")}}"
    jq -e --arg c "${CHANNEL}" '.channels[] | select(.name == $c)' "${WORK}/package.json" >/dev/null \
        || die "No channel '${CHANNEL}' (channels: $(jq -r '[.channels[].name] | join(", ")' "${WORK}/package.json"))."
    VERSION="${VERSION:-${KUBECOST_OPERATOR_VERSION:-}}"
    if [[ -z "${VERSION}" ]]; then
        CSV="$(jq -r --arg c "${CHANNEL}" '.channels[] | select(.name == $c) | .entries[]' "${WORK}/package.json" | kc_sort_csvs | head -1)"
    else
        CSV="kubecost-operator.v${VERSION}"
        jq -e --arg c "${CHANNEL}" --arg v "${CSV}" '.channels[] | select(.name == $c) | .entries | index($v)' "${WORK}/package.json" >/dev/null \
            || die "${CSV} is not in channel ${CHANNEL}: $(jq -r --arg c "${CHANNEL}" '.channels[] | select(.name == $c) | .entries[]' "${WORK}/package.json" | kc_sort_csvs | head -5 | tr '\n' ' ')..."
    fi
    BUNDLE="$(jq -c --arg v "${CSV}" '.bundles[] | select(.name == $v)' "${WORK}/package.json")"
    VERSION="$(jq -r '.version' <<<"${BUNDLE}")"
    echo "[INFO] ${CSV} (channel ${CHANNEL}, catalog ${TAG})"

    # name, component, class, source for each related image (the bundle has no name).
    TABLE="$(jq -c --arg b "$(jq -r '.image' <<<"${BUNDLE}")" '
        [.relatedImages[] | {name: (if .name == "" and .image == $b then "operator-bundle" else .name end), source: .image}]
        | unique_by(.source)' <<<"${BUNDLE}")"
    rows=()
    for row in ${(f)"$(jq -c '.[]' <<<"${TABLE}")"}; do
        name="$(jq -r '.name' <<<"${row}")"
        if [[ "${name}" == operator-bundle ]]; then
            cls=(bundle operator)
        elif [[ -n "${KC_IMAGE_CLASS[${name}]:-}" ]]; then
            cls=(${=KC_IMAGE_CLASS[${name}]})
        else
            cls=("${name}" required)
            echo "[WARN] Unknown image '${name}' in ${CSV}: treated as required."
        fi
        sel=true
        case "${cls[2]}" in
            operator) [[ "${NO_OPERATOR}" == true ]] && sel=false ;;
            optional) [[ "${IMAGES}" == all ]] || sel=false ;;
        esac
        (( ${EXCLUDE_LIST[(Ie)${cls[1]}]} )) && sel=false
        rows+=("$(jq -c --arg c "${cls[1]}" --arg k "${cls[2]}" --argjson s "${sel}" --arg t "${VERSION}" \
            '. + {component: $c, class: $k, selected: $s, digest: (.source | split("@")[1]), tag: $t}' <<<"${row}")")
    done
    TABLE="$(print -rl -- "${rows[@]}" | jq -s 'sort_by(({operator: 0, required: 1, optional: 2}[.class]), .component)')"
else
    # load / verify: a saved directory or the newest record.
    if [[ "${PHASE}" == load ]]; then
        if [[ -z "${DIR}" && -z "${KUBECOST_MIRROR_DIR:-}" ]]; then
            VERSION="${VERSION:-$(for d in "${KC_WORKSPACE}"/mirror/*/meta/record.json(N); do print -r -- "kubecost-operator.v${${d:h:h}:t}"; done | kc_sort_csvs | head -1 | sed 's/^kubecost-operator\.v//')}"
        fi
        SRC_DIR="${DIR:-${KUBECOST_MIRROR_DIR:-${KC_WORKSPACE}/mirror/${VERSION}}}"
        [[ -f "${SRC_DIR}/meta/record.json" ]] || die "No saved images at ${SRC_DIR} (meta/record.json). Run --phase save first and bring that directory over."
        REC="$(<"${SRC_DIR}/meta/record.json")"
    else
        VERSION="${VERSION:-${KUBECOST_OPERATOR_VERSION:-$(kc_latest_mirror_version)}}"
        [[ -n "${VERSION}" && -f "$(kc_mirror_meta "${VERSION}")/record.json" ]] \
            || die "No mirror record for ${VERSION:-any version} in configs/kubecost_config/mirror/. Run --phase mirror or load first."
        REC="$(<"$(kc_mirror_meta "${VERSION}")/record.json")"
    fi
    VERSION="$(jq -r '.version' <<<"${REC}")"; CSV="$(jq -r '.csv' <<<"${REC}")"; CHANNEL="$(jq -r '.channel' <<<"${REC}")"
    INDEX="$(jq -r '.index // ""' <<<"${REC}")"
    TABLE="$(jq -c '.images' <<<"${REC}")"
    kc_write_authfile "${AUTH}" "$([[ "${PHASE}" == load ]] && echo true || echo false)" 2>/dev/null
fi

# Destinations (registry known) and the plan.
DEST_ROOT="$(kc_dest_root)"
TABLE="$(jq -c --arg r "${DEST_ROOT}" 'map(. + {dest: (if $r == "" then "" else
        "\($r)/\(.source | split("@")[0] | split("/")[1:] | join("/"))" end)})' <<<"${TABLE}")"
echo
printf '  %-9s %-19s %-4s %s\n' CLASS COMPONENT COPY "SOURCE -> DESTINATION"
jq -r '.[] | [.class, .component, (if .selected then "yes" else "no" end), "\(.source | split("@")[0])@\(.digest[7:19])", (if .dest == "" then "-" else "\(.dest):\(.tag)" end)] | @tsv' <<<"${TABLE}" \
    | while IFS=$'\t' read -r k c s src dst; do printf '  %-9s %-19s %-4s %s\n  %-34s -> %s\n' "${k}" "${c}" "${s}" "${src}" "" "${dst}"; done
SELECTED="$(jq -c '[.[] | select(.selected)]' <<<"${TABLE}")"
N="$(jq 'length' <<<"${SELECTED}")"
SKIPPED="$(jq -r '[.[] | select(.selected | not) | .component] | join(", ")' <<<"${TABLE}")"
echo
echo "[INFO] ${N} image(s) to copy${SKIPPED:+; left out: ${SKIPPED}}."
if [[ "${PHASE}" == list ]]; then
    echo "Next: --phase mirror (registry reachable from here) or --phase save (air gap)."
    exit 0
fi
(( N > 0 )) || die "Nothing selected."

# --- Copy ------------------------------------------------------------------------------
record() {   # <file> <phase>: the record the install reads
    jq -n --arg p "${KC_PACKAGE}" --arg ch "${CHANNEL}" --arg v "${VERSION}" --arg csv "${CSV}" \
        --arg idx "${INDEX}" --arg reg "${KC_REGISTRY}" --arg path "${KC_REGISTRY_PATH}" \
        --arg root "${DEST_ROOT}" --arg ph "$2" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson img "${TABLE}" \
        '{package: $p, channel: $ch, version: $v, csv: $csv, index: $idx, registry: $reg, registryPath: $path,
          destRoot: $root, phase: $ph, at: $at, images: $img}' > "$1"
}
copy_meta() {   # <dest dir>: package data + bundle manifests
    mkdir -p "$1/bundle/manifests" "$1/bundle/metadata"
    cp "${WORK}/package.json" "$1/package.json"
    cp -R "${WORK}/bundle/." "$1/bundle/"
}
extract_bundle() {
    local b; b="$(jq -r '.[] | select(.component == "bundle") | .source' <<<"${TABLE}")"
    mkdir -p "${WORK}/bundle/manifests" "${WORK}/bundle/metadata"
    echo "[INFO] Reading the bundle manifests from ${b%@*}..."
    oc image extract "${b}" -a "${AUTH}" --filter-by-os=linux/amd64 \
        --path "/manifests/:${WORK}/bundle/manifests" --path "/metadata/:${WORK}/bundle/metadata" --confirm >/dev/null 2>"${WORK}/bundle.err" \
        || die "Could not read the bundle: $(tail -1 "${WORK}/bundle.err")"
}

i=0
case "${PHASE}" in
    mirror)
        extract_bundle
        for row in ${(f)"$(jq -c '.[]' <<<"${SELECTED}")"}; do
            (( ++i ))
            src="$(jq -r '.source' <<<"${row}")"; dst="$(jq -r '"\(.dest):\(.tag)"' <<<"${row}")"
            copy_image "${i}" "${N}" "$(jq -r '.component' <<<"${row}") -> ${dst}" "${REG_FLAGS[@]}" "${src}=${dst}" \
                || die "Mirroring ${src} failed."
        done
        [[ "${DRY_RUN}" == true ]] && exit 0
        META="$(kc_mirror_meta "${VERSION}")"
        (umask 077; mkdir -p "${META}")
        copy_meta "${META}"
        record "${META}/record.json" mirror
        echo "[OK] ${N} image(s) in ${DEST_ROOT}; record: ${META#${_CP4D_REPO_ROOT}/}/record.json"
        echo "Next: install_kubecost_operator.sh --source private"
        ;;
    save)
        OUT="${DIR:-${KUBECOST_MIRROR_DIR:-${KC_WORKSPACE}/mirror/${VERSION}}}"
        extract_bundle
        mkdir -p "${OUT}/images"
        for row in ${(f)"$(jq -c '.[]' <<<"${SELECTED}")"}; do
            (( ++i ))
            src="$(jq -r '.source' <<<"${row}")"
            dst="file://kubecost/$(jq -r '"\(.source | split("@")[0] | split("/")[1:] | join("/")):\(.tag)"' <<<"${row}")"
            copy_image "${i}" "${N}" "$(jq -r '.component' <<<"${row}") -> ${dst}" --dir="${OUT}/images" "${src}=${dst}" \
                || die "Saving ${src} failed."
        done
        [[ "${DRY_RUN}" == true ]] && exit 0
        copy_meta "${OUT}/meta"
        record "${OUT}/meta/record.json" save
        echo "[OK] ${N} image(s) saved to ${OUT} ($(du -sh "${OUT}" | cut -f1))."
        echo "Next: carry ${OUT} into the air-gapped network, then: ${SCRIPT_FILE:t} --phase load --dir <copied dir>"
        ;;
    load)
        for row in ${(f)"$(jq -c '.[]' <<<"${SELECTED}")"}; do
            (( ++i ))
            src="file://kubecost/$(jq -r '"\(.source | split("@")[0] | split("/")[1:] | join("/")):\(.tag)"' <<<"${row}")"
            dst="$(jq -r '"\(.dest):\(.tag)"' <<<"${row}")"
            copy_image "${i}" "${N}" "$(jq -r '.component' <<<"${row}") -> ${dst}" "${REG_FLAGS[@]}" --from-dir="${SRC_DIR}/images" "${src}=${dst}" \
                || die "Loading ${src} failed."
        done
        [[ "${DRY_RUN}" == true ]] && exit 0
        META="$(kc_mirror_meta "${VERSION}")"
        (umask 077; mkdir -p "${META}")
        mkdir -p "${WORK}/bundle"
        cp "${SRC_DIR}/meta/package.json" "${WORK}/package.json"; cp -R "${SRC_DIR}/meta/bundle/." "${WORK}/bundle/"
        copy_meta "${META}"
        record "${META}/record.json" load
        echo "[OK] ${N} image(s) loaded into ${DEST_ROOT}; record: ${META#${_CP4D_REPO_ROOT}/}/record.json"
        echo "Next: install_kubecost_operator.sh --source local"
        ;;
    verify)
        bad=0
        for row in ${(f)"$(jq -c '.[]' <<<"${SELECTED}")"}; do
            (( ++i ))
            ref="$(jq -r '"\(.dest)@\(.digest)"' <<<"${row}")"
            if oc image info -a "${AUTH}" "${REG_FLAGS[@]}" --filter-by-os=linux/amd64 "${ref}" >/dev/null 2>&1; then
                printf '[%d/%d %3d%%] OK       %s\n' "${i}" "${N}" $(( i * 100 / N )) "${ref}"
            else
                printf '[%d/%d %3d%%] MISSING  %s\n' "${i}" "${N}" $(( i * 100 / N )) "${ref}"; (( ++bad ))
            fi
        done
        (( bad == 0 )) || die "${bad} image(s) missing from ${DEST_ROOT}."
        echo "[OK] All ${N} image(s) are in ${DEST_ROOT}."
        ;;
esac
