#!/bin/zsh
# =============================================================================
# confluent_operator_helpers.sh - the Confluent operator install mode (CFK and
# cp-fko through OLM, CRs rendered from confluent_cfk_render.py)
# -----------------------------------------------------------------------------
# How scripts use it (operator/ scripts, after the env_bootstrap line):
#
#     source "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_helpers.sh"
#     cfo_entry platform          # checks, oc login, scripts-mode guard
#
# Loads common_helpers.sh, confluent_helpers.sh, operator_install_helpers.sh
# and version_resolver.sh. Prefixes: cfo_ = operator mechanics, cf_ = endpoint
# resolvers with operator-mode semantics (never called in scripts mode).
#
# The decisions live in Python, so they are testable from fixtures:
#   confluent_operator_config.py  settings, checks, operator targets
#   confluent_operator_olm.py     OLM / Helm JSON (detect, gates, InstallPlans)
# The functions here collect `oc ... -o json` into a private temp dir and call
# them. Binding spec: .claude/plans/confluent-operator-install-mode/
# implementation-contract.md (sections 2, 3.2, 9).
#
# Rules kept everywhere:
#   - every wait prints progress ([<elapsed>s/<timeout>s] or [i/N]); elapsed
#     time is counted per poll, so a wait cannot spin when `sleep` is a fake;
#   - a failed `oc apply` ends the step at once (no wait afterwards);
#   - DRY_RUN=true reads the cluster but writes nothing;
#   - secret values move only through 0600 files or stdin, never argv/stdout.
#
# Private helpers other scripts call (stable: names, arguments and results do
# not change; the underscore only says "not part of contract 3.2"):
#   _cfo_read <oc args...>         oc stdout; empty when absent; status 1 + [ERROR] on any other failure
#   _cfo_json <file> <oc args...>  oc ... -o json into <file> (empty list when absent); status 1 on other failures
#   _cfo_mktemp                    a new 0700 temp dir on stdout (the caller removes it)
#   _cfo_int <value> <default>     REPLY = <value> when it is a number, else <default>
#   _cfo_owner                     REPLY = the ownership label value (CFO_OWNER_ID, else cfo_owner_id)
#   _cfo_vars_file                 REPLY = the confluent_vars.sh in use
#   _cfo_pkg_settings <pkg>        _CFO_P_* (name, catalog, channel, CSV, approval, ...) of one OLM package
#   _cfo_config_py <args...>       confluent_operator_config.py (no config export; see _cfo_config)
#   _cfo_external_hosts <domain>   REPLY = the external listener SAN host names (comma-joined) for the broker count
#   _cfo_render_root               REPLY = the rendered-file root of this run (platform or Flink add-on)
#
# Notes:
#   - Must be SOURCED, not executed. Guarded via _CFO_HELPERS_LOADED.
# =============================================================================

[[ -n "${_CFO_HELPERS_LOADED:-}" ]] && return 0
_CFO_HELPERS_LOADED=1

_CFO_DIR="${${(%):-%x}:A:h}"
: "${_CP4D_REPO_ROOT:=${_CFO_DIR:h:h}}"

source "${_CFO_DIR}/common_helpers.sh"
source "${_CFO_DIR}/confluent_helpers.sh"
source "${_CP4D_REPO_ROOT}/scripts/operator_install_helpers.sh"
source "${_CFO_DIR}/version_resolver.sh"

# -----------------------------------------------------------------------------
# Constants (contract 3.2, 2.6, 9.1, 9.2)
# -----------------------------------------------------------------------------
CF_PLATFORM_DIR="${_CP4D_REPO_ROOT}/scripts/install_confluent_platform"
CF_FLINK_DIR="${CF_PLATFORM_DIR}/install_confluent_platform_flink_addon"
CF_RENDER_ROOT="${MCM_CLUSTER_ROOT:-${CF_PLATFORM_DIR}}/confluent_platform_vars/rendered"
CF_FLINK_RENDER_ROOT="${MCM_CLUSTER_ROOT:-${CF_FLINK_DIR}}/flink_vars/rendered"

CF_KAFKA_CR=kafka
CF_KRAFT_CR=kraftcontroller
CF_SR_CR=schema-registry
CF_CONNECT_CR=connect
CF_KSQLDB_CR=ksqldb-server
CF_KRP_CR=rest-proxy
CF_C3_CR=control-center
CF_RESTCLASS_CR=default

CFO_PKG_CFK=confluent-for-kubernetes
CFO_PKG_FKO=cp-fko

CFO_LABEL_PART_OF="app.kubernetes.io/part-of=confluent"
CFO_LABEL_OWNER_KEY="confluent.ibm-scripts/installed-by"
CFO_LABEL_MODE="confluent.ibm-scripts/deploy-mode=operator"
CFO_LABEL_DERIVED_KEY="confluent.ibm-scripts/derived-from"
CFO_LABEL_WIPED="confluent.ibm-scripts/wiped-from=scripts-mode"
# PVs kept by a KEEP_DATA delete (plan 15.14 item 1). Label value <ns>.<cr> (a label value cannot hold "/");
# the annotation of the same key carries the exact "<ns>/<cr>".
CFO_LABEL_RETAINED_KEY="confluent.ibm-scripts/retained-from"
CFO_ANNOT_BLOCK_RECONCILE="platform.confluent.io/block-reconcile"

CFO_RC_OK=0
CFO_RC_ERROR=1
CFO_RC_BLOCKED=2
# (exit code 4 "data kept, stopped" is gone: KEEP_DATA now retains the PVs and x.0 completes, plan 15.14 item 1)

: "${CFO_SASL_SERVER_SECRET:=confluent-sasl-cfk-server}"
: "${CFO_SASL_CLIENT_SECRET:=confluent-sasl-cfk-client}"
: "${CFO_LICENSE_SECRET:=confluent-license}"
: "${CFO_CA_PAIR_SECRET:=ca-pair-sslcerts}"
: "${CFO_MARKER_CM:=confluent-ibm-scripts-deploy-mode}"
: "${CFO_FRONT_PROXY:=control-center-auth}"
: "${CONFLUENT_CONNECT_STATE_FILE:=${CONFLUENT_CONFIG_DIR:-${_CP4D_REPO_ROOT}/configs/confluent_platform_config}/confluent_connect_state.json}"
# MDS (phase 5; key names unverified, V5)
: "${CFO_MDS_TOKEN_SECRET:=confluent-mds-cfk-token}"
: "${CFO_MDS_LDAP_SECRET:=confluent-ldap-cfk-bind}"
: "${CFO_MDS_CLIENT_SECRET:=confluent-mds-cfk-client}"

CFO_STATEFUL_KINDS=(Kafka KRaftController KsqlDB ControlCenter)

# Seconds between polls of every wait (tests lower it; the fake sleep returns at once anyway).
: "${CFO_POLL_INTERVAL:=10}"
[[ "${CFO_POLL_INTERVAL}" == <-> ]] && (( CFO_POLL_INTERVAL > 0 )) || CFO_POLL_INTERVAL=10

typeset -ga CFO_SUMMARY_ROWS CFO_RETAINED_PVS
CFO_SUMMARY_ROWS=()
CFO_RETAINED_PVS=()

# =============================================================================
# Small internals
# =============================================================================
# cfo_python <args...> - the repo venv's python (PyYAML, jinja2), isolated (-I).
cfo_python() {
    if [[ -x "${_CP4D_REPO_ROOT}/.venv/bin/python" ]]; then
        "${_CP4D_REPO_ROOT}/.venv/bin/python" -I "$@"
    else
        python3 -I "$@"
    fi
}

_cfo_config_py() { cfo_python "${_CFO_DIR}/confluent_operator_config.py" "$@"; }
_cfo_olm_py()    { cfo_python "${_CFO_DIR}/confluent_operator_olm.py" "$@"; }

# _cfo_with_vars <names-command> -- <command...> - runs <command> in a subshell
# where every variable named by <names-command> that is set is exported (config
# values set with `: ${X:=...}` are not exported by the scripts).
_cfo_with_vars() {
    local -a names=()
    while (( $# )) && [[ "$1" != -- ]]; do names+=("$1"); shift; done
    [[ "${1:-}" == -- ]] && shift
    (
        local _n
        for _n in "${names[@]}"; do
            [[ -n "${(P)_n+x}" ]] && export "${_n}"
        done
        "$@"
    )
}

# Names confluent_operator_config.py may read (cached).
_cfo_config_names() {
    if [[ -z "${_CFO_CONFIG_NAMES:-}" ]]; then
        _CFO_CONFIG_NAMES="$(_cfo_config_py list-vars)" || return 1
    fi
    REPLY="${_CFO_CONFIG_NAMES}"
}

# _cfo_config <args...> - confluent_operator_config.py with the config exported.
_cfo_config() {
    _cfo_config_names || return 1
    _cfo_with_vars ${(f)REPLY} -- _cfo_config_py "$@"
}

# _cfo_mktemp - a new 0700 temp dir (callers remove it in an `always` block).
_cfo_mktemp() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/cfo.XXXXXX")" || return 1
    chmod 700 "${d}"
    print -r -- "${d}"
}

# _cfo_json <file> <oc args...> - `oc <args> -o json` into <file>; an empty
# list when the read fails. Status 1 (and the oc error on stderr) when the read
# failed for any reason but "absent" (NotFound, no such resource type): callers
# whose decision would install or delete something on an empty answer (detect,
# the version gate, the CRD check) stop on it; status / listing callers add
# `|| true` and live with the empty list.
_cfo_json() {
    local file="$1"; shift
    local err rc=0 errtext
    err="$(mktemp "${TMPDIR:-/tmp}/cfo-err.XXXXXX")" || return 1
    oc "$@" -o json > "${file}" 2>"${err}" || rc=$?
    errtext="$(<"${err}")"
    rm -f "${err}"
    if (( rc != 0 )); then
        print -r -- '{"items":[]}' > "${file}"
        if ! _cfo_not_found "${errtext}"; then
            print -r -- "[ERROR] oc $* failed: ${errtext:-exit ${rc}}" >&2
            return 1
        fi
    fi
    [[ -s "${file}" ]] || print -r -- '{"items":[]}' > "${file}"
    return 0
}

# _cfo_not_found <stderr text> - status 0 when an oc error only says the object
# or its kind is absent.
_cfo_not_found() {
    [[ "$1" == *NotFound* || "$1" == *"not found"* || "$1" == *"doesn't have a resource type"* ]]
}

# _cfo_read <oc args...> - `oc <args>` stdout; empty (status 0) when the object or its kind is absent;
# status 1 with an [ERROR] line on any other failure (Forbidden, no connection, ...). For reads whose
# empty answer would let a caller delete something (fail closed, like _cfo_json).
_cfo_read() {
    local err rc=0 out errtext
    err="$(mktemp "${TMPDIR:-/tmp}/cfo-err.XXXXXX")" || return 1
    out="$(oc "$@" 2>"${err}")" || rc=$?
    errtext="$(<"${err}")"
    rm -f "${err}"
    if (( rc != 0 )); then
        _cfo_not_found "${errtext}" && return 0
        print -r -- "[ERROR] oc $* failed: ${errtext:-exit ${rc}}" >&2
        return 1
    fi
    [[ -n "${out}" ]] && print -r -- "${out}"
    return 0
}

_cfo_owner() { REPLY="${CFO_OWNER_ID:-$(cfo_owner_id)}"; }

# The rendered-file root of this run: Flink-only runs keep theirs with the Flink add-on.
_cfo_render_root() {
    if [[ "${CFO_SCOPE:-}" == flink ]]; then REPLY="${CF_FLINK_RENDER_ROOT}"; else REPLY="${CF_RENDER_ROOT}"; fi
}

_cfo_vars_file() {
    REPLY="${ENV_TARGET_FILE:-${CONFLUENT_CONFIG_DIR:-${_CP4D_REPO_ROOT}/configs/confluent_platform_config}/confluent_vars.sh}"
}

# _cfo_int <value> <default> - REPLY = the value when it is a number, else the default.
_cfo_int() { if [[ "${1:-}" == <-> ]]; then REPLY="$1"; else REPLY="$2"; fi; }

# _cfo_choice <value> <default> <allowed...> - REPLY = canonical value (case-insensitive), else <default>.
# Silent: cfo_check_config already warned about an invalid value at entry.
_cfo_choice() {
    _cf_trim "${1:-}"
    local v="${REPLY}" def="$2" a
    shift 2
    REPLY="${def}"
    [[ -z "${v}" ]] && return 0
    for a in "$@"; do
        [[ "${(L)v}" == "${(L)a}" ]] && { REPLY="${a}"; return 0; }
    done
    return 0
}

# cfo_resource <Kind> - the fully qualified resource name of a CFK kind.
cfo_resource() {
    case "$1" in
        Kafka)                print -r -- kafkas.platform.confluent.io ;;
        KRaftController)      print -r -- kraftcontrollers.platform.confluent.io ;;
        SchemaRegistry)       print -r -- schemaregistries.platform.confluent.io ;;
        Connect)              print -r -- connects.platform.confluent.io ;;
        KsqlDB)               print -r -- ksqldbs.platform.confluent.io ;;
        KafkaRestProxy)       print -r -- kafkarestproxies.platform.confluent.io ;;
        ControlCenter)        print -r -- controlcenters.platform.confluent.io ;;
        KafkaTopic)           print -r -- kafkatopics.platform.confluent.io ;;
        Connector)            print -r -- connectors.platform.confluent.io ;;
        KafkaRestClass)       print -r -- kafkarestclasses.platform.confluent.io ;;
        ConfluentRolebinding) print -r -- confluentrolebindings.platform.confluent.io ;;
        ClusterLink)          print -r -- clusterlinks.platform.confluent.io ;;
        SchemaExporter)       print -r -- schemaexporters.platform.confluent.io ;;
        Schema)               print -r -- schemas.platform.confluent.io ;;
        USMAgent)             print -r -- usmagents.platform.confluent.io ;;
        CMFRestClass)         print -r -- cmfrestclasses.platform.confluent.io ;;
        FlinkEnvironment)     print -r -- flinkenvironments.platform.confluent.io ;;
        FlinkApplication)     print -r -- flinkapplications.platform.confluent.io ;;
        *)                    print -r -- "${(L)1}" ;;
    esac
}

# =============================================================================
# Config, mode, entry
# =============================================================================
# cfo_catalog <path> <fallback> - a version_catalog.json value, else <fallback>.
cfo_catalog() {
    local v
    v="$(vr_catalog "$1" 2>/dev/null)" || v=""
    [[ -n "${v}" ]] && print -r -- "${v}" || print -r -- "$2"
}

# cfo_owner_id - the ownership label value: <cluster>.<platform namespace>.
cfo_owner_id() {
    local id="${MCM_CLUSTER:-local}.${PROJECT_CONFLUENT_SERVER:-}"
    id="${id//[^A-Za-z0-9._-]/-}"
    id="${id[1,63]}"
    while [[ -n "${id}" && "${id[1]}" != [A-Za-z0-9] ]]; do id="${id[2,-1]}"; done
    while [[ -n "${id}" && "${id[-1]}" != [A-Za-z0-9] ]]; do id="${id[1,-2]}"; done
    print -r -- "${id}"
}

# cfo_check_config <platform|flink|all> - the static operator-mode checks
# (confluent_operator_config.py check). Status 1 when any error.
cfo_check_config() {
    local scope="${1:-all}" lic=false out line errors=0
    [[ -n "${CONFLUENT_LICENSE_KEY:-}" ]] && lic=true
    out="$(_cfo_config check --scope "${scope}" --license-present "${lic}" --format text)" || {
        print -r -- "[ERROR] confluent_operator_config.py check failed." >&2
        return 1
    }
    for line in "${(@f)out}"; do
        [[ -z "${line}" ]] && continue
        case "${line}" in
            "[ERROR] "*) print -r -- "${line}" >&2; (( errors += 1 )) ;;
            "[WARN] CONFLUENT_DEPLOY_MODE="*)
                # cf_resolve_deploy_mode warns once per process tree already
                [[ -n "${_CF_DEPLOY_MODE_WARNED:-}" ]] || print -r -- "${line}" >&2 ;;
            "[WARN] FLINK_OPERATOR_SOURCE="*)
                [[ -n "${_CF_FLINK_SOURCE_WARNED:-}" ]] || print -r -- "${line}" >&2 ;;
            "[WARN] FLINK_CMF_RESOURCE_MODE="*)
                [[ -n "${_CF_FLINK_CMF_WARNED:-}" ]] || print -r -- "${line}" >&2 ;;
            "[WARN] No CONFLUENT_LICENSE_KEY"*)
                # Only when the platform namespace has no license secret either. cfo_entry runs this
                # before its oc login, so it defers the secret check until after the login.
                if [[ -n "${_CFO_LICENSE_DEFER:-}" ]]; then
                    _CFO_LICENSE_PENDING=1
                else
                    _cfo_license_warning_unless_secret
                fi ;;
            "[WARN] "*)  print -r -- "${line}" >&2 ;;
            *)           print -r -- "${line}" ;;
        esac
    done
    (( errors == 0 ))
}

# cfo_license_warning - the 30-day-trial warning, printed once per process tree (cfo_check_config and
# cfo_ensure_license_secret both reach it; plan item 14). Summary lines that want to repeat the fact should
# test CFO_LICENSE_PRESENT instead of calling this again.
cfo_license_warning() {
    [[ -n "${_CFO_LICENSE_WARNED:-}" ]] && return 0
    export _CFO_LICENSE_WARNED=1
    print -r -- "[WARN] No CONFLUENT_LICENSE_KEY - Confluent Platform runs on the 30-day trial license." >&2
}

# _cfo_license_warning_unless_secret - cfo_license_warning when there is no CONFLUENT_LICENSE_KEY and no
# ${CFO_LICENSE_SECRET} secret in the platform namespace (read-only; an unreadable secret counts as absent).
_cfo_license_warning_unless_secret() {
    [[ -n "${CONFLUENT_LICENSE_KEY:-}" ]] && return 0
    if [[ -n "${PROJECT_CONFLUENT_SERVER:-}" ]] \
        && oc get secret "${CFO_LICENSE_SECRET}" -n "${PROJECT_CONFLUENT_SERVER}" -o name >/dev/null 2>&1; then
        return 0
    fi
    cfo_license_warning
}

# cfo_plan_targets [platform|flink|all] - "<ns> <pkg> [<pkg>]" lines (contract 3.3).
cfo_plan_targets() {
    _cfo_config plan --scope "${1:-all}"
}

# cfo_operator_source - olm | existing for CFK; status 1 on helm / invalid.
cfo_operator_source() {
    # K8S-EXTENSION(K1): return helm when CONFLUENT_CLUSTER_PLATFORM=kubernetes (no OLM there); existing still works.
    _cf_trim "${CONFLUENT_OPERATOR_SOURCE:-}"
    local v="${(L)REPLY}"
    case "${v}" in
        ""|olm)   print -r -- olm ;;
        existing) print -r -- existing ;;
        helm)     print -r -- "[ERROR] CONFLUENT_OPERATOR_SOURCE=helm is reserved for Kubernetes mode (v1: olm|existing)" >&2
                  return 1 ;;
        *)        print -r -- "[ERROR] CONFLUENT_OPERATOR_SOURCE='${REPLY}' is not olm|existing" >&2
                  return 1 ;;
    esac
}

# cfo_approval <platform|flink> - Manual | Automatic.
cfo_approval() {
    if [[ "${1:-platform}" == flink ]]; then
        _cfo_choice "${FLINK_OLM_INSTALL_PLAN_APPROVAL:-}" Manual Manual Automatic
    else
        _cfo_choice "${CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL:-}" Manual Manual Automatic
    fi
    print -r -- "${REPLY}"
}

# cfo_tls_source - repo | cfk (--tls-source on the CLI wins over the config).
cfo_tls_source() {
    _cfo_choice "${CONFLUENT_OPERATOR_TLS_SOURCE_CLI:-${CONFLUENT_OPERATOR_TLS_SOURCE:-}}" repo repo cfk
    print -r -- "${REPLY}"
}

cfo_sasl_impl() {
    _cfo_choice "${CONFLUENT_OPERATOR_SASL_IMPL:-}" plain plain scram
    print -r -- "${REPLY}"
}

cfo_connector_management() {
    _cfo_choice "${CONFLUENT_CONNECTOR_MANAGEMENT:-}" rest rest cr
    print -r -- "${REPLY}"
}

# cfo_entry <platform|flink|all> [--no-login] [--no-guard] - the top of every
# operator-mode entry point: static checks (exit 1), login, scripts-mode guard
# (exit 2). Exports CFO_OWNER_ID and CFO_SCOPE.
cfo_entry() {
    local scope="${1:-}" login=true guard=true
    [[ "${scope}" == (platform|flink|all) ]] || { print -r -- "[ERROR] cfo_entry: scope must be platform, flink or all" >&2; exit 1; }
    shift
    while (( $# )); do
        case "$1" in
            --no-login) login=false ;;
            --no-guard) guard=false ;;
            *) print -r -- "[ERROR] cfo_entry: unknown option '$1'" >&2; exit 1 ;;
        esac
        shift
    done
    export CFO_SCOPE="${scope}"
    _CFO_LICENSE_PENDING=""
    _CFO_LICENSE_DEFER=1
    cfo_check_config "${scope}" || { unset _CFO_LICENSE_DEFER; exit 1; }
    unset _CFO_LICENSE_DEFER
    if ${login}; then
        if [[ -z "${OC_LOGIN:-}" ]]; then
            print -r -- "[ERROR] OC_LOGIN is not set - check the cluster login in your config." >&2
            exit 1
        fi
        eval "${OC_LOGIN}"
    fi
    # The trial-license warning cfo_check_config deferred: now on the logged-in cluster.
    if [[ -n "${_CFO_LICENSE_PENDING}" ]]; then
        _CFO_LICENSE_PENDING=""
        _cfo_license_warning_unless_secret
    fi
    export CFO_OWNER_ID="$(cfo_owner_id)"
    if ${guard}; then
        local rc=0
        cfo_guard_scripts_install "${scope}" || rc=$?
        (( rc == 0 )) || exit "${rc}"
    fi
    return 0
}

# cfo_route_domain - CONFLUENT_ROUTE_DOMAIN, else the cluster's apps domain.
cfo_route_domain() {
    if [[ -n "${CONFLUENT_ROUTE_DOMAIN:-}" ]]; then
        print -r -- "${CONFLUENT_ROUTE_DOMAIN}"
    else
        oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true
    fi
}

# =============================================================================
# Banner and guard
# =============================================================================
# cfo_banner <title> <line>... - "[BLOCKED] <title>" and each line indented by
# 10 spaces, on stderr; also appended to CFO_BANNER_FILE when set.
cfo_banner() {
    local title="$1" l text
    shift
    text="[BLOCKED] ${title}"
    for l in "$@"; do text+=$'\n'"          ${l}"; done
    print -r -- "${text}" >&2
    [[ -n "${CFO_BANNER_FILE:-}" ]] && print -r -- "${text}" >> "${CFO_BANNER_FILE}"
    return 0
}

# cfo_banner_replay - repeats every banner of this run (the full installers' EXIT trap).
cfo_banner_replay() {
    [[ -n "${CFO_BANNER_FILE:-}" && -s "${CFO_BANNER_FILE}" ]] || return 0
    {
        print -r -- ""
        print -r -- "[BLOCKED] summary - repeated from above:"
        cat "${CFO_BANNER_FILE}"
    } >&2
    return 0
}

# The <mode> word of the guard banner.
_cfo_mode_word() {
    _cf_trim "${CONFLUENT_DEPLOY_MODE:-}"
    case "${(L)REPLY}" in
        "")       REPLY=unset ;;
        operator) REPLY=operator ;;
        *)        REPLY="invalid ('${REPLY}')" ;;
    esac
}

# Scripts-mode objects in the platform namespace (contract 8 D15): the broker
# StatefulSet and the named scripts-mode Deployments. Prints what it finds;
# status 1 when the namespace cannot be read.
_cfo_scripts_platform_objects() {
    local ns="$1" out err rc=0
    err="$(mktemp "${TMPDIR:-/tmp}/cfo-err.XXXXXX")"
    out="$(oc get statefulset/broker deployment/schema-registry deployment/connect deployment/ksqldb-server \
        deployment/rest-proxy deployment/control-center deployment/prometheus deployment/alertmanager \
        -n "${ns}" -o name --ignore-not-found 2>"${err}")" || rc=$?
    local errtext="$(<"${err}")"
    rm -f "${err}"
    if (( rc != 0 )) && ! _cfo_not_found "${errtext}"; then
        print -r -- "[ERROR] Cannot read namespace ${ns} to check for a scripts-mode install: ${errtext}" >&2
        return 1
    fi
    print -r -- "${out}"
}

# cfo_guard_scripts_install <platform|flink|all> - read-only: blocks (status 2)
# when the target namespace holds a scripts-mode install. Cannot be skipped.
cfo_guard_scripts_install() {
    local scope="${1:-platform}" blocked=0 found repo="${_CP4D_REPO_ROOT}"
    local x8="${repo}/scripts/install_confluent_platform/utility_scripts_confluent_platform/x.8_confluent_wipe_scripts_mode.sh"
    _cfo_vars_file; local vars_file="${REPLY}"
    _cfo_mode_word; local mode="${REPLY}"

    if [[ "${scope}" == (platform|all) ]] && cf_is_operator_mode; then
        local ns="${PROJECT_CONFLUENT_SERVER:-}"
        if [[ -n "${ns}" ]]; then
            found="$(_cfo_scripts_platform_objects "${ns}")" || return 1
            if [[ -n "${found}" ]]; then
                cfo_banner "Namespace ${ns} holds a scripts-mode Confluent install." \
                    "CONFLUENT_DEPLOY_MODE is ${mode}, which means operator mode." \
                    "Choose one:" \
                    "  1. Keep it: set CONFLUENT_DEPLOY_MODE=\"scripts\" in ${vars_file}" \
                    "  2. Replace it: run ${x8}" \
                    "     (add --keep-data to keep the PVCs), then re-run this script."
                blocked=1
            fi
        fi
    fi

    if [[ "${scope}" == (flink|all) ]] && cf_flink_is_olm && cf_flink_configured; then
        local fns="${PROJECT_CONFLUENT_FLINK}" tmp hits marker
        tmp="$(_cfo_mktemp)" || return 1
        {
            # Fail closed like the platform check: an unreadable namespace is not an empty one.
            if ! command -v helm >/dev/null 2>&1; then
                print -r -- "[ERROR] helm is not on PATH - cannot check ${fns} for a scripts-mode Flink install (the Flink add-on needs helm for CMF anyway)." >&2
                return 1
            fi
            if ! helm list -n "${fns}" -o json > "${tmp}/helm.json" 2>/dev/null; then
                print -r -- "[ERROR] Cannot list the Helm releases in ${fns} to check for a scripts-mode Flink install." >&2
                return 1
            fi
            [[ -s "${tmp}/helm.json" ]] || print -r -- '[]' > "${tmp}/helm.json"
            hits="$(_cfo_olm_py guard-flink --helm "${tmp}/helm.json")" || hits=""
            marker="$(oc get configmap "${CFO_MARKER_CM}" -n "${fns}" -o name --ignore-not-found 2>/dev/null || true)"
            local hit is_scripts=false
            for hit in "${(@f)hits}"; do
                [[ -z "${hit}" ]] && continue
                case "${hit%% *}" in
                    fko) is_scripts=true ;;
                    cmf) [[ -z "${marker}" ]] && is_scripts=true ;;
                esac
            done
            if ${is_scripts}; then
                local flink_line="CONFLUENT_DEPLOY_MODE is ${mode}, which means operator mode."
                local keep="CONFLUENT_DEPLOY_MODE=\"scripts\""
                if [[ -n "${FLINK_OPERATOR_SOURCE:-}" ]]; then
                    flink_line="FLINK_OPERATOR_SOURCE is ${FLINK_OPERATOR_SOURCE}, which means the OLM cp-fko operator."
                    keep="FLINK_OPERATOR_SOURCE=\"helm\""
                fi
                cfo_banner "Namespace ${fns} holds a scripts-mode Confluent Flink install." \
                    "${flink_line}" \
                    "Choose one:" \
                    "  1. Keep it: set ${keep} in ${vars_file}" \
                    "  2. Replace it: run ${x8} --include-flink" \
                    "     (add --keep-data to keep the PVCs), then re-run this script."
                blocked=1
            fi
        } always {
            rm -rf "${tmp}"
        }
    fi
    (( blocked == 0 )) && return 0
    return "${CFO_RC_BLOCKED}"
}

# cfo_marker_set <ns> - the ConfigMap that tells the guard a Flink CMF release is ours (contract 8 D19).
cfo_marker_set() {
    local ns="$1"
    _cfo_owner; local owner="${REPLY}"
    if [[ "${DRY_RUN:-false}" == true ]]; then
        print -r -- "  [DRY-RUN] oc apply ConfigMap ${CFO_MARKER_CM} -n ${ns} (mode: operator, owner: ${owner})"
        return 0
    fi
    oc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CFO_MARKER_CM}
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: confluent
    confluent.ibm-scripts/installed-by: "${owner}"
    confluent.ibm-scripts/deploy-mode: operator
data:
  mode: operator
  owner: "${owner}"
YAML
}

# =============================================================================
# OLM detect / install
# =============================================================================
# Per-package settings: REPLY-style globals _CFO_P_* for <canonical package>.
_cfo_pkg_settings() {
    local pkg="$1"
    if [[ "${pkg}" == "${CFO_PKG_CFK}" ]]; then
        _CFO_P_NAME="${CONFLUENT_OPERATOR_PACKAGE:-${CFO_PKG_CFK}}"
        _CFO_P_SUB="${CONFLUENT_OPERATOR_SUBSCRIPTION_NAME:-confluent-for-kubernetes}"
        _CFO_P_CHANNEL="${CONFLUENT_OPERATOR_CHANNEL:-$(cfo_catalog confluent/operator/cfk_channel 3.4)}"
        if [[ -n "${CONFLUENT_OPERATOR_STARTING_CSV+x}" ]]; then
            _CFO_P_CSV="${CONFLUENT_OPERATOR_STARTING_CSV}"
        else
            _CFO_P_CSV="$(cfo_catalog confluent/operator/cfk_csv confluent-for-kubernetes.v3.4.0)"
        fi
        _CFO_P_CATALOG="${CONFLUENT_OPERATOR_CATALOG_SOURCE:-certified-operators}"
        _CFO_P_CATALOG_NS="${CONFLUENT_OPERATOR_CATALOG_SOURCE_NAMESPACE:-openshift-marketplace}"
        _CFO_P_APPROVAL="$(cfo_approval platform)"
        _CFO_P_DEPLOY=confluent-operator
        _CFO_P_CHANNEL_VAR=CONFLUENT_OPERATOR_CHANNEL
        _CFO_P_CSV_VAR=CONFLUENT_OPERATOR_STARTING_CSV
    else
        local fko="" derived_channel="" derived_csv=""
        if [[ -n "${FLINK_CMF_CHART_VERSION:-}" ]]; then
            fko="$(_cfo_config_py fko-for-cmf "${FLINK_CMF_CHART_VERSION}" 2>/dev/null)" || fko=""
        fi
        derived_channel="${fko%% *}"
        derived_csv="${fko#* }"
        [[ -n "${fko}" ]] || { derived_channel="$(cfo_catalog confluent/operator/fko_channel stable-v1.16)"; derived_csv="$(cfo_catalog confluent/operator/fko_csv cp-fko.v1.16.1-cp1)"; }
        _CFO_P_NAME="${FLINK_OLM_PACKAGE:-${CFO_PKG_FKO}}"
        _CFO_P_SUB="${FLINK_OLM_SUBSCRIPTION_NAME:-cp-fko}"
        _CFO_P_CHANNEL="${FLINK_OLM_CHANNEL:-${derived_channel}}"
        if [[ -n "${FLINK_OLM_STARTING_CSV+x}" ]]; then
            _CFO_P_CSV="${FLINK_OLM_STARTING_CSV}"
        else
            _CFO_P_CSV="${derived_csv}"
        fi
        _CFO_P_CATALOG="${FLINK_OLM_CATALOG_SOURCE:-certified-operators}"
        _CFO_P_CATALOG_NS="${FLINK_OLM_CATALOG_SOURCE_NAMESPACE:-openshift-marketplace}"
        _CFO_P_APPROVAL="$(cfo_approval flink)"
        _CFO_P_DEPLOY=cp-fko
        _CFO_P_CHANNEL_VAR=FLINK_OLM_CHANNEL
        _CFO_P_CSV_VAR=FLINK_OLM_STARTING_CSV
    fi
}

# cfo_detect <package> <ns> - what runs <package> for <ns>. Call without $(...):
# sets CFO_RESULT (none|reuse|conflict), CFO_NS, CFO_CSV, CFO_VERSION,
# CFO_CHANNEL, CFO_SUB, CFO_OWNED, CFO_REASON (and CFO_PHASE, CFO_OTHERS);
# prints one human line.
cfo_detect() {
    # K8S-EXTENSION(K3): in Kubernetes mode the `helm list -A` scan below becomes the primary CFK detection (no OLM).
    local pkg="$1" ns="$2" tmp out
    _cfo_owner; local owner="${REPLY}"
    CFO_RESULT=none CFO_NS="" CFO_CSV="" CFO_VERSION="" CFO_CHANNEL="" CFO_SUB="" CFO_OWNED=false CFO_REASON="" \
        CFO_PHASE="" CFO_OTHERS=""
    tmp="$(_cfo_mktemp)" || return 1
    {
        # A failed read must not look like "nothing installed" (that would install a second operator).
        _cfo_json "${tmp}/csvs.json" get clusterserviceversions.operators.coreos.com -A \
            && _cfo_json "${tmp}/ogs.json"  get operatorgroups.operators.coreos.com -A \
            && _cfo_json "${tmp}/subs.json" get subscriptions.operators.coreos.com -A \
            || { print -r -- "[ERROR] cfo_detect ${pkg} ${ns}: cannot read the OLM objects - nothing decided." >&2; return 1; }
        print -r -- '[]' > "${tmp}/helm.json"
        print -r -- '{}' > "${tmp}/values.json"
        # Helm releases: for cp-fko a failed read fails closed (plan C2: never two Flink operators on one
        # namespace); for CFK the Helm check is a bonus (an OLM-only cluster has no helm), so it only warns.
        local helm_ok=false
        if command -v helm >/dev/null 2>&1; then
            if helm list -A -o json > "${tmp}/helm.json" 2>/dev/null; then
                helm_ok=true
            else
                print -r -- '[]' > "${tmp}/helm.json"
            fi
            [[ -s "${tmp}/helm.json" ]] || print -r -- '[]' > "${tmp}/helm.json"
        fi
        if ! ${helm_ok}; then
            if [[ "${pkg}" == "${CFO_PKG_FKO}" ]]; then
                print -r -- "[ERROR] cfo_detect ${pkg} ${ns}: cannot list the Helm releases (helm list -A) to rule out a Helm Flink operator - nothing decided." >&2
                return 1
            fi
            print -r -- "[WARN] cfo_detect ${pkg} ${ns}: cannot list the Helm releases (helm list -A); a Helm-installed CFK would go unnoticed." >&2
        fi
        if ${helm_ok}; then
            if [[ "${pkg}" == "${CFO_PKG_FKO}" ]]; then
                local rel
                for rel in ${(f)"$(_cfo_olm_py guard-flink --helm "${tmp}/helm.json" 2>/dev/null)"}; do
                    local -a f=(${=rel})
                    [[ "${f[1]}" == fko ]] || continue
                    # "<ns>/<name>" of that release: helm list -A carries the namespace
                    local relns=""
                    relns="$(cfo_python -c 'import json,sys
for r in json.load(open(sys.argv[1])):
    if r.get("name") == sys.argv[2]: print(r.get("namespace", "")); break' "${tmp}/helm.json" "${f[2]}" 2>/dev/null)" || relns=""
                    helm get values "${f[2]}" -n "${relns}" -o json > "${tmp}/v.json" 2>/dev/null || print -r -- '{}' > "${tmp}/v.json"
                    cfo_python -c 'import json,sys
p, key, vf = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p))
try:
    v = json.load(open(vf))
except ValueError:
    v = {}
d[key] = v or {}
json.dump(d, open(p, "w"))' "${tmp}/values.json" "${relns}/${f[2]}" "${tmp}/v.json" 2>/dev/null || true
                done
            fi
        fi
        out="$(_cfo_olm_py detect --package "${pkg}" --namespace "${ns}" --csvs "${tmp}/csvs.json" \
            --ogs "${tmp}/ogs.json" --subs "${tmp}/subs.json" --helm "${tmp}/helm.json" \
            --helm-values "${tmp}/values.json" --owner "${owner}" --format shell)" || {
            print -r -- "[ERROR] cfo_detect ${pkg} ${ns}: confluent_operator_olm.py detect failed." >&2
            return 1
        }
        eval "${out}"
    } always {
        rm -rf "${tmp}"
    }
    case "${CFO_RESULT}" in
        reuse)    print -r -- "[INFO] ${pkg} for ${ns}: reuse ${CFO_CSV} in ${CFO_NS}$([[ ${CFO_OWNED} == true ]] && print ' (ours)')" ;;
        conflict) print -r -- "[INFO] ${pkg} for ${ns}: conflict - ${CFO_REASON}" ;;
        *)        print -r -- "[INFO] ${pkg} for ${ns}: none${CFO_REASON:+ (${CFO_REASON})}" ;;
    esac
    [[ -n "${CFO_OTHERS}" ]] && print -r -- "[WARN] Other ${pkg} installs on this cluster: ${CFO_OTHERS}" >&2
    return 0
}

# cfo_version_gate <package> <wanted-version> - every install of the package on
# the cluster must have that version (shared CRDs, plan C1/C10). Status 0/2.
cfo_version_gate() {
    local pkg="$1" wanted="$2" tmp out
    [[ -n "${wanted}" ]] || return 0
    tmp="$(_cfo_mktemp)" || return 1
    {
        _cfo_json "${tmp}/csvs.json" get clusterserviceversions.operators.coreos.com -A || return 1
        out="$(_cfo_olm_py version-gate --package "${pkg}" --wanted "${wanted}" --csvs "${tmp}/csvs.json")" || return 1
    } always {
        rm -rf "${tmp}"
    }
    [[ "${out}" == *'"ok": true'* ]] && return 0
    local -a lines
    lines=(${(f)"$(print -r -- "${out}" | cfo_python -c 'import json,sys
for f in json.load(sys.stdin)["found"]:
    print("found: ClusterServiceVersion/%s in %s (version %s)" % (f["csv"], f["ns"], f["version"]))')"})
    cfo_banner "${pkg} ${wanted} would join another version on this cluster (the CRDs are shared - one version per package)" \
        "${lines[@]}" \
        "Choose one:" \
        "  1. use the version that is already installed (set the channel / starting CSV to it)" \
        "  2. upgrade the other installs first (x.7_confluent_operator_upgrade.sh for ours)"
    return "${CFO_RC_BLOCKED}"
}

# cfo_catalog_check <package> <catalog> <catalog-ns> <channel> <starting-csv> -
# the catalog offers the package, channel and CSV. Sets CFO_CHANNEL_HEAD. Status 0/2.
cfo_catalog_check() {
    local pkg="$1" cat="$2" catns="$3" channel="$4" csv="$5" tmp out state disabled
    CFO_CHANNEL_HEAD=""
    tmp="$(_cfo_mktemp)" || return 1
    {
        _cfo_json "${tmp}/pm.json" get packagemanifests.packages.operators.coreos.com -n "${catns}" -l "catalog=${cat}" || true
        out="$(_cfo_olm_py channel-info --pm "${tmp}/pm.json" --package "${pkg}" --catalog "${cat}" \
            --channel "${channel}" --starting-csv "${csv}" --format shell)" || return 1
    } always {
        rm -rf "${tmp}"
    }
    local CFO_CI_FOUND="" CFO_CI_CHANNEL_FOUND="" CFO_CI_HEAD="" CFO_CI_STARTING_CSV_OK="" CFO_CI_CHANNEL="" \
        CFO_CI_DEFAULT_CHANNEL="" CFO_CI_CHANNELS="" CFO_CI_ENTRIES=""
    eval "${out}"
    state="$(oc get catalogsources.operators.coreos.com "${cat}" -n "${catns}" \
        -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)"
    disabled="$(oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}' 2>/dev/null || true)"
    if [[ "${CFO_CI_FOUND}" != true || "${CFO_CI_CHANNEL_FOUND}" != true ]]; then
        local -a extra=()
        [[ -n "${CFO_CI_CHANNELS}" ]] && extra+=("found: channels ${CFO_CI_CHANNELS} in CatalogSource ${cat}")
        [[ "${disabled}" == true ]] && extra+=("the default catalogs are disabled (operatorhub/cluster .spec.disableAllDefaultSources=true)")
        [[ -n "${state}" && "${state}" != READY ]] && extra+=("CatalogSource ${cat} in ${catns} is ${state}")
        cfo_banner "${pkg} channel ${CFO_CI_CHANNEL:-${channel}} is not in CatalogSource ${cat} - mirror it: private_registry_mirroring 1.0 -> 2.2 -> 3.4 with MIRROR_CONFLUENT_CONTENT including \"operators\"" \
            "${extra[@]}"
        return "${CFO_RC_BLOCKED}"
    fi
    if [[ "${state}" != READY ]]; then
        cfo_banner "CatalogSource ${cat} in ${catns} is ${state:-absent}, not READY" \
            "found: CatalogSource/${cat} in ${catns}" \
            "wait for the catalog pod, or check: oc get catalogsources.operators.coreos.com ${cat} -n ${catns} -o yaml"
        return "${CFO_RC_BLOCKED}"
    fi
    CFO_CHANNEL_HEAD="${CFO_CI_HEAD}"
    if [[ "${CFO_CI_STARTING_CSV_OK}" != true ]]; then
        cfo_banner "${csv} is not offered by ${pkg} channel ${CFO_CI_CHANNEL} in CatalogSource ${cat}" \
            "found: channel head ${CFO_CI_HEAD}; entries ${CFO_CI_ENTRIES}" \
            "set the starting CSV to one of the entries, or to \"\" for the channel head"
        return "${CFO_RC_BLOCKED}"
    fi
    return 0
}

# _cfo_apply_file <file> - oc apply; DRY_RUN: server dry-run (client with a
# WARN when refused) and a diff when the object exists. Status = the apply's.
_cfo_apply_file() {
    local file="$1" out rc=0
    if [[ "${DRY_RUN:-false}" == true ]]; then
        print -r -- "  [DRY-RUN] oc apply -f ${file}"
        out="$(oc apply --dry-run=server -f "${file}" 2>&1)" || rc=$?
        if (( rc != 0 )); then
            print -r -- "[WARN] Server dry-run refused for ${file:t} (${out//$'\n'/ }); using a client dry-run." >&2
            rc=0
            out="$(oc apply --dry-run=client -f "${file}" 2>&1)" || rc=$?
        fi
        [[ -n "${out}" ]] && print -r -- "${out}" | sed 's/^/  [DRY-RUN] /'
        if oc get -f "${file}" -o name >/dev/null 2>&1; then
            oc diff -f "${file}" 2>/dev/null | sed 's/^/  [DRY-RUN] /' || true
        fi
        return "${rc}"
    fi
    oc apply -f "${file}"
}

# _cfo_wait_deploy <ns> <deployment> <timeout> - ready replicas with progress.
_cfo_wait_deploy() {
    local ns="$1" name="$2" t="$3" e=0 st ready want
    while true; do
        st="$(oc get deployment "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || true)"
        ready="${st%%/*}"; want="${st#*/}"
        print -r -- "  [${e}s/${t}s] Deployment ${name}: ready ${ready:-0}/${want:-?}"
        [[ -n "${want}" && "${want}" != 0 && "${ready:-0}" == "${want}" ]] && return 0
        if (( e >= t )); then
            print -r -- "[ERROR] Deployment ${name} in ${ns} not ready after ${t}s." >&2
            return 1
        fi
        sleep "${CFO_POLL_INTERVAL}"
        e=$(( e + CFO_POLL_INTERVAL ))
    done
}

# cfo_install_ns <ns> <pkg>... - one OLM install of <pkg>s in <ns>: OwnNamespace
# OperatorGroup + Subscriptions (plan 4.2, 15.4). Status 0/1/2.
cfo_install_ns() {
    # K8S-EXTENSION(K2): dispatch on the operator source here (olm | helm); Kubernetes mode installs the
    # confluent-for-kubernetes / flink-kubernetes-operator charts with --set namespaced=true instead.
    local ns="$1"; shift
    local -a pkgs=("$@") expected=() subs=()
    _cfo_owner; local owner="${REPLY}"
    _cfo_render_root; local outdir="${REPLY}/cfk/olm"
    _cfo_int "${CONFLUENT_OPERATOR_INSTALLPLAN_TIMEOUT:-}" 300; local plan_t="${REPLY}"
    _cfo_int "${CONFLUENT_OPERATOR_CSV_TIMEOUT:-}" 600; local csv_t="${REPLY}"
    local pkg rc

    # [1/6] namespace
    print -r -- "[1/6] Namespace ${ns}"
    if [[ "${DRY_RUN:-false}" == true ]]; then
        if oc get namespace "${ns}" >/dev/null 2>&1; then
            print -r -- "[INFO] Namespace ${ns} already exists, leaving it as-is."
        else
            print -r -- "  [DRY-RUN] create namespace ${ns} (labels ${CFO_LABEL_PART_OF}, ${CFO_LABEL_OWNER_KEY}=${owner})"
        fi
    else
        cp4d_ensure_namespace "${ns}" "${CFO_LABEL_PART_OF}" "${CFO_LABEL_OWNER_KEY}=${owner}" || return 1
    fi

    # [2/6] catalog + one-version gate
    print -r -- "[2/6] Catalog and version checks"
    for pkg in "${pkgs[@]}"; do
        _cfo_pkg_settings "${pkg}"
        rc=0
        cfo_catalog_check "${_CFO_P_NAME}" "${_CFO_P_CATALOG}" "${_CFO_P_CATALOG_NS}" "${_CFO_P_CHANNEL}" "${_CFO_P_CSV}" || rc=$?
        (( rc == 0 )) || return "${rc}"
        local want_csv="${_CFO_P_CSV:-${CFO_CHANNEL_HEAD}}"
        cfo_version_gate "${_CFO_P_NAME}" "${want_csv#${_CFO_P_NAME}.v}" || rc=$?
        (( rc == 0 )) || return "${rc}"
        expected+=("${want_csv}")
        print -r -- "  ${_CFO_P_NAME}: channel ${_CFO_P_CHANNEL}, CSV ${want_csv}, approval ${_CFO_P_APPROVAL}"
    done

    # [3/6] OperatorGroup: create our OwnNamespace one, reuse an OwnNamespace one, never edit another
    print -r -- "[3/6] OperatorGroup in ${ns}"
    local tmp ogout
    tmp="$(_cfo_mktemp)" || return 1
    {
        _cfo_json "${tmp}/ogs.json" get operatorgroups.operators.coreos.com -n "${ns}" || return 1
        ogout="$(_cfo_olm_py og-check --ogs "${tmp}/ogs.json" --namespace "${ns}" --format shell)" || return 1
    } always {
        rm -rf "${tmp}"
    }
    local CFO_OG_RESULT="" CFO_OG_NAME="" CFO_OG_TARGETS=""
    eval "${ogout}"
    case "${CFO_OG_RESULT}" in
        own)  print -r -- "[INFO] OperatorGroup ${CFO_OG_NAME} already targets ${ns} (OwnNamespace) - reusing it." ;;
        none)
            mkdir -p "${outdir}"
            local ogfile="${outdir}/operatorgroup-${ns}.yaml"
            cat > "${ogfile}" <<YAML
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${ns}-confluent-og
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: confluent
    confluent.ibm-scripts/installed-by: "${owner}"
spec:
  targetNamespaces:
  - ${ns}
YAML
            _cfo_apply_file "${ogfile}" || return 1 ;;
        *)
            cfo_banner "OperatorGroup ${CFO_OG_NAME} in ${ns} is not OwnNamespace for ${ns} (${CFO_OG_RESULT}, targets ${CFO_OG_TARGETS:-?})" \
                "found: OperatorGroup/${CFO_OG_NAME} in ${ns}" \
                "Choose one:" \
                "  1. point PROJECT_CONFLUENT_SERVER / PROJECT_CONFLUENT_FLINK at a namespace without it" \
                "  2. change or remove that OperatorGroup yourself (the scripts never edit one)"
            return "${CFO_RC_BLOCKED}" ;;
    esac

    # [4/6] Subscriptions
    print -r -- "[4/6] Subscriptions"
    mkdir -p "${outdir}"
    for pkg in "${pkgs[@]}"; do
        _cfo_pkg_settings "${pkg}"
        local have=""
        have="$(oc get subscriptions.operators.coreos.com "${_CFO_P_SUB}" -n "${ns}" \
            -o jsonpath="{.metadata.labels.confluent\.ibm-scripts/installed-by}|{.metadata.name}" 2>/dev/null || true)"
        if [[ -n "${have#*|}" && "${have%%|*}" != "${owner}" ]]; then
            cfo_banner "Subscription ${_CFO_P_SUB} in ${ns} exists and is not ours" \
                "found: Subscription/${_CFO_P_SUB} in ${ns} (installed-by '${have%%|*}')" \
                "remove it, or let the operators step reuse the operator once it has installed"
            return "${CFO_RC_BLOCKED}"
        fi
        local env_json="" subfile="${outdir}/subscription-${ns}-${pkg}.yaml"
        env_json="$(cfo_subscription_env "${ns}" "${pkg}")" || env_json='[]'
        {
            print -r -- "apiVersion: operators.coreos.com/v1alpha1"
            print -r -- "kind: Subscription"
            print -r -- "metadata:"
            print -r -- "  name: ${_CFO_P_SUB}"
            print -r -- "  namespace: ${ns}"
            print -r -- "  labels:"
            print -r -- "    app.kubernetes.io/part-of: confluent"
            print -r -- "    confluent.ibm-scripts/installed-by: \"${owner}\""
            print -r -- "spec:"
            print -r -- "  name: ${_CFO_P_NAME}"
            print -r -- "  channel: \"${_CFO_P_CHANNEL}\""
            print -r -- "  source: ${_CFO_P_CATALOG}"
            print -r -- "  sourceNamespace: ${_CFO_P_CATALOG_NS}"
            print -r -- "  installPlanApproval: ${_CFO_P_APPROVAL}"
            [[ -n "${_CFO_P_CSV}" ]] && print -r -- "  startingCSV: ${_CFO_P_CSV}"
            if [[ "${env_json}" != "[]" ]]; then
                print -r -- "  config:"
                print -r -- "    env: ${env_json}"
            fi
        } > "${subfile}"
        print -r -- "  Subscription ${_CFO_P_SUB} (${_CFO_P_NAME}) -> ${subfile}"
        _cfo_apply_file "${subfile}" || return 1
    done

    # [5/6] Manual approval of the first InstallPlan
    if _cfo_any_manual "${pkgs[@]}"; then
        print -r -- "[5/6] InstallPlan approval (Manual)"
        if [[ "${DRY_RUN:-false}" == true ]]; then
            print -r -- "  [DRY-RUN] would approve the first InstallPlan in ${ns} when it lists only: ${expected[*]}"
        else
            rc=0
            cfo_approve_installplans "${ns}" "${plan_t}" "${expected[@]}" || rc=$?
            (( rc == 0 )) || return "${rc}"
        fi
    else
        print -r -- "[5/6] InstallPlan approval: Automatic - OLM installs at once"
    fi

    # [6/6] CSV Succeeded + operator Deployment ready
    print -r -- "[6/6] Wait for the operators"
    if [[ "${DRY_RUN:-false}" == true ]]; then
        print -r -- "  [DRY-RUN] would wait for CSV ${expected[*]} (Succeeded) and the operator Deployments"
        local j=1
        for pkg in "${pkgs[@]}"; do
            _cfo_pkg_settings "${pkg}"
            CFO_SUMMARY_ROWS+=("${ns}|${_CFO_P_NAME}|would install (dry-run)|${expected[$j]}|${_CFO_P_APPROVAL}")
            (( j += 1 ))
        done
        return 0
    fi
    local i=1
    for pkg in "${pkgs[@]}"; do
        _cfo_pkg_settings "${pkg}"
        cfo_wait_csv "${ns}" "${expected[$i]}" "${csv_t}" || return 1
        _cfo_wait_deploy "${ns}" "${_CFO_P_DEPLOY}" "${csv_t}" || return 1
        CFO_SUMMARY_ROWS+=("${ns}|${_CFO_P_NAME}|installed|${expected[$i]}|${_CFO_P_APPROVAL}")
        (( i += 1 ))
    done
    return 0
}

_cfo_any_manual() {
    local p
    for p in "$@"; do
        _cfo_pkg_settings "${p}"
        [[ "${_CFO_P_APPROVAL}" == Manual ]] && return 0
    done
    return 1
}

# cfo_install <package> <ns>
cfo_install() { cfo_install_ns "$2" "$1"; }

# cfo_ensure_operators <ns> <pkg>... - detect each package; reuse, block, or
# install the missing ones in one batch. Status 0/1/2.
cfo_ensure_operators() {
    local ns="$1"; shift
    local -a collect=()
    local pkg source blocked=0
    for pkg in "$@"; do
        _cfo_pkg_settings "${pkg}"
        cfo_detect "${_CFO_P_NAME}" "${ns}" || return 1
        case "${CFO_RESULT}" in
            reuse)
                CFO_SUMMARY_ROWS+=("${ns}|${_CFO_P_NAME}|reuse${CFO_NS:+ (${CFO_NS})}|${CFO_CSV}|${_CFO_P_APPROVAL}") ;;
            conflict)
                local found_line="found: a Helm release or a non-OLM install (named above) for ${ns}"
                [[ -n "${CFO_CSV}" ]] && found_line="found: ClusterServiceVersion/${CFO_CSV} in ${CFO_NS:-${ns}}"
                cfo_banner "${CFO_REASON}" \
                    "${found_line}" \
                    "Choose one:" \
                    "  1. point the namespace setting at a namespace no other ${_CFO_P_NAME} watches" \
                    "  2. remove or narrow the other operator yourself (the scripts never edit it)"
                CFO_SUMMARY_ROWS+=("${ns}|${_CFO_P_NAME}|BLOCKED|${CFO_CSV:--}|${_CFO_P_APPROVAL}")
                blocked=1 ;;
            *)
                if [[ "${pkg}" == "${CFO_PKG_CFK}" ]]; then
                    source="$(cfo_operator_source)" || return 1
                else
                    source="$(cf_flink_operator_source)"
                fi
                if [[ "${source}" == existing ]]; then
                    local var=CONFLUENT_OPERATOR_SOURCE
                    [[ "${pkg}" == "${CFO_PKG_FKO}" ]] && var=FLINK_OPERATOR_SOURCE
                    cfo_banner "No ${_CFO_P_NAME} watches ${ns}, and ${var}=existing installs none" \
                        "found: nothing" \
                        "Choose one:" \
                        "  1. install the operator for ${ns} yourself (OperatorHub), then re-run" \
                        "  2. set ${var}=\"olm\" so the scripts install it"
                    CFO_SUMMARY_ROWS+=("${ns}|${_CFO_P_NAME}|BLOCKED|-|${_CFO_P_APPROVAL}")
                    blocked=1
                else
                    collect+=("${pkg}")
                fi ;;
        esac
    done
    (( blocked )) && return "${CFO_RC_BLOCKED}"
    (( ${#collect} )) || return 0
    local rc=0
    cfo_install_ns "${ns}" "${collect[@]}" || rc=$?
    if (( rc != 0 )); then
        # the summary must show what did not install (cfo_install_ns adds rows only on success)
        local word=FAILED
        (( rc == CFO_RC_BLOCKED )) && word=BLOCKED
        for pkg in "${collect[@]}"; do
            _cfo_pkg_settings "${pkg}"
            local row had=false
            for row in "${CFO_SUMMARY_ROWS[@]}"; do
                [[ "${row}" == "${ns}|${_CFO_P_NAME}|"* ]] && had=true
            done
            ${had} && continue
            CFO_SUMMARY_ROWS+=("${ns}|${_CFO_P_NAME}|${word}|-|${_CFO_P_APPROVAL}")
        done
    fi
    return "${rc}"
}

# cfo_subscription_env <ns> <pkg> - JSON list of the spec.config.env entries our Subscription carries.
cfo_subscription_env() {
    _cfo_config subscription-env --namespace "$1" --package "$2"
}

# cfo_ensure_subscription_env <ns> <sub> NAME=VALUE... - merge-patch the
# entries into spec.config.env (others kept). Foreign Subscriptions only with
# CONFLUENT_OPERATOR_ALLOW_PATCH_EXISTING=true. Status 0/1/2.
cfo_ensure_subscription_env() {
    local ns="$1" sub="$2" tmp out label
    shift 2
    (( $# )) || return 0
    _cfo_owner; local owner="${REPLY}"
    tmp="$(_cfo_mktemp)" || return 1
    {
        oc get subscriptions.operators.coreos.com "${sub}" -n "${ns}" -o json > "${tmp}/sub.json" 2>/dev/null \
            || print -r -- '{}' > "${tmp}/sub.json"
        out="$(_cfo_olm_py sub-env-merge --sub "${tmp}/sub.json" --set "$@")" || return 1
        label="$(cfo_python -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    d = {}
print(((d.get("metadata") or {}).get("labels") or {}).get("confluent.ibm-scripts/installed-by", ""))' "${tmp}/sub.json")"
    } always {
        rm -rf "${tmp}"
    }
    local CFO_ENV_STATE="" CFO_ENV_PATCH=""
    eval "${out}"
    case "${CFO_ENV_STATE}" in
        present) print -r -- "[INFO] Subscription ${sub} in ${ns} already has $*."; return 0 ;;
        absent)  print -r -- "[ERROR] Subscription ${sub} not found in ${ns}." >&2; return 1 ;;
    esac
    if [[ "${label}" != "${owner}" ]] && ! h_is_true "${CONFLUENT_OPERATOR_ALLOW_PATCH_EXISTING:-false}"; then
        _cfo_vars_file
        cfo_banner "Subscription ${sub} in ${ns} is not ours and lacks $*" \
            "found: Subscription/${sub} in ${ns}" \
            "Choose one:" \
            "  1. add it yourself: oc patch subscriptions.operators.coreos.com ${sub} -n ${ns} --type=merge -p '${CFO_ENV_PATCH}'" \
            "  2. let the scripts patch it: set CONFLUENT_OPERATOR_ALLOW_PATCH_EXISTING=\"true\" in ${REPLY}"
        return "${CFO_RC_BLOCKED}"
    fi
    if [[ "${DRY_RUN:-false}" == true ]]; then
        print -r -- "  [DRY-RUN] oc patch subscriptions.operators.coreos.com ${sub} -n ${ns} --type=merge -p '${CFO_ENV_PATCH}'"
        return 0
    fi
    oc patch subscriptions.operators.coreos.com "${sub}" -n "${ns}" --type=merge -p "${CFO_ENV_PATCH}" >/dev/null || return 1
    print -r -- "[INFO] Subscription ${sub} in ${ns}: spec.config.env now has $* (OLM rolls the operator)."
}

# cfo_approve_installplans <ns> <timeout> <expected-csv>... - approves the first
# InstallPlan of our Subscriptions when it lists only expected CSVs. Status 0/1/2.
cfo_approve_installplans() {
    local ns="$1" t="$2" e=0 line missing plans
    shift 2
    local -a expected=("$@") want_pkgs=()
    local c
    # Only the Subscriptions of this batch's packages: an earlier Subscription of ours in the namespace (CFK
    # installed before cp-fko joined) points at an old, possibly garbage-collected plan.
    for c in "${expected[@]}"; do want_pkgs+=("${c%%.v[0-9]*}"); done
    _cfo_owner; local owner="${REPLY}"
    local -A plan_of
    while true; do
        plans="$(oc get subscriptions.operators.coreos.com -n "${ns}" -l "${CFO_LABEL_OWNER_KEY}=${owner}" \
            -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.name}{" "}{.status.installPlanRef.name}{"\n"}{end}' 2>/dev/null || true)"
        missing=""
        plan_of=()
        for line in "${(@f)plans}"; do
            [[ -z "${line}" ]] && continue
            local -a w=("${(@s: :)line}")
            local s="${w[1]}" pk="${w[2]:-}" p="${w[3]:-}"
            (( ${want_pkgs[(Ie)${pk}]} )) || continue
            if [[ -z "${p}" ]]; then missing+=" ${s}"; else plan_of[${s}]="${p}"; fi
        done
        if [[ -z "${missing}" && ${#plan_of} -gt 0 ]]; then
            break
        fi
        print -r -- "  [${e}s/${t}s] InstallPlan: waiting for Subscription(s)${missing:- (none of ours yet)}"
        if (( e >= t )); then
            print -r -- "[ERROR] No InstallPlan for${missing} in ${ns} after ${t}s." >&2
            return 1
        fi
        sleep "${CFO_POLL_INTERVAL}"
        e=$(( e + CFO_POLL_INTERVAL ))
    done

    local plan tmp out phase
    for plan in ${(u)plan_of}; do
        tmp="$(_cfo_mktemp)" || return 1
        {
            oc get installplans.operators.coreos.com "${plan}" -n "${ns}" -o json > "${tmp}/plan.json" 2>/dev/null \
                || { print -r -- "[ERROR] InstallPlan ${plan} in ${ns} cannot be read." >&2; return 1; }
            out="$(_cfo_olm_py installplan-check --plan "${tmp}/plan.json" --expect "${expected[@]}")" || return 1
        } always {
            rm -rf "${tmp}"
        }
        phase="$(print -r -- "${out}" | cfo_python -c 'import json,sys; print(json.load(sys.stdin)["phase"])')"
        print -r -- "  [${e}s/${t}s] InstallPlan ${plan}: ${phase:-pending}"
        if [[ "${out}" == *'"approved": true'* ]]; then
            print -r -- "[INFO] InstallPlan ${plan} is already approved."
            continue
        fi
        if [[ "${out}" != *'"approve": true'* ]]; then
            local extra=""
            extra="$(print -r -- "${out}" | cfo_python -c 'import json,sys; print(", ".join(json.load(sys.stdin)["extra"]) or "(no CSV listed)")')"
            cfo_banner "InstallPlan ${plan} in ${ns} installs more than this run asked for" \
                "found: InstallPlan/${plan} in ${ns}: ${extra}" \
                "expected only: ${expected[*]}" \
                "review it, then approve it yourself: oc patch installplans.operators.coreos.com ${plan} -n ${ns} --type=merge -p '{\"spec\":{\"approved\":true}}'"
            return "${CFO_RC_BLOCKED}"
        fi
        oc patch installplans.operators.coreos.com "${plan}" -n "${ns}" --type=merge -p '{"spec":{"approved":true}}' >/dev/null \
            || return 1
        print -r -- "[INFO] InstallPlan ${plan} approved (${expected[*]})."
    done
    return 0
}

# cfo_wait_csv <ns> <csv> <timeout> - CSV Succeeded, with progress; Failed or timeout = status 1.
cfo_wait_csv() {
    local ns="$1" csv="$2" t="$3" e=0 phase
    while true; do
        phase="$(cp4d_csv_phase "${ns}" "${csv}")"
        print -r -- "  [${e}s/${t}s] CSV ${csv}: ${phase:-pending}"
        [[ "${phase}" == Succeeded ]] && return 0
        if [[ "${phase}" == Failed ]]; then
            print -r -- "[ERROR] CSV ${csv} in ${ns} failed. Conditions:" >&2
            oc get subscriptions.operators.coreos.com -n "${ns}" \
                -o jsonpath='{range .items[*]}Subscription {.metadata.name}: {range .status.conditions[*]}{.type}={.status} {.message}; {end}{"\n"}{end}' >&2 2>/dev/null || true
            oc get installplans.operators.coreos.com -n "${ns}" \
                -o jsonpath='{range .items[*]}InstallPlan {.metadata.name}: {.status.phase} {range .status.conditions[*]}{.type}={.status} {.message}; {end}{"\n"}{end}' >&2 2>/dev/null || true
            oc get clusterserviceversions.operators.coreos.com "${csv}" -n "${ns}" \
                -o jsonpath='{range .status.conditions[*]}CSV {.phase} {.reason}: {.message}{"\n"}{end}' >&2 2>/dev/null || true
            return 1
        fi
        if (( e >= t )); then
            print -r -- "[ERROR] CSV ${csv} in ${ns} not Succeeded after ${t}s (last phase: ${phase:-none})." >&2
            return 1
        fi
        sleep "${CFO_POLL_INTERVAL}"
        e=$(( e + CFO_POLL_INTERVAL ))
    done
}

# cfo_operator_rows <ns> - the "Operators" rows of 1.2 (S6), tab-separated:
# subscription package channel approval state installedCSV csv-phase pending-plan deployment ready vs-starting
cfo_operator_rows() {
    local ns="$1" tmp
    tmp="$(_cfo_mktemp)" || return 1
    {
        _cfo_json "${tmp}/subs.json" get subscriptions.operators.coreos.com -n "${ns}" || true
        _cfo_json "${tmp}/csvs.json" get clusterserviceversions.operators.coreos.com -n "${ns}" || true
        _cfo_json "${tmp}/plans.json" get installplans.operators.coreos.com -n "${ns}" || true
        _cfo_json "${tmp}/deploys.json" get deployments.apps -n "${ns}" || true
        _cfo_olm_py operator-rows --namespace "${ns}" --subs "${tmp}/subs.json" --csvs "${tmp}/csvs.json" \
            --plans "${tmp}/plans.json" --deploys "${tmp}/deploys.json"
    } always {
        rm -rf "${tmp}"
    }
}

# cfo_autoselect_latest [--persist] - the newest compatible operator set from
# the live catalogs and the Confluent Helm index, next to the pins (plan 15.5).
# New installs only: exports the chosen values for this process (--persist or
# CFO_AUTOSELECT_PERSIST=1 also saves them); an installed operator only gets a report.
cfo_autoselect_latest() {
    local persist=false
    [[ "${1:-}" == --persist || -n "${CFO_AUTOSELECT_PERSIST:-}" ]] && persist=true
    local tmp out
    tmp="$(_cfo_mktemp)" || return 1
    {
        _cfo_pkg_settings "${CFO_PKG_CFK}"
        _cfo_json "${tmp}/cfk.json" get packagemanifests.packages.operators.coreos.com -n "${_CFO_P_CATALOG_NS}" -l "catalog=${_CFO_P_CATALOG}" || true
        _cfo_pkg_settings "${CFO_PKG_FKO}"
        _cfo_json "${tmp}/fko.json" get packagemanifests.packages.operators.coreos.com -n "${_CFO_P_CATALOG_NS}" -l "catalog=${_CFO_P_CATALOG}" || true
        local -a idx=()
        if [[ "${FLINK_CHART_SOURCE:-repo}" == (oci|local) ]]; then
            print -r -- "[INFO] FLINK_CHART_SOURCE=${FLINK_CHART_SOURCE}: the Helm index is not read; the CMF chart stays pinned."
        elif curl -sfL "${FLINK_HELM_REPO_URL:-https://packages.confluent.io/helm}/index.yaml" -o "${tmp}/index.yaml" 2>/dev/null; then
            idx=(--helm-index "${tmp}/index.yaml")
        else
            print -r -- "[WARN] Could not read ${FLINK_HELM_REPO_URL:-https://packages.confluent.io/helm}/index.yaml; the CMF chart stays pinned." >&2
        fi
        out="$(_cfo_olm_py autoselect --cfk-pm "${tmp}/cfk.json" --fko-pm "${tmp}/fko.json" "${idx[@]}" --format lines)" || return 1
    } always {
        rm -rf "${tmp}"
    }
    local line name pinned chosen installed=false
    local -A chosen_of
    print -r -- "[INFO] --autoselect-latest: newest compatible operator set"
    printf '  %-34s %-34s %-34s %s\n' VARIABLE CURRENT PINNED CHOSEN
    for line in "${(@f)out}"; do
        [[ -z "${line}" ]] && continue
        local -a f=("${(@s:	:)line}")
        if [[ "${f[1]}" == NOTE ]]; then
            print -r -- "[INFO]   note: ${f[2]}"
            continue
        fi
        name="${f[1]}" pinned="${f[2]}" chosen="${f[3]}"
        chosen_of[${name}]="${chosen}"
        printf '  %-34s %-34s %-34s %s\n' "${name}" "${(P)name:--}" "${pinned:--}" "${chosen:--}"
    done
    # The Flink set only applies when the Flink add-on runs cp-fko: a Helm (scripts-mode) Flink keeps its
    # pinned CMF chart, and an unconfigured add-on gets no half-written Flink settings.
    local flink_olm=false
    cf_flink_configured && cf_flink_is_olm && flink_olm=true
    if [[ -n "${PROJECT_CONFLUENT_SERVER:-}" ]] && cf_is_operator_mode; then
        if ! cfo_detect "${CFO_PKG_CFK}" "${PROJECT_CONFLUENT_SERVER}" >/dev/null 2>&1; then
            print -r -- "[WARN] Cannot tell whether CFK is installed for ${PROJECT_CONFLUENT_SERVER} - keeping the pinned set." >&2
            installed=true
        fi
        [[ "${CFO_RESULT}" == reuse ]] && installed=true
    fi
    if ${flink_olm}; then
        if ! cfo_detect "${CFO_PKG_FKO}" "${PROJECT_CONFLUENT_FLINK}" >/dev/null 2>&1; then
            print -r -- "[WARN] Cannot tell whether cp-fko is installed for ${PROJECT_CONFLUENT_FLINK} - keeping the pinned set." >&2
            installed=true
        fi
        [[ "${CFO_RESULT}" == reuse ]] && installed=true
    fi
    if ${installed}; then
        print -r -- "[INFO] An operator is already installed: nothing changes. To move to the newer set run"
        print -r -- "       ${CF_PLATFORM_DIR}/utility_scripts_confluent_platform/x.7_confluent_operator_upgrade.sh --check"
        return 0
    fi
    _cfo_vars_file; local vars_file="${REPLY}"
    for name in ${(ko)chosen_of}; do
        [[ -n "${chosen_of[$name]}" ]] || continue
        if [[ "${name}" == FLINK_* ]] && ! ${flink_olm}; then
            continue
        fi
        export "${name}=${chosen_of[$name]}"
        if ${persist}; then
            cf_persist_var "${vars_file}" "${name}" "${chosen_of[$name]}" || return 1
        fi
    done
    ${persist} || print -r -- "[INFO] Chosen values apply to this run only (add --persist to save them)."
    return 0
}

# =============================================================================
# TLS and secrets
# =============================================================================
# cfo_tls_make_cert <out-dir> <cn> <san-csv> <days> [<ca-dir>] - CA (or the one
# in <ca-dir>) + server cert; 0600 files ca.crt ca.key server.crt server.key
# fullchain.pem privkey.pem cacerts.pem (openssl as confluent_kafka_security.sh).
cfo_tls_make_cert() {
    local out="$1" cn="$2" sans="$3" days="${4:-825}" cadir="${5:-}"
    command -v openssl >/dev/null 2>&1 || { print -r -- "[ERROR] openssl is required to generate certificates." >&2; return 1; }
    (
        umask 077
        mkdir -p "${out}" || exit 1
        local san="" s
        for s in ${(s:,:)sans}; do
            [[ -z "${s}" ]] && continue
            [[ "${s}" == (DNS|IP):* ]] || s="DNS:${s}"
            san+="${san:+,}${s}"
        done
        if [[ -n "${cadir}" && -f "${cadir}/ca.crt" && -f "${cadir}/ca.key" ]]; then
            cp "${cadir}/ca.crt" "${out}/ca.crt" && cp "${cadir}/ca.key" "${out}/ca.key" || exit 1
        else
            openssl req -new -x509 -nodes -days "${days}" \
                -subj "/CN=Confluent CFK CA/O=ibm-software-installation-scripts" \
                -keyout "${out}/ca.key" -out "${out}/ca.crt" 2>/dev/null || exit 1
        fi
        # X.509 caps a CN at 64 characters; clients check the SAN list.
        openssl req -new -nodes -subj "/CN=${cn[1,64]}/O=ibm-software-installation-scripts" \
            -keyout "${out}/server.key" -out "${out}/server.csr" 2>/dev/null \
        && printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\n' "${san}" > "${out}/ext.cnf" \
        && openssl x509 -req -in "${out}/server.csr" -CA "${out}/ca.crt" -CAkey "${out}/ca.key" -CAcreateserial \
            -out "${out}/server.crt" -days "${days}" -extfile "${out}/ext.cnf" 2>/dev/null || exit 1
        cat "${out}/server.crt" "${out}/ca.crt" > "${out}/fullchain.pem"
        cp "${out}/server.key" "${out}/privkey.pem"
        cp "${out}/ca.crt" "${out}/cacerts.pem"
        rm -f "${out}/server.csr" "${out}/ext.cnf" "${out}/ca.srl"
        chmod 600 "${out}"/*
    ) || { print -r -- "[ERROR] Generating the certificate for ${cn} failed." >&2; return 1; }
}

# cfo_secret_apply <ns> <name> <label k=v>... -- <key>=<file>... - creates or
# updates a generic secret from files, labelled. Values never reach argv.
cfo_secret_apply() {
    local ns="$1" name="$2"
    shift 2
    local -a labels=() files=() keys=()
    while (( $# )) && [[ "$1" != -- ]]; do labels+=("$1"); shift; done
    [[ "${1:-}" == -- ]] && shift
    local kv
    for kv in "$@"; do
        files+=("--from-file=${kv}")
        keys+=("${kv%%=*}")
    done
    if [[ "${DRY_RUN:-false}" == true ]]; then
        print -r -- "  [DRY-RUN] secret/${name} keys: ${(j:,:)keys}"
        return 0
    fi
    oc create secret generic "${name}" -n "${ns}" "${files[@]}" --dry-run=client -o yaml \
        | oc label --local -f - "${labels[@]}" -o yaml \
        | oc apply -f - >/dev/null
}

# cfo_tls_ensure_ca_pair <ns> - TLS source cfk: the CA CFK signs its
# autoGeneratedCerts with (V27), created once.
cfo_tls_ensure_ca_pair() {
    local ns="$1"
    [[ "$(cfo_tls_source)" == cfk ]] || return 0
    if oc get secret "${CFO_CA_PAIR_SECRET}" -n "${ns}" -o name >/dev/null 2>&1; then
        print -r -- "[INFO] CA secret ${CFO_CA_PAIR_SECRET} already present in ${ns}."
        return 0
    fi
    _cfo_owner; local owner="${REPLY}"
    if [[ "${DRY_RUN:-false}" == true ]]; then
        print -r -- "  [DRY-RUN] secret/${CFO_CA_PAIR_SECRET} keys: tls.crt,tls.key (new CA)"
        return 0
    fi
    local tmp rc=0
    tmp="$(_cfo_mktemp)" || return 1
    {
        (
            umask 077
            openssl req -new -x509 -nodes -days "${CONFLUENT_INTERNAL_CERT_VALIDITY_DAYS:-825}" \
                -subj "/CN=Confluent CFK CA/O=ibm-software-installation-scripts" \
                -keyout "${tmp}/tls.key" -out "${tmp}/tls.crt" 2>/dev/null
        ) || { print -r -- "[ERROR] Generating the CFK CA failed." >&2; return 1; }
        # CONTRACT-DEVIATION: a kubernetes.io/tls secret (oc create secret tls) rather than cfo_secret_apply's
        # generic one - same keys; the type is what `oc create secret tls` gives the CFK docs' ca-pair-sslcerts.
        oc create secret tls "${CFO_CA_PAIR_SECRET}" -n "${ns}" --cert="${tmp}/tls.crt" --key="${tmp}/tls.key" \
            --dry-run=client -o yaml \
            | oc label --local -f - "${CFO_LABEL_PART_OF}" "${CFO_LABEL_OWNER_KEY}=${owner}" -o yaml \
            | oc apply -f - >/dev/null || rc=1
    } always {
        rm -rf "${tmp}"
    }
    (( rc == 0 )) && print -r -- "[INFO] CA secret ${CFO_CA_PAIR_SECRET} created in ${ns} (CFK signs its certificates with it)."
    return "${rc}"
}

# The SAN host names the external listener needs for the current broker count.
_cfo_external_hosts() {
    local domain="$1" ns="${PROJECT_CONFLUENT_SERVER:-}"
    local boot="${CONFLUENT_EXTERNAL_KAFKA_BOOTSTRAP_PREFIX:-kafka-${ns}}"
    local broker="${CONFLUENT_EXTERNAL_KAFKA_BROKER_PREFIX:-kafka-${ns}-b}"
    local n="${CONFLUENT_BROKER_REPLICAS:-3}" i
    [[ "${n}" == <-> ]] || n=3
    local -a hosts=("${boot}.${domain}")
    for (( i = 0; i < n; i++ )); do hosts+=("${broker}${i}.${domain}"); done
    REPLY="${(j:,:)hosts}"
}

# cfo_tls_ensure_external_cert <ns> <domain> [--rotate] - the external listener's
# secret (keys ca.crt fullchain.pem privkey.pem cacerts.pem) with the route SANs.
cfo_tls_ensure_external_cert() {
    local ns="$1" domain="$2" rotate=false
    [[ "${3:-}" == --rotate ]] && rotate=true
    local secret="${CONFLUENT_EXTERNAL_TLS_SECRET:-confluent-kafka-tls}"
    _cfo_external_hosts "${domain}"; local sans="${REPLY}"
    if ! ${rotate}; then
        local have=""
        # -text, not -ext subjectAltName: macOS LibreSSL has no -ext, and an empty answer here would
        # regenerate (rotate) the certificate on every run.
        have="$(oc get secret "${secret}" -n "${ns}" -o jsonpath='{.data.fullchain\.pem}' 2>/dev/null | base64 --decode 2>/dev/null \
            | openssl x509 -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -n 1 || true)"
        if [[ -n "${have}" ]]; then
            local h missing=""
            have=",${have//[[:space:]]/},"      # ",DNS:a,DNS:b," - whole-entry matches only
            for h in ${(s:,:)sans}; do
                [[ "${have}" == *",DNS:${h},"* ]] || missing+=" ${h}"
            done
            if [[ -z "${missing}" ]]; then
                print -r -- "[INFO] External TLS secret ${secret} already covers ${sans//,/, }."
                return 0
            fi
            print -r -- "[INFO] External TLS secret ${secret} lacks${missing} - regenerating it."
        fi
    fi
    if [[ "${DRY_RUN:-false}" == true ]]; then
        print -r -- "  [DRY-RUN] secret/${secret} keys: ca.crt,fullchain.pem,privkey.pem,cacerts.pem (SANs ${sans})"
        return 0
    fi
    _cfo_owner; local owner="${REPLY}" tmp rc=0
    tmp="$(_cfo_mktemp)" || return 1
    {
        cfo_tls_make_cert "${tmp}/cert" "${sans%%,*}" "${sans}" "${CONFLUENT_EXTERNAL_CERT_VALIDITY_DAYS:-825}" || return 1
        cfo_secret_apply "${ns}" "${secret}" "${CFO_LABEL_PART_OF}" "${CFO_LABEL_OWNER_KEY}=${owner}" -- \
            "ca.crt=${tmp}/cert/ca.crt" "fullchain.pem=${tmp}/cert/fullchain.pem" \
            "privkey.pem=${tmp}/cert/privkey.pem" "cacerts.pem=${tmp}/cert/cacerts.pem" || rc=1
    } always {
        rm -rf "${tmp}"
    }
    (( rc == 0 )) && print -r -- "[INFO] External TLS secret ${secret} written (SANs ${sans//,/, })."
    return "${rc}"
}

# cfo_derive_sasl_secrets <ns> - CFK's SASL/PLAIN secrets from CONFLUENT_SASL_SECRET (V6):
# server (plain-users.json, plain-interbroker.txt) and client (plain.txt).
cfo_derive_sasl_secrets() {
    local ns="$1" src="${CONFLUENT_SASL_SECRET:-confluent-sasl}" admin="${CONFLUENT_SASL_ADMIN_USER:-admin}"
    _cfo_owner; local owner="${REPLY}"
    local -a labels=("${CFO_LABEL_PART_OF}" "${CFO_LABEL_OWNER_KEY}=${owner}" "${CFO_LABEL_DERIVED_KEY}=${src}")
    if [[ "${DRY_RUN:-false}" == true ]]; then
        print -r -- "  [DRY-RUN] secret/${CFO_SASL_SERVER_SECRET} keys: plain-users.json,plain-interbroker.txt,kafka-server-listener-{internal,replication,external}-plain-metrics.txt (from ${src})"
        print -r -- "  [DRY-RUN] secret/${CFO_SASL_CLIENT_SECRET} keys: plain.txt (from ${src})"
        return 0
    fi
    (( ${+functions[kafka_secret_credentials]} )) || source "${CF_PLATFORM_DIR}/confluent_kafka_security.sh"
    local tmp rc=0
    tmp="$(_cfo_mktemp)" || return 1
    {
        ( umask 077; CONFLUENT_SASL_SECRET="${src}" kafka_secret_credentials "${ns}" > "${tmp}/creds" ) || rc=1
        if (( rc == 0 )) && [[ ! -s "${tmp}/creds" ]]; then
            print -r -- "[ERROR] SASL secret ${src} in ${ns} has no users (run 1.0_confluent_prep.sh first)." >&2
            rc=1
        fi
        if (( rc == 0 )); then
            ( umask 077; cfo_python -c 'import json, os, sys
creds, admin, out = sys.argv[1], sys.argv[2], sys.argv[3]
users = {}
for line in open(creds):
    line = line.rstrip("\n")
    if "=" in line:
        user, pw = line.split("=", 1)
        users[user] = pw
if admin not in users:
    sys.stderr.write("[ERROR] user %s is not in the SASL secret\n" % admin)
    sys.exit(1)
def write(name, text):
    fd = os.open(os.path.join(out, name), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
write("plain-users.json", json.dumps(users, sort_keys=True))
pair = "username=%s\npassword=%s\n" % (admin, users[admin])
write("plain-interbroker.txt", pair)
for listener in ("internal", "replication", "external"):
    write("kafka-server-listener-%s-plain-metrics.txt" % listener, pair)
write("plain.txt", pair)' "${tmp}/creds" "${admin}" "${tmp}" ) || rc=1
        fi
        if (( rc == 0 )); then
            # CFK 3.4 refuses a Kafka CR whose PLAIN listener secret lacks the metrics reporter's credentials
            # ("missing metric key internal credentials ... kafka-server-listener-internal-plain-metrics.txt",
            # seen in a live install test; key shape as in Confluent's multi-tenancy quick start).
            # One key per listener that uses this secret, all holding the admin pair.
            cfo_secret_apply "${ns}" "${CFO_SASL_SERVER_SECRET}" "${labels[@]}" -- \
                "plain-users.json=${tmp}/plain-users.json" "plain-interbroker.txt=${tmp}/plain-interbroker.txt" \
                "kafka-server-listener-internal-plain-metrics.txt=${tmp}/kafka-server-listener-internal-plain-metrics.txt" \
                "kafka-server-listener-replication-plain-metrics.txt=${tmp}/kafka-server-listener-replication-plain-metrics.txt" \
                "kafka-server-listener-external-plain-metrics.txt=${tmp}/kafka-server-listener-external-plain-metrics.txt" || rc=1
            cfo_secret_apply "${ns}" "${CFO_SASL_CLIENT_SECRET}" "${labels[@]}" -- "plain.txt=${tmp}/plain.txt" || rc=1
        fi
    } always {
        rm -rf "${tmp}"
    }
    (( rc == 0 )) && print -r -- "[INFO] CFK SASL secrets ${CFO_SASL_SERVER_SECRET}, ${CFO_SASL_CLIENT_SECRET} derived from ${src}."
    return "${rc}"
}

# cfo_ensure_license_secret <ns> - secret confluent-license (license.txt) from
# CONFLUENT_LICENSE_KEY; sets and exports CFO_LICENSE_PRESENT.
cfo_ensure_license_secret() {
    local ns="$1"
    if [[ -z "${CONFLUENT_LICENSE_KEY:-}" ]]; then
        if oc get secret "${CFO_LICENSE_SECRET}" -n "${ns}" -o name >/dev/null 2>&1; then
            print -r -- "[INFO] No CONFLUENT_LICENSE_KEY; using the existing secret ${CFO_LICENSE_SECRET} in ${ns}."
            export CFO_LICENSE_PRESENT=true
        else
            cfo_license_warning
            export CFO_LICENSE_PRESENT=false
        fi
        return 0
    fi
    export CFO_LICENSE_PRESENT=true
    _cfo_owner; local owner="${REPLY}" tmp rc=0
    tmp="$(_cfo_mktemp)" || return 1
    {
        ( umask 077; print -rn -- "${CONFLUENT_LICENSE_KEY}" > "${tmp}/license.txt" ) || rc=1
        (( rc == 0 )) && cfo_secret_apply "${ns}" "${CFO_LICENSE_SECRET}" "${CFO_LABEL_PART_OF}" \
            "${CFO_LABEL_OWNER_KEY}=${owner}" -- "license.txt=${tmp}/license.txt" || rc=1
    } always {
        rm -rf "${tmp}"
    }
    return "${rc}"
}

# =============================================================================
# Render, apply, wait
# =============================================================================
_cfo_secret_present() {   # <ns> <name>
    [[ -n "$2" ]] && oc get secret "$2" -n "$1" -o name >/dev/null 2>&1 && print -r -- true || print -r -- false
}

# cfo_live_json <set> <file> [<args-json>] - the renderer's "live" object from
# the cluster and the state files (contract 4.2).
cfo_live_json() {
    local set="$1" file="$2" ns="${PROJECT_CONFLUENT_SERVER:-}" tmp
    local -a args=(--out "${file}")
    tmp="$(_cfo_mktemp)" || return 1
    {
        local domain; domain="$(cfo_route_domain)"
        [[ -n "${domain}" ]] && args+=(--route-domain "${domain}")
        if [[ "${set}" == (platform|repo|topic|connector|connect-plugins) ]]; then
            local lic="${CFO_LICENSE_PRESENT:-}"
            [[ -n "${lic}" ]] || lic="$(_cfo_secret_present "${ns}" "${CFO_LICENSE_SECRET}")"
            args+=(--license-present "${lic}"
                   --pull-secret-present "$(_cfo_secret_present "${ns}" "${CONFLUENT_PULL_SECRET:-}")"
                   --internal-tls-present "$(_cfo_secret_present "${ns}" "${CONFLUENT_INTERNAL_TLS_SECRET:-confluent-kafka-internal-tls}")"
                   --external-tls-present "$(_cfo_secret_present "${ns}" "${CONFLUENT_EXTERNAL_TLS_SECRET:-confluent-kafka-tls}")"
                   --ca-pair-present "$(_cfo_secret_present "${ns}" "${CFO_CA_PAIR_SECRET}")")
            [[ -f "${CONFLUENT_CONNECT_STATE_FILE}" ]] && args+=(--connect-state "${CONFLUENT_CONNECT_STATE_FILE}")
            _cfo_choice "${CONFLUENT_OPERATOR_IMAGE_SOURCE:-}" tags tags csv
            if [[ "${REPLY}" == csv ]]; then
                local csvname
                csvname="$(oc get subscriptions.operators.coreos.com -n "${ns}" \
                    -o jsonpath='{range .items[?(@.spec.name=="confluent-for-kubernetes")]}{.status.installedCSV}{end}' 2>/dev/null || true)"
                if [[ -n "${csvname}" ]]; then
                    oc get clusterserviceversions.operators.coreos.com "${csvname}" -n "${ns}" -o json > "${tmp}/csv.json" 2>/dev/null \
                        || print -r -- '{}' > "${tmp}/csv.json"
                    _cfo_olm_py related-images --csv "${tmp}/csv.json" > "${tmp}/related.json" || print -r -- '{}' > "${tmp}/related.json"
                    args+=(--related-images "${tmp}/related.json")
                else
                    print -r -- "[WARN] CONFLUENT_OPERATOR_IMAGE_SOURCE=csv but no CFK CSV is installed in ${ns}; image vars must be set." >&2
                fi
            fi
        fi
        if [[ "${set}" == (flink|flink-app) ]]; then
            local fdef="${CF_FLINK_RENDER_ROOT}/environment-defaults.json"
            [[ -f "${fdef}" ]] && args+=(--flink-defaults "${fdef}")
            local cfkns="${FLINK_CFK_NAMESPACE:-${PROJECT_CONFLUENT_FLINK:-}}"
            if [[ -n "${FLINK_ENVIRONMENT:-}" && -n "${cfkns}" ]]; then
                oc get flinkenvironments.platform.confluent.io "${FLINK_ENVIRONMENT}" -n "${cfkns}" -o json \
                    > "${tmp}/env.json" 2>/dev/null || print -r -- '{}' > "${tmp}/env.json"
                args+=(--flink-env "${tmp}/env.json")
            fi
        fi
        _cfo_olm_py live-json "${args[@]}"
    } always {
        rm -rf "${tmp}"
    }
}

# cfo_render <set> <out-root> [<args-json>] - renders one set with
# confluent_cfk_render.py; sets CFO_MANIFEST=<out-root>/<set>/manifest.json.
cfo_render() {
    local set="$1" root="$2" argsjson="${3:-}" tmp rc=0
    local render="${_CFO_DIR}/confluent_cfk_render.py"
    CFO_MANIFEST=""
    [[ -f "${render}" ]] || { print -r -- "[ERROR] ${render} is missing." >&2; return 1; }
    tmp="$(_cfo_mktemp)" || return 1
    {
        cfo_live_json "${set}" "${tmp}/live.json" || return 1
        local names
        names="$(cfo_python "${render}" list-inputs)" || return 1
        _cfo_with_vars ${(f)names} CFO_OWNER_ID -- cfo_python "${render}" input-from-env --live "${tmp}/live.json" \
            > "${tmp}/input.json" || return 1
        local -a extra=()
        if [[ -n "${argsjson}" ]]; then
            print -r -- "${argsjson}" > "${tmp}/args.json"
            extra=(--args "${tmp}/args.json")
        fi
        cfo_python "${render}" render --set "${set}" --out-dir "${root}" "${extra[@]}" < "${tmp}/input.json" \
            > "${tmp}/manifest.json" || rc=1
    } always {
        rm -rf "${tmp}"
    }
    (( rc == 0 )) || { print -r -- "[ERROR] Rendering set ${set} failed (see the [ERROR] lines above)." >&2; return 1; }
    CFO_MANIFEST="${root}/${set}/manifest.json"
    return 0
}

# cfo_apply_manifest <manifest> [<stage>] - applies the set's files in order;
# stops at the first failure (no wait afterwards).
cfo_apply_manifest() {
    local manifest="$1" stage="${2:-}" root="${1:h:h}" out line i=0
    local -a st=()
    [[ -n "${stage}" ]] && st=(--stage "${stage}")
    out="$(_cfo_olm_py manifest-files --manifest "${manifest}" "${st[@]}")" || return 1
    local -a lines=("${(@f)out}")
    [[ -z "${out}" ]] && lines=()
    local n=${#lines}
    for line in "${lines[@]}"; do
        local -a f=("${(@s:	:)line}")
        (( i += 1 ))
        print -r -- "[${i}/${n}] apply ${f[2]}/${f[3]}"
        _cfo_apply_file "${root}/${f[1]}" || {
            print -r -- "[ERROR] apply of ${f[2]}/${f[3]} failed - stopping (nothing waited for)." >&2
            return 1
        }
    done
    return 0
}

# cfo_wait_crs <ns> <timeout> <kind>/<name>... - every CR RUNNING with its
# replicas ready; fails fast on FAILED/ERROR or pods that cannot be created (V1).
cfo_wait_crs() {
    local ns="$1" t="$2" e=0
    shift 2
    local -a crs=("$@")
    local -A fc_first done_cr
    local n=${#crs} i cr kind name res st phase ready want msg
    while true; do
        local all=true
        i=0
        for cr in "${crs[@]}"; do
            (( i += 1 ))
            kind="${cr%%/*}" name="${cr#*/}"
            if [[ -n "${done_cr[$cr]:-}" ]]; then
                continue
            fi
            res="$(cfo_resource "${kind}")"
            st="$(oc get "${res}" "${name}" -n "${ns}" \
                -o jsonpath='{.status.phase}|{.status.readyReplicas}|{.status.replicas}|{.spec.replicas}' 2>/dev/null || true)"
            local -a p=("${(@s:|:)st}")
            phase="${p[1]:-}" ready="${p[2]:-0}" want="${p[3]:-${p[4]:-}}"
            print -r -- "  [${i}/${n}] ${kind}/${name}: phase=${phase:-none} ready=${ready:-0}/${want:-?} [${e}s/${t}s]"
            if [[ "${(U)phase}" == (FAILED|ERROR) ]]; then
                print -r -- "[ERROR] ${kind}/${name} is ${phase}:" >&2
                oc get "${res}" "${name}" -n "${ns}" \
                    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' >&2 2>/dev/null || true
                return 1
            fi
            if [[ "${(U)phase}" == RUNNING && ( -z "${want}" || "${ready:-0}" == "${want}" ) ]]; then
                done_cr[$cr]=1
                continue
            fi
            all=false
            msg="$(oc get events -n "${ns}" --field-selector "involvedObject.kind=StatefulSet,involvedObject.name=${name},reason=FailedCreate" \
                -o jsonpath='{.items[-1:].message}' 2>/dev/null || true)"
            if [[ -n "${msg}" ]]; then
                [[ -n "${fc_first[$cr]:-}" ]] || fc_first[$cr]="${e}"
                if (( e - fc_first[$cr] >= 120 )); then
                    print -r -- "[ERROR] ${kind}/${name}: StatefulSet ${name} cannot create pods for $(( e - fc_first[$cr] ))s: ${msg}" >&2
                    return 1
                fi
            fi
        done
        ${all} && return 0
        if (( e >= t )); then
            print -r -- "[ERROR] Not ready after ${t}s:" >&2
            for cr in "${crs[@]}"; do
                [[ -n "${done_cr[$cr]:-}" ]] && continue
                oc describe "$(cfo_resource "${cr%%/*}")" "${cr#*/}" -n "${ns}" 2>/dev/null | tail -n 20 >&2 || true
            done
            return 1
        fi
        sleep "${CFO_POLL_INTERVAL}"
        e=$(( e + CFO_POLL_INTERVAL ))
    done
}

# cfo_wait_roll <ns> <kind>/<name> <timeout> - waits for the rolling condition to
# turn False (V25, item 9), then for the CR to be ready. Right after an apply the
# condition can still be the False of the previous state, so False counts only
# once CFK has seen the applied spec (status.observedGeneration >=
# metadata.generation) or after rolling=True was seen. Fallback: 60 s without
# either (a change that needs no roll, or a CR without observedGeneration).
cfo_wait_roll() {
    local ns="$1" cr="$2" t="$3" e=0 s seen=false raw gen obs
    local res="$(cfo_resource "${cr%%/*}")" name="${cr#*/}"
    while true; do
        raw="$(oc get "${res}" "${name}" -n "${ns}" \
            -o jsonpath='{.metadata.generation}|{.status.observedGeneration}|{.status.conditions[?(@.type=="platform.confluent.io/rolling")].status}' 2>/dev/null || true)"
        if [[ "${raw}" == *"|"*"|"* ]]; then
            gen="${raw%%|*}"; raw="${raw#*|}"; obs="${raw%%|*}"; s="${raw#*|}"
        else
            gen="" obs="" s=""
        fi
        print -r -- "  [1/1] ${cr}: rolling=${s:-unknown} observedGeneration=${obs:-?}/${gen:-?} [${e}s/${t}s]"
        [[ "${s}" == True ]] && seen=true
        if [[ "${s}" == False ]]; then
            ${seen} && break
            [[ "${gen}" == <-> && "${obs}" == <-> ]] && (( obs >= gen )) && break
        fi
        # Neither the roll nor the applied generation showed up within a minute: a spec change that needs
        # no roll never shows the condition, and a CR may not report observedGeneration.
        if ! ${seen} && [[ "${s}" != True ]] && (( e >= 60 )); then
            print -r -- "  [1/1] ${cr}: no roll seen in 60s (rolling=${s:-unknown}) - continuing"
            break
        fi
        if (( e >= t )); then
            print -r -- "[ERROR] ${cr} still rolling after ${t}s." >&2
            return 1
        fi
        sleep "${CFO_POLL_INTERVAL}"
        e=$(( e + CFO_POLL_INTERVAL ))
    done
    cfo_wait_crs "${ns}" "$(( t > e ? t - e : CFO_POLL_INTERVAL ))" "${cr}"
}

# cfo_wait_status_field <ns> <kind>/<name> <jsonpath> <value> <timeout>
cfo_wait_status_field() {
    local ns="$1" cr="$2" jp="$3" want="$4" t="$5" e=0 v
    local res="$(cfo_resource "${cr%%/*}")" name="${cr#*/}"
    while true; do
        v="$(oc get "${res}" "${name}" -n "${ns}" -o jsonpath="${jp}" 2>/dev/null || true)"
        print -r -- "  [1/1] ${cr}: ${jp}=${v:-none} [${e}s/${t}s]"
        [[ "${v}" == "${want}" ]] && return 0
        # CFK Flink CRs report CMF's verdict in .status.cmfSync: a Failed sync never recovers by waiting
        # (seen live 2026-11-18: a rejected FlinkApplication payload polled to the 300 s timeout).
        if [[ "${cr%%/*}" == Flink(Environment|Application) ]]; then
            local sync
            sync="$(oc get "${res}" "${name}" -n "${ns}" -o jsonpath='{.status.cmfSync.status}' 2>/dev/null || true)"
            if [[ "${sync}" == Failed ]]; then
                print -r -- "[ERROR] ${cr}: CMF rejected it (cmfSync Failed): $(oc get "${res}" "${name}" -n "${ns}" \
                    -o jsonpath='{.status.cmfSync.errorMessage}' 2>/dev/null || true)" >&2
                return 1
            fi
        fi
        if (( e >= t )); then
            print -r -- "[ERROR] ${cr}: ${jp} is '${v}', not '${want}', after ${t}s." >&2
            return 1
        fi
        sleep "${CFO_POLL_INTERVAL}"
        e=$(( e + CFO_POLL_INTERVAL ))
    done
}

# _cfo_wait_gone <ns> <res> <name> <timeout> <i> <n> <label> - progress until the object is gone.
_cfo_wait_gone() {
    local ns="$1" res="$2" name="$3" t="$4" i="$5" n="$6" label="$7" e=0
    while oc get "${res}" "${name}" -n "${ns}" -o name >/dev/null 2>&1; do
        print -r -- "  [${i}/${n}] ${label} deleting [${e}s/${t}s]"
        (( e >= t )) && return 1
        sleep "${CFO_POLL_INTERVAL}"
        e=$(( e + CFO_POLL_INTERVAL ))
    done
    print -r -- "  [${i}/${n}] ${label} deleted"
    return 0
}

# cfo_delete_disabled <manifest> <ns> - deletes the disabled components' CRs we own.
cfo_delete_disabled() {
    local manifest="$1" ns="$2" out line i=0
    _cfo_owner; local owner="${REPLY}"
    _cfo_int "${CONFLUENT_OPERATOR_COMPONENT_TIMEOUT:-}" 600; local t="${REPLY}"
    out="$(_cfo_olm_py manifest-disabled --manifest "${manifest}")" || return 1
    local -a lines=("${(@f)out}")
    [[ -z "${out}" ]] && return 0
    local n=${#lines}
    for line in "${lines[@]}"; do
        local -a f=("${(@s:	:)line}")
        (( i += 1 ))
        local res="$(cfo_resource "${f[1]}")" label=""
        label="$(oc get "${res}" "${f[2]}" -n "${ns}" -o "jsonpath={.metadata.labels.confluent\.ibm-scripts/installed-by}|{.metadata.name}" 2>/dev/null || true)"
        [[ -z "${label#*|}" ]] && continue
        if [[ "${label%%|*}" != "${owner}" ]]; then
            print -r -- "[INFO] ${f[1]}/${f[2]} is disabled but not ours - leaving it."
            continue
        fi
        if [[ "${DRY_RUN:-false}" == true ]]; then
            print -r -- "  [DRY-RUN] oc delete ${res} ${f[2]} -n ${ns}"
            continue
        fi
        oc delete "${res}" "${f[2]}" -n "${ns}" --wait=false >/dev/null || return 1
        _cfo_wait_gone "${ns}" "${res}" "${f[2]}" "${t}" "${i}" "${n}" "${f[1]}/${f[2]}" \
            || { print -r -- "[ERROR] ${f[1]}/${f[2]} not gone after ${t}s." >&2; return 1; }
    done
    return 0
}

# cfo_apply_front_proxy <ns> <basic|openshift|none> - the C3 front proxy (O13):
# secrets, Deployment + Service control-center-auth, Route control-center.
# <mode> is what the caller asks the renderer for; the steps below follow the
# mode the rendered manifest actually holds (the renderer turns it into none
# when Control Center is off), so a basic request never writes a gateway secret
# from an nginx.conf that was not rendered.
cfo_apply_front_proxy() {
    local ns="$1" mode="$2" auth="${CONFLUENT_AUTH_SECRET:-confluent-auth}"
    [[ "${mode}" == (basic|openshift|none) ]] \
        || { print -r -- "[ERROR] cfo_apply_front_proxy: mode must be basic, openshift or none" >&2; return 1; }
    _cfo_owner; local owner="${REPLY}"
    _cfo_render_root; local root="${REPLY}/cfk"
    # Digest of the credentials the proxy secret carries (base64 data, through a pipe, never printed): the
    # renderer folds it into the Deployment's checksum annotation, so a changed password or cookie key rolls it.
    local digest="" jp="" src="${auth}"
    case "${mode}" in
        basic)     jp='{.data.username}:{.data.bcrypt}' ;;
        openshift) jp='{.data.cookie-secret}'; src="${auth}-oauth" ;;
    esac
    if [[ -n "${jp}" ]]; then
        digest="$( { oc get secret "${src}" -n "${ns}" -o jsonpath="${jp}" 2>/dev/null || true; } \
            | cfo_python -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" || digest=""
    fi
    cfo_render repo "${root}" "{\"front_proxy_mode\": \"${mode}\", \"front_proxy_secret_digest\": \"${digest}\"}" || return 1
    local manifest="${CFO_MANIFEST}" rendered
    rendered="$(_cfo_olm_py front-proxy-mode --manifest "${manifest}" --name "${CFO_FRONT_PROXY}")" || return 1
    if [[ "${rendered}" != "${mode}" ]]; then
        print -r -- "[INFO] Front proxy: ${mode} requested, the rendered repo set holds ${rendered} - applying ${rendered}."
        mode="${rendered}"
    fi
    case "${mode}" in
        basic)
            cf_dry_run --ignore-errors oc delete secret "${auth}-oauth" -n "${ns}" --ignore-not-found
            local tmp rc=0
            tmp="$(_cfo_mktemp)" || return 1
            {
                if [[ "${DRY_RUN:-false}" != true ]]; then
                    (
                        umask 077
                        local u b
                        u="$(oc get secret "${auth}" -n "${ns}" -o jsonpath='{.data.username}' 2>/dev/null | base64 --decode)"
                        b="$(oc get secret "${auth}" -n "${ns}" -o jsonpath='{.data.bcrypt}' 2>/dev/null | base64 --decode)"
                        [[ -n "${u}" && -n "${b}" ]] || { print -r -- "[ERROR] Secret ${auth} in ${ns} lacks username/bcrypt (run 1.0_confluent_prep.sh)." >&2; exit 1; }
                        print -r -- "${u}:${b}" > "${tmp}/htpasswd"
                    ) || rc=1
                fi
                (( rc == 0 )) && cfo_secret_apply "${ns}" "${auth}-gateway" "${CFO_LABEL_PART_OF}" "${CFO_LABEL_OWNER_KEY}=${owner}" -- \
                    "htpasswd=${tmp}/htpasswd" "nginx.conf=${root}/repo/control-center-auth-nginx.conf" || rc=1
            } always {
                rm -rf "${tmp}"
            }
            (( rc == 0 )) || return 1 ;;
        openshift)
            cf_dry_run --ignore-errors oc delete secret "${auth}-gateway" -n "${ns}" --ignore-not-found ;;
        none)
            cf_dry_run --ignore-errors oc delete deployment "${CFO_FRONT_PROXY}" -n "${ns}" --ignore-not-found
            cf_dry_run --ignore-errors oc delete service "${CFO_FRONT_PROXY}" -n "${ns}" --ignore-not-found ;;
        *) print -r -- "[ERROR] cfo_apply_front_proxy: mode must be basic, openshift or none" >&2; return 1 ;;
    esac
    local out line i=0
    out="$(_cfo_olm_py manifest-files --manifest "${manifest}")" || return 1
    local -a pick=()
    for line in "${(@f)out}"; do
        local -a f=("${(@s:	:)line}")
        [[ "${f[3]}" == ("${CFO_FRONT_PROXY}"|control-center) && "${f[2]}" == (Deployment|Service|Route) ]] && pick+=("${line}")
    done
    for line in "${pick[@]}"; do
        local -a f=("${(@s:	:)line}")
        (( i += 1 ))
        print -r -- "[${i}/${#pick}] apply ${f[2]}/${f[3]}"
        _cfo_apply_file "${manifest:h:h}/${f[1]}" || return 1
    done
    if [[ "${mode}" != none && "${DRY_RUN:-false}" != true ]]; then
        _cfo_int "${CONFLUENT_OPERATOR_COMPONENT_TIMEOUT:-}" 600
        _cfo_wait_deploy "${ns}" "${CFO_FRONT_PROXY}" "${REPLY}" || return 1
    fi
    return 0
}

# =============================================================================
# Endpoint resolvers (operator mode)
# =============================================================================
cf_kafka_present() {   # <ns>
    [[ -n "$(oc get statefulset broker -n "$1" -o name --ignore-not-found 2>/dev/null)" ]] && return 0
    [[ -n "$(oc get kafkas.platform.confluent.io "${CF_KAFKA_CR}" -n "$1" -o name --ignore-not-found 2>/dev/null)" ]]
}

cf_bootstrap_internal() {   # <ns>
    local ep
    ep="$(oc get kafkas.platform.confluent.io "${CF_KAFKA_CR}" -n "$1" \
        -o jsonpath='{.status.listeners.internal.internalEndpoint}' 2>/dev/null || true)"
    ep="${ep#*://}"
    print -r -- "${ep:-kafka.$1.svc.cluster.local:9071}"
}

cf_external_bootstrap() {   # <ns>
    local host
    host="$(oc get route kafka-bootstrap -n "$1" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "${host}" ]] && print -r -- "${host}:443"
    return 0
}

cf_external_broker_hosts() {   # <ns>
    local out line
    local -a hosts=()
    out="$(oc get routes -n "$1" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.host}{"\n"}{end}' 2>/dev/null || true)"
    for line in ${(f)out}; do
        [[ "${line%% *}" == kafka-<-> ]] && hosts+=("${line%% *}|${line#* }:443")
    done
    # order by broker number
    hosts=(${(on)hosts})
    print -r -- "${(j:,:)${hosts[@]#*|}}"
}

cf_component_url() {   # <ns> <cr-name>
    local ns="$1" cr="$2" kind port out
    case "${cr}" in
        "${CF_SR_CR}")      kind=SchemaRegistry port=8081 ;;
        "${CF_CONNECT_CR}") kind=Connect port=8083 ;;
        "${CF_KSQLDB_CR}")  kind=KsqlDB port=8088 ;;
        "${CF_KRP_CR}")     kind=KafkaRestProxy port=8082 ;;
        "${CF_C3_CR}")      kind=ControlCenter port=9021 ;;
        *) return 0 ;;
    esac
    out="$(oc get "$(cfo_resource "${kind}")" "${cr}" -n "${ns}" \
        -o jsonpath='{.metadata.name}|{.status.restConfig.internalEndpoint}' 2>/dev/null || true)"
    [[ -n "${out%%|*}" ]] || return 0
    local ep="${out#*|}"
    print -r -- "${ep:-http://${cr}.${ns}.svc.cluster.local:${port}}"
}

cf_deployed_version() {   # <ns>
    local img
    img="$(oc get kafkas.platform.confluent.io "${CF_KAFKA_CR}" -n "$1" -o jsonpath='{.spec.image.application}' 2>/dev/null || true)"
    if [[ -z "${img}" ]]; then
        print -r -- "${CONFLUENT_VERSION:-}"
    elif [[ "${img}" == *@* ]]; then
        print -r -- "[WARN] Kafka image is pinned by digest (${img}); reporting CONFLUENT_VERSION=${CONFLUENT_VERSION:-}." >&2
        print -r -- "${CONFLUENT_VERSION:-}"
    else
        print -r -- "${img##*:}"
    fi
}

cf_running_cluster_id() {   # <ns>
    local id
    id="$(oc get kafkas.platform.confluent.io "${CF_KAFKA_CR}" -n "$1" -o jsonpath='{.status.clusterID}' 2>/dev/null || true)"
    [[ -n "${id}" ]] || id="$(oc get kraftcontrollers.platform.confluent.io "${CF_KRAFT_CR}" -n "$1" -o jsonpath='{.status.clusterID}' 2>/dev/null || true)"
    print -r -- "${id:-${CONFLUENT_CLUSTER_ID:-}}"
}

# cf_live_security <ns> - "<internal-protocol> <internal-mechanism|-> <internal-mechs> <external-mechs|->"
cf_live_security() {
    local ns="$1" st auth tls ext overrides line proto mech ilist elist
    st="$(oc get kafkas.platform.confluent.io "${CF_KAFKA_CR}" -n "${ns}" \
        -o jsonpath='{.spec.listeners.internal.authentication.type}|{.spec.listeners.internal.tls.enabled}|{.spec.listeners.external.externalAccess.type}' 2>/dev/null || true)"
    local -a p=("${(@s:|:)st}")
    auth="${p[1]:-}" tls="${p[2]:-}" ext="${p[3]:-}"
    overrides="$(oc get kafkas.platform.confluent.io "${CF_KAFKA_CR}" -n "${ns}" \
        -o jsonpath='{range .spec.configOverrides.server[*]}{@}{"\n"}{end}' 2>/dev/null || true)"
    _cfo_override_mechs() {   # <listener>
        local l="$1" ln m
        local -a out=(PLAIN)
        for ln in ${(f)overrides}; do
            if [[ "${(L)ln}" == "listener.name.${l}.sasl.enabled.mechanisms="* ]]; then
                for m in ${(s:,:)${ln#*=}}; do
                    m="${(U)m// /}"
                    [[ "${m}" == SCRAM-* && ${out[(Ie)$m]} -eq 0 ]] && out+=("${m}")
                done
            fi
        done
        REPLY="${(j:,:)out}"
    }
    if [[ "${auth}" == plain ]]; then
        if [[ "${tls}" == true ]]; then proto=SASL_SSL; else proto=SASL_PLAINTEXT; fi
        mech=PLAIN
        _cfo_override_mechs internal; ilist="${REPLY}"
    else
        proto=PLAINTEXT mech=- ilist=-
    fi
    if [[ -n "${ext}" && "${auth}" == plain ]]; then
        _cfo_override_mechs external; elist="${REPLY}"
    else
        elist=-
    fi
    unfunction _cfo_override_mechs
    print -r -- "${proto} ${mech} ${ilist} ${elist}"
}

cf_ca_pem() {   # <ns> <internal|external>
    local ns="$1" which="$2" secret key=ca.crt
    if [[ "${which}" == external ]]; then
        secret="${CONFLUENT_EXTERNAL_TLS_SECRET:-confluent-kafka-tls}"
    elif [[ "$(cfo_tls_source)" == cfk ]]; then
        secret="${CFO_CA_PAIR_SECRET}" key=tls.crt
    else
        secret="${CONFLUENT_INTERNAL_TLS_SECRET:-confluent-kafka-internal-tls}"
    fi
    oc get secret "${secret}" -n "${ns}" -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null | base64 --decode 2>/dev/null || true
}

cf_kafka_app_labels() { print -r -- "kafka schema-registry"; }

cf_kafka_txn_max() {   # <ns>
    local line
    for line in ${(f)"$(oc get kafkas.platform.confluent.io "${CF_KAFKA_CR}" -n "$1" \
            -o jsonpath='{range .spec.configOverrides.server[*]}{@}{"\n"}{end}' 2>/dev/null || true)"}; do
        [[ "${line}" == transaction.max.timeout.ms=* ]] && { print -r -- "${line#*=}"; return 0; }
    done
    return 0
}

# =============================================================================
# Deletion
# =============================================================================
# cfo_list_crs <ns> - "<Kind>/<name> <owned:true|false>" for every CFK CR in <ns>.
cfo_list_crs() {
    local ns="$1" tmp
    _cfo_owner; local owner="${REPLY}"
    tmp="$(_cfo_mktemp)" || return 1
    {
        # Fail closed: a read error (not "no such kind") must not look like "no CRs" to a deleting caller.
        _cfo_json "${tmp}/cfk.json" get confluent -n "${ns}" \
            || { print -r -- "[ERROR] Cannot list the CFK CRs in ${ns} - nothing decided." >&2; return 1; }
        _cfo_json "${tmp}/usm.json" get usmagents.platform.confluent.io -n "${ns}" \
            || { print -r -- "[ERROR] Cannot list the USMAgent CRs in ${ns} - nothing decided." >&2; return 1; }
        _cfo_olm_py list-crs --owner "${owner}" --json "${tmp}/cfk.json" "${tmp}/usm.json"
    } always {
        rm -rf "${tmp}"
    }
}

# cfo_delete_order - the three delete groups, in Confluent's documented order.
cfo_delete_order() {
    print -r -- "ClusterLink ConfluentRolebinding Connector KafkaTopic SchemaExporter Schema KafkaRestClass"
    print -r -- "Connect ControlCenter KafkaRestProxy KsqlDB SchemaRegistry USMAgent"
    print -r -- "Kafka KRaftController"
}

# cfo_delete_group <ns> <timeout> [--force-finalizers] [--delete-data] <Kind>... - deletes our CRs of those
# kinds (never --force) and waits until they are gone. Data (plan 15.14 item 1): CFK deletes a stateful CR's
# PVCs with it, so before any delete the PVs behind the data PVCs of our Kafka, KRaftController, KsqlDB and
# ControlCenter CRs (incl. prometheus-data) get reclaim Retain + the retained-from label (cfo_retain_pvs);
# a failure there deletes nothing. --delete-data skips that (PVs go with the StorageClass's reclaim policy).
# The retained PV names are printed at the end and left in CFO_RETAINED_PVS.
cfo_delete_group() {
    local ns="$1" t="$2" force=false keep_data=true
    shift 2
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --force-finalizers) force=true ;;
            --delete-data)      keep_data=false ;;
            *) print -r -- "[ERROR] cfo_delete_group: unknown option '$1'" >&2; return 1 ;;
        esac
        shift
    done
    local -a kinds=("$@") targets=() stateful=()
    local line ref listing
    listing="$(cfo_list_crs "${ns}")" || return 1
    for line in ${(f)listing}; do
        ref="${line% *}"
        [[ "${line##* }" == true ]] || continue
        (( ${kinds[(Ie)${ref%%/*}]} )) || continue
        targets+=("${ref}")
        (( ${CFO_STATEFUL_KINDS[(Ie)${ref%%/*}]} )) && stateful+=("${ref}")
    done
    local n=${#targets} i=0 res name
    CFO_RETAINED_PVS=()
    (( n )) || return 0
    if ${keep_data} && (( ${#stateful} )); then
        cfo_retain_pvs "${ns}" "${stateful[@]}" \
            || { print -r -- "[ERROR] Could not retain the data PVs in ${ns} - no CR deleted (or use --delete-data)." >&2; return 1; }
    fi
    for ref in "${targets[@]}"; do
        res="$(cfo_resource "${ref%%/*}")" name="${ref#*/}"
        cf_dry_run oc delete "${res}" "${name}" -n "${ns}" --wait=false || return 1
    done
    if [[ "${DRY_RUN:-false}" != true ]]; then
        for ref in "${targets[@]}"; do
            (( i += 1 ))
            res="$(cfo_resource "${ref%%/*}")" name="${ref#*/}"
            if ! _cfo_wait_gone "${ns}" "${res}" "${name}" "${t}" "${i}" "${n}" "${ref}"; then
                if ${force}; then
                    oc patch "${res}" "${name}" -n "${ns}" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null || return 1
                    print -r -- "[WORKAROUND] finalizers removed from ${ref}"
                    _cfo_wait_gone "${ns}" "${res}" "${name}" 60 "${i}" "${n}" "${ref}" || return 1
                else
                    print -r -- "[ERROR] ${ref} not gone after ${t}s (re-run with --force-finalizers to remove its finalizers)." >&2
                    return 1
                fi
            fi
        done
    fi
    cfo_print_retained
    return 0
}

# cfo_retain_pvs <ns> <Kind>/<name>... - for every data PVC of these stateful CRs (V15 names: data0-<cr>-N,
# data-<cr>-N, prometheus-data-<cr>-N, alertmanager-data-<cr>-N), patch its PV to
# persistentVolumeReclaimPolicy Retain, label it confluent.ibm-scripts/retained-from=<ns>.<cr> and annotate
# the same key with "<ns>/<cr>". Appends "<pv> <ns>/<pvc> <Kind>/<name>" to CFO_RETAINED_PVS. Fails closed
# (status 1) when the PVCs cannot be read or a patch fails; an unbound PVC or a CR without PVCs is a WARN.
# Re-attaching a retained PV is not documented by Confluent: the PVs are a backup, recovery is manual.
cfo_retain_pvs() {
    local ns="$1" tmp out line
    shift
    (( $# )) || return 0
    local -a crarg=()
    local c
    for c in "$@"; do crarg+=(--cr "${c}"); done
    tmp="$(_cfo_mktemp)" || return 1
    {
        _cfo_json "${tmp}/pvcs.json" get pvc -n "${ns}" \
            || { print -r -- "[ERROR] Cannot read the PVCs in ${ns} - their PVs cannot be retained." >&2; return 1; }
        out="$(_cfo_olm_py retain-plan --pvcs "${tmp}/pvcs.json" "${crarg[@]}")" || return 1
    } always {
        rm -rf "${tmp}"
    }
    for line in ${(f)out}; do
        local -a f=("${(@s:	:)line}")
        local ref="${f[1]}" pvc="${f[2]:-}" pv="${f[3]:-}" cr="${f[1]#*/}"
        if [[ -z "${pvc}" ]]; then
            print -r -- "[WARN] ${ref}: no data PVC found in ${ns} - nothing to retain." >&2
            continue
        fi
        if [[ -z "${pv}" ]]; then
            print -r -- "[WARN] ${ref}: PVC ${pvc} is not bound to a PV - nothing to retain." >&2
            continue
        fi
        local lv="${ns}.${cr}"
        lv="${lv//[^A-Za-z0-9._-]/-}"; lv="${lv[1,63]}"
        while [[ -n "${lv}" && "${lv[-1]}" != [A-Za-z0-9] ]]; do lv="${lv[1,-2]}"; done
        local patch="{\"metadata\":{\"labels\":{\"${CFO_LABEL_RETAINED_KEY}\":\"${lv}\"},\"annotations\":{\"${CFO_LABEL_RETAINED_KEY}\":\"${ns}/${cr}\"}},\"spec\":{\"persistentVolumeReclaimPolicy\":\"Retain\"}}"
        if [[ "${DRY_RUN:-false}" == true ]]; then
            print -r -- "  [DRY-RUN] oc patch pv ${pv} --type=merge -p '${patch}'"
        else
            oc patch pv "${pv}" --type=merge -p "${patch}" >/dev/null \
                || { print -r -- "[ERROR] PV ${pv} (PVC ${ns}/${pvc}) could not be set to Retain." >&2; return 1; }
            print -r -- "[INFO] PV ${pv} (PVC ${ns}/${pvc}, ${ref}) set to reclaim Retain."
        fi
        CFO_RETAINED_PVS+=("${pv} ${ns}/${pvc} ${ref}")
    done
    return 0
}

# cfo_print_retained - the PVs cfo_retain_pvs kept in this run (nothing when none).
cfo_print_retained() {
    (( ${#CFO_RETAINED_PVS[@]} )) || return 0
    local row
    local what="Data kept"
    [[ "${DRY_RUN:-false}" == true ]] && what="Data that would be kept"
    print -r -- "[INFO] ${what}: ${#CFO_RETAINED_PVS[@]} PV(s) with reclaim Retain, label ${CFO_LABEL_RETAINED_KEY}=<ns>.<cr>:"
    for row in "${CFO_RETAINED_PVS[@]}"; do
        local -a f=("${(@s: :)row}")
        print -r -- "         ${f[1]}  (was ${f[2]}, ${f[3]})"
    done
    print -r -- "[INFO] Re-attaching a retained PV is not documented by Confluent - the PVs are a backup; recovery is manual."
    print -r -- "[INFO] Remove them when no longer needed: oc delete pv -l ${CFO_LABEL_RETAINED_KEY}"
}

# cfo_reapply_platform <ns> - the x.1 (reinstall) path with KEEP_DATA (plan 15.14 item 1): re-render set
# platform and apply it stage by stage, so CFK reconciles the existing stateful CRs in place (their data
# stays, no PV handling), waiting after each stage (Kafka/KRaft: Kafka timeout, rolls via cfo_wait_roll;
# Connect: Connect timeout; others: component timeout); then removes disabled components we own.
# Secrets, TLS, the repo set and the front proxy are operator 1.1's job - x.1 re-runs 1.1 for those.
cfo_reapply_platform() {
    local ns="$1" stage out line
    _cfo_render_root; local root="${REPLY}/cfk"
    cfo_render platform "${root}" || return 1
    local manifest="${CFO_MANIFEST}"
    _cfo_int "${CONFLUENT_OPERATOR_KAFKA_TIMEOUT:-}" 900; local tk="${REPLY}"
    _cfo_int "${CONFLUENT_OPERATOR_CONNECT_TIMEOUT:-}" 900; local tc="${REPLY}"
    _cfo_int "${CONFLUENT_OPERATOR_COMPONENT_TIMEOUT:-}" 600; local to="${REPLY}"
    for stage in 1 2 3 4 5; do
        out="$(_cfo_olm_py manifest-files --manifest "${manifest}" --stage "${stage}")" || return 1
        [[ -z "${out}" ]] && continue
        local -a rolls=() fresh=() t_wait=()
        local tmax="${to}"
        for line in ${(f)out}; do
            local -a f=("${(@s:	:)line}")
            [[ "${f[5]:-}" == phase ]] || continue
            local ref="${f[2]}/${f[3]}" t="${to}"
            [[ "${f[2]}" == (Kafka|KRaftController) ]] && t="${tk}"
            [[ "${f[2]}" == Connect ]] && t="${tc}"
            (( t > tmax )) && tmax="${t}"
            if [[ "${f[2]}" == (Kafka|KRaftController) ]] \
                    && oc get "$(cfo_resource "${f[2]}")" "${f[3]}" -n "${ns}" -o name >/dev/null 2>&1; then
                rolls+=("${ref}") t_wait+=("${t}")
            else
                fresh+=("${ref}")
            fi
        done
        print -r -- "[INFO] stage ${stage}: apply"
        cfo_apply_manifest "${manifest}" "${stage}" || return 1
        [[ "${DRY_RUN:-false}" == true ]] && continue
        local k
        for (( k = 1; k <= ${#rolls}; k++ )); do
            cfo_wait_roll "${ns}" "${rolls[$k]}" "${t_wait[$k]}" || return 1
        done
        (( ${#fresh} )) && { cfo_wait_crs "${ns}" "${tmax}" "${fresh[@]}" || return 1; }
    done
    cfo_delete_disabled "${manifest}" "${ns}"
}

# cfo_flinkenv_delete <cfk-ns> <env-name> - plan 15.14 item 2 steps 3-5 (CMF_URL from cmf_connect; steps 1-2,
# FlinkApplications and CLI pools/catalogs/statements, are the caller's; CMFRestClass goes last, after this,
# with cfo_cmfrestclass_delete):
#   3. DELETE the environment through CMF REST (404 = already gone). CMF 2.5.0 answers 422 while the
#      environment catalog's default database still holds tables or views: report the catalog and its
#      databases (GET /environments/<env>/catalog) and stop - nothing is deleted on the cluster.
#   4. delete the FlinkEnvironment CR and wait FLINK_ENVIRONMENT_DELETE_WAIT s;
#   5. still present and CMF says 404: the documented removal (co-manage-flink-environments): annotate
#      platform.confluent.io/block-reconcile=true, delete --wait=false, clear the finalizers.
# The block-reconcile + finalizer step never runs unless CMF's delete succeeded or answered 404.
cfo_flinkenv_delete() {
    local ns="$1" env="$2" code res=flinkenvironments.platform.confluent.io tmp
    _cfo_int "${FLINK_ENVIRONMENT_DELETE_WAIT:-}" 60; local t="${REPLY}"
    if [[ "${DRY_RUN:-false}" == true ]]; then
        print -r -- "  [DRY-RUN] curl -X DELETE ${CMF_URL:-<cmf>}/cmf/api/v1/environments/${env}"
        print -r -- "  [DRY-RUN] oc delete ${res} ${env} -n ${ns} --wait=false   (wait ${t}s)"
        print -r -- "  [DRY-RUN] if still present and CMF answers 404: oc annotate ${res} ${env} -n ${ns} ${CFO_ANNOT_BLOCK_RECONCILE}=true --overwrite;" \
            "oc delete ${res} ${env} -n ${ns} --wait=false; oc patch ${res} ${env} -n ${ns} --type=merge -p '{\"metadata\":{\"finalizers\":[]}}'"
        return 0
    fi
    if [[ -z "${CMF_URL:-}" ]]; then
        print -r -- "[ERROR] cfo_flinkenv_delete: CMF_URL is not set (run cmf_connect first) - FlinkEnvironment/${env} kept." >&2
        return 1
    fi
    tmp="$(_cfo_mktemp)" || return 1
    {
        # CMF deletes compute pools and applications asynchronously (their FlinkDeployments have to go first),
        # so a DELETE right after removing them answers 422 "still has 1 compute pool" (seen in a live
        # uninstall test). While the 422 names pools or applications, retry until the wait runs out.
        local e=0
        while true; do
            code="$(curl -sk -o "${tmp}/body" -w '%{http_code}' -X DELETE "${CMF_URL}/cmf/api/v1/environments/${env}" 2>/dev/null || true)"
            [[ "${code}" == 422 ]] && grep -q -i -E 'compute pool|application' "${tmp}/body" 2>/dev/null && (( e < t )) || break
            print -r -- "  [1/1] CMF environment ${env}: still has compute pools/applications being removed [${e}s/${t}s]"
            sleep "${CFO_POLL_INTERVAL}"
            e=$(( e + CFO_POLL_INTERVAL ))
        done
        case "${code}" in
            200|202|204|404)
                print -r -- "[INFO] CMF environment ${env}: delete answered HTTP ${code}." ;;
            422)
                print -r -- "[ERROR] CMF refused to delete environment ${env} (HTTP 422):" >&2
                [[ -s "${tmp}/body" ]] && sed 's/^/[ERROR]   /' "${tmp}/body" >&2
                if grep -q -i -E 'compute pool|application' "${tmp}/body" 2>/dev/null; then
                    print -r -- "[ERROR] Compute pools or applications were still present after ${t}s - FlinkEnvironment/${env} kept." >&2
                    print -r -- "[ERROR] Check: confluent flink compute-pool list / application list --environment ${env}, then re-run." >&2
                    return 1
                fi
                print -r -- "[ERROR] CMF 2.5.0 keeps an environment while the default database of its catalog holds tables or views." >&2
                curl -sk -o "${tmp}/catalog.json" "${CMF_URL}/cmf/api/v1/environments/${env}/catalog" 2>/dev/null || true
                if [[ -s "${tmp}/catalog.json" ]]; then
                    print -r -- "[ERROR] Environment catalog (GET /cmf/api/v1/environments/${env}/catalog):" >&2
                    cfo_python -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    sys.exit(0)
meta = d.get("metadata") or {}
spec = d.get("spec") or {}
print("[ERROR]   catalog: %s" % (meta.get("name") or d.get("name") or "?"))
dbs = spec.get("databases") or d.get("databases") or []
for db in dbs:
    print("[ERROR]   database: %s" % (db.get("name") if isinstance(db, dict) else db))' "${tmp}/catalog.json" >&2 || true
                fi
                print -r -- "[ERROR] Drop those tables and views first (Flink SQL: SHOW TABLES / SHOW VIEWS, then DROP TABLE / DROP VIEW" >&2
                print -r -- "[ERROR] in the default database), then re-run. FlinkEnvironment/${env} kept." >&2
                return 1 ;;
            *)
                print -r -- "[ERROR] CMF environment ${env}: delete answered HTTP ${code:-none} - FlinkEnvironment/${env} kept." >&2
                return 1 ;;
        esac
    } always {
        rm -rf "${tmp}"
    }
    oc delete "${res}" "${env}" -n "${ns}" --wait=false --ignore-not-found >/dev/null || return 1
    _cfo_wait_gone "${ns}" "${res}" "${env}" "${t}" 1 1 "FlinkEnvironment/${env}" && return 0
    code="$(curl -sk -o /dev/null -w '%{http_code}' "${CMF_URL}/cmf/api/v1/environments/${env}" 2>/dev/null || true)"
    if [[ "${code}" != 404 ]]; then
        print -r -- "[ERROR] FlinkEnvironment/${env} still present and CMF still has the environment (HTTP ${code:-none})." >&2
        return 1
    fi
    print -r -- "[WORKAROUND] FlinkEnvironment/${env} still present after ${t}s although CMF deleted the environment (V34):" \
        "documented removal - ${CFO_ANNOT_BLOCK_RECONCILE}=true, delete --wait=false, clear finalizers"
    oc annotate "${res}" "${env}" -n "${ns}" "${CFO_ANNOT_BLOCK_RECONCILE}=true" --overwrite >/dev/null || return 1
    oc delete "${res}" "${env}" -n "${ns}" --wait=false --ignore-not-found >/dev/null || return 1
    oc patch "${res}" "${env}" -n "${ns}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null || return 1
    _cfo_wait_gone "${ns}" "${res}" "${env}" 60 1 1 "FlinkEnvironment/${env}"
}

# cfo_cmfrestclass_delete <cfk-ns> <name> - the CMFRestClass, deleted LAST in the Flink teardown (the
# FlinkEnvironment finalizer needs it to reach CMF; plan 15.14 item 2). Refuses while any FlinkEnvironment is
# left in <cfk-ns>, fails closed when that cannot be read, deletes only ours, waits until gone.
cfo_cmfrestclass_delete() {
    local ns="$1" name="${2:-${FLINK_CMF_RESTCLASS_NAME:-default}}" res=cmfrestclasses.platform.confluent.io left lbl
    _cfo_owner; local owner="${REPLY}"
    left="$(_cfo_read get flinkenvironments.platform.confluent.io -n "${ns}" -o name)" || {
        print -r -- "[ERROR] Cannot read the FlinkEnvironments in ${ns} - CMFRestClass/${name} kept." >&2; return 1; }
    if [[ -n "${left}" && "${DRY_RUN:-false}" != true ]]; then
        print -r -- "[ERROR] CMFRestClass/${name} kept: FlinkEnvironments still in ${ns} (${${(f)left}[*]})." >&2
        return 1
    fi
    lbl="$(_cfo_read get "${res}" "${name}" -n "${ns}" -o "jsonpath={.metadata.name}|{.metadata.labels.confluent\.ibm-scripts/installed-by}")" \
        || return 1
    [[ -z "${lbl%%|*}" ]] && { print -r -- "[INFO] No CMFRestClass/${name} in ${ns}."; return 0; }
    if [[ "${lbl#*|}" != "${owner}" ]]; then
        print -r -- "[INFO] CMFRestClass/${name} in ${ns} is not ours - leaving it."
        return 0
    fi
    cf_dry_run oc delete "${res}" "${name}" -n "${ns}" --wait=false || return 1
    [[ "${DRY_RUN:-false}" == true ]] && return 0
    _cfo_int "${CONFLUENT_OPERATOR_COMPONENT_TIMEOUT:-}" 600
    _cfo_wait_gone "${ns}" "${res}" "${name}" "${REPLY}" 1 1 "CMFRestClass/${name}" \
        || { print -r -- "[ERROR] CMFRestClass/${name} not gone after ${REPLY}s." >&2; return 1; }
}

# cfo_installplan_other_csvs <ns> <plan> <pkg> - V23 (plan 15.14 item 4): OLM resolves every Subscription
# of a namespace together, so an upgrade InstallPlan for <pkg> can carry the other package's CSV too, and
# approving it moves that operator as well. Sets CFO_PLAN_OTHERS (those CSVs) and prints a [WARN] naming
# them; x.7 warns (and asks, unless --yes) before approving such a plan. Status 1 when the plan cannot be read.
cfo_installplan_other_csvs() {
    local ns="$1" plan="$2" pkg="$3" tmp out
    typeset -ga CFO_PLAN_OTHERS
    CFO_PLAN_OTHERS=()
    tmp="$(_cfo_mktemp)" || return 1
    {
        oc get installplans.operators.coreos.com "${plan}" -n "${ns}" -o json > "${tmp}/plan.json" 2>/dev/null \
            || { print -r -- "[ERROR] InstallPlan ${plan} in ${ns} cannot be read." >&2; return 1; }
        out="$(_cfo_olm_py installplan-others --plan "${tmp}/plan.json" --package "${pkg}")" || return 1
    } always {
        rm -rf "${tmp}"
    }
    CFO_PLAN_OTHERS=(${(f)out})
    (( ${#CFO_PLAN_OTHERS} )) || return 0
    print -r -- "[WARN] InstallPlan ${plan} in ${ns} also carries ${(j:, :)CFO_PLAN_OTHERS} - approving it upgrades that operator too" \
        "(OLM puts every Subscription of a namespace into one InstallPlan, V23)." >&2
    return 0
}

# cfo_namespace_deletable <ns> - status 0 only when every Subscription and OperatorGroup in <ns> is ours.
# Fails closed: a read error (Forbidden, no connection, ...) means "not deletable" (_cfo_read).
cfo_namespace_deletable() {
    local ns="$1" line out
    _cfo_owner; local owner="${REPLY}"
    out="$(_cfo_read get subscriptions.operators.coreos.com,operatorgroups.operators.coreos.com -n "${ns}" \
            -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}|{.metadata.labels.confluent\.ibm-scripts/installed-by}{"\n"}{end}')" \
        || { print -r -- "[ERROR] Cannot read the Subscriptions / OperatorGroups in ${ns} - treating it as not deletable." >&2; return 1; }
    for line in ${(f)out}; do
        [[ -z "${line}" ]] && continue
        [[ "${line#*|}" == "${owner}" ]] || return 1
    done
    return 0
}

# cfo_remove_operator <ns> <pkg> - removes only our Subscription, its CSV, and
# our OperatorGroup when no other Subscription is left.
cfo_remove_operator() {
    local ns="$1" pkg="$2" sub csv line
    _cfo_owner; local owner="${REPLY}"
    _cfo_pkg_settings "${pkg}"
    for line in ${(f)"$(oc get subscriptions.operators.coreos.com -n "${ns}" -l "${CFO_LABEL_OWNER_KEY}=${owner}" \
            -o jsonpath='{range .items[*]}{.metadata.name}|{.spec.name}|{.status.installedCSV}{"\n"}{end}' 2>/dev/null || true)"}; do
        local -a f=("${(@s:|:)line}")
        [[ "${f[2]}" == "${_CFO_P_NAME}" ]] && { sub="${f[1]}" csv="${f[3]}"; break; }
    done
    if [[ -z "${sub}" ]]; then
        print -r -- "[INFO] No ${_CFO_P_NAME} Subscription of ours in ${ns} - nothing to remove."
        return 0
    fi
    if [[ "${pkg}" == "${CFO_PKG_CFK}" && "${DRY_RUN:-false}" != true ]]; then
        _cfo_int "${CONFLUENT_OPERATOR_COMPONENT_TIMEOUT:-}" 600; local t="${REPLY}" e=0 left
        while true; do
            # Fail closed: only "none left" (or no such kind) lets CFK go; a read error keeps it.
            left="$(_cfo_read get kraftcontrollers.platform.confluent.io -n "${ns}" -o name)" \
                || { print -r -- "[ERROR] Cannot read the KRaftController CRs in ${ns}; CFK kept." >&2; return 1; }
            [[ -z "${left}" ]] && break
            print -r -- "  [${e}s/${t}s] waiting for KRaftController CRs in ${ns} to go before removing CFK"
            (( e >= t )) && { print -r -- "[ERROR] KRaftController CRs still in ${ns}; CFK kept (it must finalize them)." >&2; return 1; }
            sleep "${CFO_POLL_INTERVAL}"
            e=$(( e + CFO_POLL_INTERVAL ))
        done
    fi
    cf_dry_run oc delete subscriptions.operators.coreos.com "${sub}" -n "${ns}" || return 1
    [[ -n "${csv}" ]] && { cf_dry_run oc delete clusterserviceversions.operators.coreos.com "${csv}" -n "${ns}" --ignore-not-found || return 1; }
    local others
    others="$(oc get subscriptions.operators.coreos.com -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
    others="$(print -r -- "${others}" | grep -vx -- "${sub}" || true)"
    if [[ -z "${others}" ]]; then
        local og
        for og in ${(f)"$(oc get operatorgroups.operators.coreos.com -n "${ns}" -l "${CFO_LABEL_OWNER_KEY}=${owner}" -o name 2>/dev/null || true)"}; do
            cf_dry_run oc delete "${og}" -n "${ns}" || return 1
        done
    fi
    print -r -- "[INFO] ${_CFO_P_NAME} removed from ${ns}."
}

# cfo_delete_crds <cfk|flink> - deletes the operator's CRDs, only when nothing
# uses them; typed confirmation from /dev/tty (never ASSUME_YES). Status 0/1/2.
cfo_delete_crds() {
    local which="$1" group pkg crd tmp line
    case "${which}" in
        cfk)   group=platform.confluent.io pkg="${CONFLUENT_OPERATOR_PACKAGE:-${CFO_PKG_CFK}}" ;;
        flink) group=flink.apache.org pkg="${FLINK_OLM_PACKAGE:-${CFO_PKG_FKO}}" ;;
        *) print -r -- "[ERROR] cfo_delete_crds: cfk or flink" >&2; return 1 ;;
    esac
    local -a crds=() users=()
    # Fail closed, and ask discovery for this API group only. A failed read used to count as "no CRDs" (and
    # return 0): on a cluster with many CRDs, `oc get crd` hit an API-server stream error (INTERNAL_ERROR)
    # in a live uninstall test, and --delete-crds then reported "No ... CRDs" with all of them still there.
    local listing="" attempt rc=1
    for attempt in 1 2 3; do
        listing="$(_cfo_read api-resources --api-group="${group}" -o name)" && { rc=0; break; }
        (( attempt < 3 )) && sleep "${CFO_POLL_INTERVAL:-5}"
    done
    if (( rc != 0 )); then
        print -r -- "[ERROR] Cannot list the ${group} API resources - CRDs kept." >&2
        return 1
    fi
    for crd in ${(f)listing}; do
        [[ "${crd}" == *."${group}" ]] && crds+=("${crd}")
    done
    if (( ${#crds} == 0 )); then
        print -r -- "[INFO] No ${group} CRDs on the cluster."
        return 0
    fi
    tmp="$(_cfo_mktemp)" || return 1
    {
        _cfo_json "${tmp}/csvs.json" get clusterserviceversions.operators.coreos.com -A \
            || { print -r -- "[ERROR] Cannot read the CSVs - CRDs kept." >&2; return 1; }
        users+=(${(f)"$(cfo_python -c 'import json,sys
for c in json.load(open(sys.argv[1])).get("items") or []:
    m = c.get("metadata") or {}
    if (c.get("status") or {}).get("reason") != "Copied" and m.get("name", "").startswith(sys.argv[2] + ".v"):
        print("ClusterServiceVersion/%s in %s" % (m.get("name"), m.get("namespace")))' "${tmp}/csvs.json" "${pkg}")"})
        if [[ "${which}" == flink ]] && command -v helm >/dev/null 2>&1; then
            helm list -A -o json > "${tmp}/helm.json" 2>/dev/null || print -r -- '[]' > "${tmp}/helm.json"
            for line in ${(f)"$(_cfo_olm_py guard-flink --helm "${tmp}/helm.json" 2>/dev/null)"}; do
                [[ "${line%% *}" == fko ]] && users+=("Helm release ${${line#* }%% *}")
            done
        fi
    } always {
        rm -rf "${tmp}"
    }
    for crd in "${crds[@]}"; do
        line="$(oc get "${crd}" -A -o name 2>/dev/null | head -1 || true)"
        [[ -n "${line}" ]] && users+=("${line} (and maybe more) of CRD ${crd}")
    done
    if (( ${#users} )); then
        cfo_banner "The ${group} CRDs are still in use - not deleting them" "${users[@]/#/found: }" \
            "remove those first (operator x.0 --remove-operator in every namespace that has one)"
        return "${CFO_RC_BLOCKED}"
    fi
    print -r -- "[INFO] CRDs to delete (${#crds}):"
    for crd in "${crds[@]}"; do print -r -- "  ${crd}"; done
    if [[ "${DRY_RUN:-false}" == true ]]; then
        for crd in "${crds[@]}"; do print -r -- "  [DRY-RUN] oc delete crd ${crd}"; done
        return 0
    fi
    # Yes/no from the terminal, never from --yes or an env var (O20). "No" is an answer, not an error: the
    # caller carries on, so the other CRD group can still be checked and offered.
    local answer=""
    if ! { print -n "Delete these ${#crds} ${group} CRDs? [y/N]: " > /dev/tty && read -r answer < /dev/tty; } 2>/dev/null; then
        cfo_banner "--delete-crds needs a terminal for the yes/no confirmation" "nothing deleted"
        return "${CFO_RC_BLOCKED}"
    fi
    if [[ "${answer:l}" != (y|yes) ]]; then
        print -r -- "[INFO] Answered no - the ${group} CRDs are kept."
        return 0
    fi
    for crd in "${crds[@]}"; do oc delete crd "${crd}" || return 1; done
}

# cfo_print_masked <file> - the file with password values replaced by ******** (O21).
# A masked value that goes on over more lines (a quote left open, or a trailing
# backslash) has its continuation lines dropped too, so no part of it prints.
cfo_print_masked() {
    awk -v sq="'" '
    # closes(s, q) - 1 when s holds the closing quote q (backslash escapes count inside "...")
    function closes(s, q,   t) {
        t = s
        if (q == "\"") gsub(/\\./, "", t)
        return index(t, q) > 0
    }
    {
        if (skip != "") {
            if (skip == "\\") { if ($0 !~ /\\$/) skip = "" }
            else if (closes($0, skip)) skip = ""
            next
        }
        if (match($0, /^(export[ \t]+)?[A-Za-z0-9_]*(_PASS|_PASSWORD|CONFLUENT_SASL_CLIENT_CREDS)=/)) {
            print substr($0, 1, RLENGTH) "\"********\""
            rest = substr($0, RLENGTH + 1)
            q = substr(rest, 1, 1)
            if (q == "\"" || q == sq) {
                if (!closes(substr(rest, 2), q)) skip = q
            } else if (rest ~ /\\$/) {
                skip = "\\"
            }
        } else {
            print
        }
    }' "$1"
}

# =============================================================================
# Shared by the two operators steps (1.0o platform / Flink)
# =============================================================================
# cfo_ensure_cfk_env <ns> - the spec.config.env entries the CFK Subscription
# watching <ns> must carry (ENABLE_CMF_DAY2_OPS, RESTRICT_*; contract 2.2).
# A Subscription that is not ours only ever gets ENABLE_CMF_DAY2_OPS. Status 0/1/2.
cfo_ensure_cfk_env() {
    local ns="$1" env_json
    local -a pairs=()
    env_json="$(cfo_subscription_env "${ns}" "${CFO_PKG_CFK}")" || return 1
    [[ "${env_json}" == "[]" || -z "${env_json}" ]] && return 0
    pairs=(${(f)"$(print -r -- "${env_json}" | cfo_python -c 'import json,sys
for e in json.load(sys.stdin):
    print("%s=%s" % (e["name"], e["value"]))')"})
    _cfo_pkg_settings "${CFO_PKG_CFK}"
    cfo_detect "${_CFO_P_NAME}" "${ns}" >/dev/null || return 1
    if [[ "${CFO_RESULT}" != reuse || -z "${CFO_SUB}" ]]; then
        if [[ "${DRY_RUN:-false}" == true ]]; then
            print -r -- "  [DRY-RUN] the new CFK Subscription for ${ns} carries ${pairs[*]}"
        else
            print -r -- "[WARN] No running CFK Subscription watches ${ns}; cannot set ${pairs[*]}." >&2
        fi
        return 0
    fi
    if [[ "${CFO_OWNED}" != true ]]; then
        pairs=(${(M)pairs:#ENABLE_CMF_DAY2_OPS=*})
        (( ${#pairs} )) || return 0
    fi
    cfo_ensure_subscription_env "${CFO_NS}" "${CFO_SUB}" "${pairs[@]}"
}

# cfo_print_summary - the CFO_SUMMARY_ROWS table (namespace, package, result, CSV, approval).
cfo_print_summary() {
    local row
    print -r -- ""
    print -r -- "Summary"
    printf '  %-28s %-26s %-28s %-38s %s\n' NAMESPACE PACKAGE RESULT CSV APPROVAL
    if (( ${#CFO_SUMMARY_ROWS} == 0 )); then
        print -r -- "  (nothing to do)"
        return 0
    fi
    for row in "${CFO_SUMMARY_ROWS[@]}"; do
        local -a f=("${(@s:|:)row}")
        printf '  %-28s %-26s %-28s %-38s %s\n' "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]:--}" "${f[5]:--}"
    done
}
