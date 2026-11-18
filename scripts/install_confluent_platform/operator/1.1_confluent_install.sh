#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_helpers.sh"   # loads common, confluent, operator_install, version_resolver helpers

# ==============================================================================
# Confluent Platform (operator mode) - install
# ------------------------------------------------------------------------------
# Runs the platform on Confluent for Kubernetes (CFK): renders the CFK custom
# resources (KRaftController, Kafka, SchemaRegistry, Connect, KsqlDB,
# KafkaRestProxy, ControlCenter) and the repo objects around them (front proxy,
# Routes, NetworkPolicies) with confluent_cfk_render.py, applies them in stages
# and waits for each stage with progress. CFK does the rolling: a re-run after a
# config change re-renders, re-applies and waits for the roll.
#
# 1.1_confluent_install.sh hands over to this script when CONFLUENT_DEPLOY_MODE
# is operator (or unset). The x.* utilities keep their "set a flag, re-run 1.1"
# pattern: they call 1.1_confluent_install.sh, which lands here.
#
# Steps:
#   [1/8] preflight (namespace, service account, the CFK operator)
#   [2/8] effective settings
#   [3/8] secrets (CFK SASL secrets, license, TLS, external certificate)
#   [4/8] render the CRs and the repo objects
#   [5/8] KRaftController + Kafka, wait until RUNNING (or until the roll ends)
#   [6/8] components (SR, Connect, ksqlDB, REST Proxy, Control Center), wait;
#         with MDS also the KafkaRestClass and the super-user ConfluentRolebinding
#   [7/8] front proxy, Routes, NetworkPolicies; SCRAM users; external client
#         files; MDS hand-off
#   [8/8] summary
#
# Run 1.0_confluent_prep.sh and the operators step (operator/1.0o_confluent_operators.sh) first.
#
# Options:
#   --dry-run              render and server-dry-run everything, change nothing
#   --tls-source repo|cfk  who makes the in-cluster certificates (this run only;
#                          default CONFLUENT_OPERATOR_TLS_SOURCE, else repo)
#   -h, --help             this text
#
# Exit status: 0 ok, 1 error, 2 blocked (the scripts-mode guard).
# ==============================================================================

usage() { sed -n '/^# Confluent Platform (operator mode)/,/^# Exit status/p' "${ZSH_ARGZERO}" | sed 's/^# \{0,1\}//'; }

DRY_RUN=false
while (( $# > 0 )); do
    case "$1" in
        --dry-run)    DRY_RUN=true; shift ;;
        --tls-source)
            h_need_value "$1" "${2:-}"
            case "$2" in
                repo|cfk) export CONFLUENT_OPERATOR_TLS_SOURCE_CLI="$2" ;;
                *) echo "[ERROR] --tls-source must be repo or cfk (got '$2')." >&2; exit 1 ;;
            esac
            shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done
export DRY_RUN

cfo_entry platform

NS="${PROJECT_CONFLUENT_SERVER}"
SA="confluent"
OLM_PY="${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_olm.py"
RENDER_DIR="${CF_RENDER_ROOT}/cfk"

_int() { _cfo_int "${1:-}" "$2"; print -r -- "${REPLY}"; }
T_KAFKA="$(_int "${CONFLUENT_OPERATOR_KAFKA_TIMEOUT:-}" 900)"
T_CONNECT="$(_int "${CONFLUENT_OPERATOR_CONNECT_TIMEOUT:-}" 900)"
T_COMPONENT="$(_int "${CONFLUENT_OPERATOR_COMPONENT_TIMEOUT:-}" 600)"

echo "=============================================================================="
_dr=""
if [[ "${DRY_RUN}" == true ]]; then _dr=" - DRY RUN"; fi
echo " Confluent Platform (operator mode) install - project '${NS}'${_dr}"
echo "=============================================================================="

# ------------------------------------------------------------------------------
echo "[1/8] Preflight"
if ! oc get namespace "${NS}" &>/dev/null; then
    echo "[ERROR] Project '${NS}' does not exist. Run 1.0_confluent_prep.sh first." >&2
    exit 1
fi
if ! oc get serviceaccount "${SA}" -n "${NS}" &>/dev/null; then
    echo "[ERROR] ServiceAccount '${SA}' not found in ${NS}. Run 1.0_confluent_prep.sh first." >&2
    exit 1
fi
_rc=0
cfo_detect "${CFO_PKG_CFK}" "${NS}" || _rc=$?
if (( _rc != 0 )); then
    echo "[ERROR] Cannot tell which CFK operator watches ${NS} (see above)." >&2
    exit 1
fi
if [[ "${CFO_RESULT}" != reuse ]]; then
    echo "[ERROR] No running CFK operator watches ${NS}${CFO_REASON:+ (${CFO_REASON})}." >&2
    echo "[ERROR] Run the operators step (operator/1.0o_confluent_operators.sh) first." >&2
    exit 1
fi
CFK_CSV="${CFO_CSV}"
CFK_NS="${CFO_NS}"

# ------------------------------------------------------------------------------
echo "[2/8] Effective settings"
: "${CONFLUENT_SASL_ENABLED:=false}"
: "${CONFLUENT_SASL_ADMIN_USER:=confluent-admin}"
: "${CONFLUENT_SASL_SECRET:=confluent-sasl}"
: "${CONFLUENT_MDS_ENABLED:=false}"
: "${CONFLUENT_MDS_USER_STORE:=LDAP}"
: "${CONFLUENT_KEYCLOAK_REALM:=confluent}"
: "${CONFLUENT_EXTERNAL_KAFKA_ENABLED:=false}"
: "${CONFLUENT_EXTERNAL_TLS_SECRET:=confluent-kafka-tls}"
: "${CONFLUENT_AUTH_ENABLED:=true}"
: "${CONFLUENT_AUTH_MODE:=openshift}"
: "${CONFLUENT_AUTH_SECRET:=confluent-auth}"
: "${CONFLUENT_CREATE_ROUTES:=true}"
: "${CONFLUENT_INSTALL_CONTROL_CENTER:=true}"
# Operator mode authenticates the components with CFK's native PLAIN (contract D10); the security
# helpers below would otherwise default the mechanism to SCRAM-SHA-512.
: "${CONFLUENT_SASL_MECHANISM:=PLAIN}"
: "${CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS:=PLAIN}"
: "${CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS:=PLAIN}"
source "${CF_PLATFORM_DIR}/confluent_kafka_security.sh"

# MDS implies SASL (same rule and wording as 1.1_confluent_install.sh:131-137).
if [[ "${CONFLUENT_MDS_ENABLED}" == "true" && "${CONFLUENT_SASL_ENABLED}" != "true" ]]; then
    echo "[INFO] CONFLUENT_MDS_ENABLED=true implies SASL; enabling it (MDS requires it)."
    CONFLUENT_SASL_ENABLED="true"
fi
# The external listener always authenticates (cfo_check_config refuses it without SASL already).
if [[ "${CONFLUENT_EXTERNAL_KAFKA_ENABLED}" == "true" && "${CONFLUENT_SASL_ENABLED}" != "true" ]]; then
    echo "[ERROR] CONFLUENT_EXTERNAL_KAFKA_ENABLED=true needs CONFLUENT_SASL_ENABLED=true in operator mode." >&2
    exit 1
fi
export CONFLUENT_SASL_ENABLED CONFLUENT_MDS_ENABLED

# MDS needs its token keypair, which x.4_confluent_add_mds.sh creates. Without it this pass renders the
# platform without MDS and hands off to that script once the platform is up (as 1.1:505-533 does);
# CFO_MDS_HANDOFF=1 (set for and by that script) stops the hand-off from looping.
MDS_DEFERRED=false
if [[ "${CONFLUENT_MDS_ENABLED}" == "true" ]] \
   && ! oc get secret "${CFO_MDS_TOKEN_SECRET}" -n "${NS}" &>/dev/null; then
    if [[ "${CFO_MDS_HANDOFF:-}" == 1 ]]; then
        echo "[ERROR] CONFLUENT_MDS_ENABLED=true but secret '${CFO_MDS_TOKEN_SECRET}' is missing in ${NS}." >&2
        echo "[ERROR] Run x.4_confluent_add_mds.sh, which generates the MDS token keypair." >&2
        exit 1
    fi
    echo "[INFO] MDS requested but no token keypair yet; this pass installs without MDS and hands off to x.4_confluent_add_mds.sh."
    MDS_DEFERRED=true
    CONFLUENT_MDS_ENABLED="false"
    export CONFLUENT_MDS_ENABLED
fi

SASL_PROTO="-"
if [[ "${CONFLUENT_SASL_ENABLED}" == "true" ]]; then
    SASL_PROTO="${CONFLUENT_SASL_PROTOCOL}"
fi
TLS_SOURCE="$(cfo_tls_source)"
SASL_IMPL="$(cfo_sasl_impl)"

# The front proxy mode the repo set renders (none without Control Center: there is nothing to front).
if [[ "${CONFLUENT_INSTALL_CONTROL_CENTER}" != "true" || "${CONFLUENT_AUTH_ENABLED}" != "true" ]]; then
    PROXY_MODE=none
elif [[ "${(L)CONFLUENT_AUTH_MODE}" == openshift ]]; then
    PROXY_MODE=openshift
else
    PROXY_MODE=basic
fi

ROUTE_DOMAIN=""
if [[ "${CONFLUENT_EXTERNAL_KAFKA_ENABLED}" == "true" ]]; then
    ROUTE_DOMAIN="$(cfo_route_domain)"
    if [[ -z "${ROUTE_DOMAIN}" ]]; then
        echo "[ERROR] External Kafka access needs the route domain: set CONFLUENT_ROUTE_DOMAIN or make" >&2
        echo "[ERROR] ingresses.config/cluster readable (oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')." >&2
        exit 1
    fi
fi

typeset -a _enabled=()
for _pair in SCHEMA_REGISTRY:schema-registry CONNECT:connect KSQLDB:ksqldb REST_PROXY:rest-proxy CONTROL_CENTER:control-center; do
    _var="CONFLUENT_INSTALL_${_pair%%:*}"
    [[ "${(P)_var:-true}" == "true" ]] && _enabled+=("${_pair#*:}")
done
_sasl_line="off"
if [[ "${CONFLUENT_SASL_ENABLED}" == "true" ]]; then
    _sasl_line="${SASL_PROTO} / $(kafka_internal_mechanisms) (impl ${SASL_IMPL}, admin ${CONFLUENT_SASL_ADMIN_USER})"
fi
_mds_line="${CONFLUENT_MDS_ENABLED}"
${MDS_DEFERRED} && _mds_line="deferred (x.4_confluent_add_mds.sh after this install)"
printf '  %-22s %s\n' \
    "CFK operator" "${CFK_CSV} in ${CFK_NS}" \
    "Kafka SASL" "${_sasl_line}" \
    "TLS source" "${TLS_SOURCE}" \
    "external Kafka" "${CONFLUENT_EXTERNAL_KAFKA_ENABLED}${ROUTE_DOMAIN:+ (routes under ${ROUTE_DOMAIN})}" \
    "MDS / RBAC" "${_mds_line}" \
    "web UI front proxy" "${PROXY_MODE}" \
    "components" "kraftcontroller kafka ${_enabled[*]}"
unset _pair _var _enabled _sasl_line _mds_line
# (TLS source cfk + external: the renderer prints the mixed-mode note of plan 15.13 item 7 in [4/8].)

# ------------------------------------------------------------------------------
echo "[3/8] Secrets"
if [[ "${PROXY_MODE}" == openshift ]] && ! oc get secret "${CONFLUENT_AUTH_SECRET}-oauth" -n "${NS}" &>/dev/null; then
    echo "[ERROR] CONFLUENT_AUTH_MODE=openshift but secret '${CONFLUENT_AUTH_SECRET}-oauth' is missing in ${NS}." >&2
    echo "[ERROR] Run 1.0_confluent_prep.sh first." >&2
    exit 1
fi
if [[ "${PROXY_MODE}" == basic ]] && ! oc get secret "${CONFLUENT_AUTH_SECRET}" -n "${NS}" &>/dev/null; then
    echo "[ERROR] CONFLUENT_AUTH_MODE=basic but secret '${CONFLUENT_AUTH_SECRET}' is missing in ${NS}." >&2
    echo "[ERROR] Run 1.0_confluent_prep.sh first." >&2
    exit 1
fi
# Secrets this run creates; a dry run creates none, so the render below counts them as present (see the shim).
typeset -a WOULD_CREATE=()
if [[ "${CONFLUENT_SASL_ENABLED}" == "true" ]]; then
    _rc=0
    cfo_derive_sasl_secrets "${NS}" || _rc=$?
    (( _rc == 0 )) || { echo "[ERROR] Deriving the CFK SASL secrets from '${CONFLUENT_SASL_SECRET}' failed." >&2; exit 1; }
    WOULD_CREATE+=("${CFO_SASL_SERVER_SECRET}" "${CFO_SASL_CLIENT_SECRET}")
fi
_rc=0
cfo_ensure_license_secret "${NS}" || _rc=$?
(( _rc == 0 )) || { echo "[ERROR] Writing the license secret '${CFO_LICENSE_SECRET}' failed." >&2; exit 1; }
if [[ "${SASL_PROTO}" == "SASL_SSL" || "${CONFLUENT_EXTERNAL_KAFKA_ENABLED}" == "true" ]]; then
    if [[ "${TLS_SOURCE}" == cfk ]]; then
        _rc=0
        cfo_tls_ensure_ca_pair "${NS}" || _rc=$?
        (( _rc == 0 )) || { echo "[ERROR] Creating the CFK CA secret '${CFO_CA_PAIR_SECRET}' failed." >&2; exit 1; }
        WOULD_CREATE+=("${CFO_CA_PAIR_SECRET}")
    elif [[ "${SASL_PROTO}" == "SASL_SSL" ]]; then
        _rc=0
        kafka_ensure_internal_tls "${NS}" || _rc=$?
        (( _rc == 0 )) || { echo "[ERROR] Creating the in-cluster TLS secret '${CONFLUENT_INTERNAL_TLS_SECRET}' failed." >&2; exit 1; }
        WOULD_CREATE+=("${CONFLUENT_INTERNAL_TLS_SECRET}")
    fi
fi
if [[ "${CONFLUENT_EXTERNAL_KAFKA_ENABLED}" == "true" ]]; then
    _rc=0
    cfo_tls_ensure_external_cert "${NS}" "${ROUTE_DOMAIN}" || _rc=$?
    (( _rc == 0 )) || { echo "[ERROR] Creating the external TLS secret '${CONFLUENT_EXTERNAL_TLS_SECRET}' failed." >&2; exit 1; }
    WOULD_CREATE+=("${CONFLUENT_EXTERNAL_TLS_SECRET}")
fi

if [[ "${DRY_RUN}" == true ]]; then
    # CONTRACT-DEVIATION: a dry run writes no secret, but the renderer refuses a SASL_SSL / external / cfk-TLS
    # render whose secrets are absent (contract 4.4), so a dry run of a first install could never render.
    # The secrets this run would create count as present for this dry run only (request: a supported
    # cfo_live_json hook for this instead of wrapping its private _cfo_secret_present).
    functions[_cfo1_secret_present_live]="${functions[_cfo_secret_present]}"
    _cfo_secret_present() {   # <ns> <name>
        if [[ -n "$2" ]] && (( ${WOULD_CREATE[(Ie)$2]} )); then print -r -- true; else _cfo1_secret_present_live "$@"; fi
    }
fi

# ------------------------------------------------------------------------------
echo "[4/8] Render"
# OAUTH user store without an external IdP: the bundled Keycloak's route (as 1.1:525-554 does).
if [[ "${CONFLUENT_MDS_ENABLED}" == "true" && "${(U)CONFLUENT_MDS_USER_STORE}" == "OAUTH" \
      && -z "${CONFLUENT_MDS_OAUTH_JWKS_URL:-}" ]]; then
    _kc_host="$(oc get route keycloak -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    if [[ -z "${_kc_host}" ]]; then
        echo "[ERROR] MDS user store is OAUTH but neither CONFLUENT_MDS_OAUTH_JWKS_URL nor a" >&2
        echo "[ERROR] Keycloak route exists. Run x.4_confluent_user_store.sh first." >&2
        exit 1
    fi
    _kc_base="https://${_kc_host}/realms/${CONFLUENT_KEYCLOAK_REALM}"
    export CONFLUENT_MDS_OAUTH_JWKS_URL="${_kc_base}/protocol/openid-connect/certs"
    export CONFLUENT_MDS_OAUTH_ISSUER="${_kc_base}"
    echo "[INFO] MDS OAUTH: Keycloak realm ${_kc_base}"
    unset _kc_host _kc_base
fi

# _render <set> <out-root> [<args-json>] - cfo_render, with the renderer's own no-license warning dropped
# from its messages once cfo_license_warning has printed it (plan item 14: printed once per run).
_render() {
    local errf rc=0
    errf="$(mktemp "${TMPDIR:-/tmp}/cfo-render-err.XXXXXX")" || return 1
    cfo_render "$@" 2>"${errf}" || rc=$?
    if [[ -n "${_CFO_LICENSE_WARNED:-}" ]]; then
        grep -v -F "[WARN] No CONFLUENT_LICENSE_KEY" "${errf}" >&2 || true
    else
        cat "${errf}" >&2
    fi
    rm -f "${errf}"
    return "${rc}"
}

_rc=0
_render platform "${RENDER_DIR}" || _rc=$?
(( _rc == 0 )) || { echo "[ERROR] Rendering the platform CRs failed (see above)." >&2; exit 1; }
PLATFORM_MANIFEST="${CFO_MANIFEST}"
_rc=0
_render repo "${RENDER_DIR}" "{\"front_proxy_mode\": \"${PROXY_MODE}\"}" || _rc=$?
(( _rc == 0 )) || { echo "[ERROR] Rendering the repo objects failed (see above)." >&2; exit 1; }
REPO_MANIFEST="${CFO_MANIFEST}"
for _m in "${PLATFORM_MANIFEST}" "${REPO_MANIFEST}"; do
    _rc=0
    _files="$(cfo_python "${OLM_PY}" manifest-files --manifest "${_m}")" || _rc=$?
    (( _rc == 0 )) || { echo "[ERROR] Cannot read the rendered manifest ${_m}." >&2; exit 1; }
    _n=0
    [[ -n "${_files}" ]] && _n=${#${(@f)_files}}
    echo "  ${_m:h:t}: ${_n} object(s) to apply, rendered in ${_m:h}"
done
unset _m _files _n

# ------------------------------------------------------------------------------
# _gen <Kind> <name> - metadata.generation of a live CR; empty when it does not exist.
_gen() {
    oc get "$(cfo_resource "$1")" "$2" -n "${NS}" -o jsonpath='{.metadata.generation}' 2>/dev/null || true
}

# _apply_stage <manifest> <stage> - applies one stage of the platform manifest, then waits with progress:
# a CR whose spec the apply changed (generation moved) waits for CFK's roll (cfo_wait_roll); a new or
# unchanged one waits until it is RUNNING and ready (cfo_wait_crs). A failed apply stops at once.
_apply_stage() {
    local manifest="$1" stage="$2" out line ref t tmax="${T_COMPONENT}"
    local -A before tmo
    local -a crs=() rolls=() settle=()
    out="$(cfo_python "${OLM_PY}" manifest-files --manifest "${manifest}" --stage "${stage}")" || return 1
    [[ -z "${out}" ]] && { echo "  (nothing in stage ${stage})"; return 0; }
    for line in "${(@f)out}"; do
        local -a f=("${(@s:	:)line}")
        [[ "${f[5]:-}" == phase ]] || continue
        ref="${f[2]}/${f[3]}"
        crs+=("${ref}")
        before[$ref]="$(_gen "${f[2]}" "${f[3]}")"
        case "${f[2]}" in
            Kafka|KRaftController) t="${T_KAFKA}" ;;
            Connect)               t="${T_CONNECT}" ;;
            *)                     t="${T_COMPONENT}" ;;
        esac
        tmo[$ref]="${t}"
    done
    cfo_apply_manifest "${manifest}" "${stage}" || return 1
    [[ "${DRY_RUN}" == true ]] && return 0
    for ref in "${crs[@]}"; do
        local now="$(_gen "${ref%%/*}" "${ref#*/}")"
        if [[ -n "${before[$ref]}" && "${now}" != "${before[$ref]}" ]]; then
            rolls+=("${ref}")
        else
            settle+=("${ref}")
            (( tmo[$ref] > tmax )) && tmax="${tmo[$ref]}"
        fi
    done
    for ref in "${rolls[@]}"; do
        echo "[INFO] ${ref} changed - waiting for CFK to roll it."
        cfo_wait_roll "${NS}" "${ref}" "${tmo[$ref]}" || return 1
    done
    if (( ${#settle} )); then
        cfo_wait_crs "${NS}" "${tmax}" "${settle[@]}" || return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
echo "[5/8] KRaft controllers and Kafka"
_rc=0
_apply_stage "${PLATFORM_MANIFEST}" 1 || _rc=$?
(( _rc == 0 )) || { echo "[ERROR] KRaftController / Kafka did not come up (see above)." >&2; exit 1; }

# ------------------------------------------------------------------------------
echo "[6/8] Components"
# CONTRACT-DEVIATION: the contract lists stages 3-4 only. Stages 2 and 5 (KafkaRestClass, ConfluentRolebinding)
# are rendered only while MDS is on and not deferred (empty otherwise), and are applied here too, in CFK's
# documented order: the REST class before the components, the role binding after them. Without them a re-run
# with MDS already configured would never restore or update them (x.4_confluent_add_mds.sh and
# cfo_reapply_platform both assume 1.1 applies every stage). Neither stage has a phase to wait for;
# x.4_confluent_add_mds.sh waits for the role binding's state.
for _stage in 2 3 4 5; do
    echo "--- stage ${_stage}"
    _rc=0
    _apply_stage "${PLATFORM_MANIFEST}" "${_stage}" || _rc=$?
    (( _rc == 0 )) || { echo "[ERROR] Stage ${_stage} components did not come up (see above)." >&2; exit 1; }
done
unset _stage
_rc=0
cfo_delete_disabled "${PLATFORM_MANIFEST}" "${NS}" || _rc=$?
(( _rc == 0 )) || { echo "[ERROR] Removing the disabled components failed (see above)." >&2; exit 1; }

# ------------------------------------------------------------------------------
echo "[7/8] Front proxy, Routes, NetworkPolicies"
# K8S-EXTENSION(K4): Kubernetes mode applies Ingress objects here instead of the OpenShift Routes.
# The front proxy first: it writes the gateway secret (the rendered nginx.conf + htpasswd) its Deployment mounts.
_rc=0
cfo_apply_front_proxy "${NS}" "${PROXY_MODE}" || _rc=$?
(( _rc == 0 )) || { echo "[ERROR] The Control Center front proxy (${PROXY_MODE}) failed (see above)." >&2; exit 1; }
_rc=0
cfo_apply_manifest "${REPO_MANIFEST}" || _rc=$?
(( _rc == 0 )) || { echo "[ERROR] Applying the repo objects failed (see above)." >&2; exit 1; }
_rc=0
cfo_delete_disabled "${REPO_MANIFEST}" "${NS}" || _rc=$?
(( _rc == 0 )) || { echo "[ERROR] Removing the disabled repo objects failed (see above)." >&2; exit 1; }

if [[ "${CONFLUENT_SASL_ENABLED}" == "true" && "${SASL_IMPL}" == scram && -n "$(kafka_scram_mechanisms_in_use)" ]]; then
    echo "[INFO] Registering SCRAM users ($(kafka_scram_mechanisms_in_use))..."
    if [[ "${DRY_RUN}" == true ]]; then
        echo "  [DRY-RUN] kafka-configs --alter --add-config <SCRAM> for every user in secret/${CONFLUENT_SASL_SECRET} (via kafka-0)"
    else
        SASL_ADMIN_PW="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" \
            -o jsonpath="{.data.${CONFLUENT_SASL_ADMIN_USER}}" 2>/dev/null | base64 --decode || true)"
        if [[ -z "${SASL_ADMIN_PW}" ]]; then
            echo "[ERROR] Secret '${CONFLUENT_SASL_SECRET}' has no entry for '${CONFLUENT_SASL_ADMIN_USER}'." >&2
            exit 1
        fi
        if ! kafka_register_scram_users_cfk "${NS}" "${SASL_ADMIN_PW}" "${(@f)$(kafka_secret_credentials "${NS}")}"; then
            echo "[ERROR] Registering the SCRAM users failed; PLAIN clients still work. Re-run this script" >&2
            echo "[ERROR] or x.2_confluent_add_sasl.sh once the cluster is healthy." >&2
            exit 1
        fi
        unset SASL_ADMIN_PW
    fi
fi

# External access is configured by this script in operator mode (no x.4 hand-off as in scripts mode), so
# the local client files that hand-off wrote come from x.4's --client-config-only: the client properties
# and confluent_kafka_ca.crt, which 1.3's watsonx.data block and confluent_cli_login.sh point at.
if [[ "${CONFLUENT_EXTERNAL_KAFKA_ENABLED}" == "true" ]]; then
    _ext_script="${CF_PLATFORM_DIR}/utility_scripts_confluent_platform/x.4_confluent_add_external_access.sh"
    if [[ "${DRY_RUN}" == true ]]; then
        echo "  [DRY-RUN] ${_ext_script##*/} --client-config-only (confluent_external_client.properties, confluent_kafka_ca.crt)"
    elif [[ -f "${_ext_script}" ]]; then
        echo "[INFO] Writing the external client files (${_ext_script##*/} --client-config-only)..."
        zsh "${_ext_script}" --client-config-only \
            || echo "[WARN] Could not write the external client files; re-run ${_ext_script##*/} --client-config-only." >&2
    fi
    unset _ext_script
fi

if ${MDS_DEFERRED}; then
    _mds_script="${CF_PLATFORM_DIR}/utility_scripts_confluent_platform/x.4_confluent_add_mds.sh"
    if [[ "${DRY_RUN}" == true ]]; then
        echo "  [DRY-RUN] hand off to ${_mds_script##*/} --yes --no-status (MDS token keypair, then this install again)"
    elif [[ -f "${_mds_script}" ]]; then
        echo "[INFO] MDS requested but no token keypair yet; handing off to ${_mds_script##*/}."
        export CFO_MDS_HANDOFF=1
        export CONFLUENT_MDS_ENABLED=true
        exec zsh "${_mds_script}" --yes --no-status
    else
        echo "[WARN] CONFLUENT_MDS_ENABLED=true but ${_mds_script##*/} is missing; MDS stays off." >&2
    fi
fi

# ------------------------------------------------------------------------------
echo "[8/8] Summary"
echo ""
if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY-RUN] Nothing was changed. Rendered files: ${RENDER_DIR}"
    exit 0
fi
echo "[INFO] Confluent Platform ${CONFLUENT_VERSION} installed in project '${NS}' (operator mode, ${CFK_CSV})."
echo "[INFO] In-cluster bootstrap servers: $(cf_bootstrap_internal "${NS}")"
if [[ "${CONFLUENT_SASL_ENABLED}" == "true" ]]; then
    echo "[INFO] Kafka authentication: in-cluster ${SASL_PROTO} / $(kafka_internal_mechanisms)${${CONFLUENT_EXTERNAL_KAFKA_ENABLED:#false}:+, EXTERNAL SASL_SSL / ${CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS}}."
    echo "[INFO]   Client properties: 1.3_confluent_get_instance_details.sh writes them to configs/confluent_platform_config/."
fi
_ext="$(cf_external_bootstrap "${NS}")"
[[ -n "${_ext}" ]] && echo "[INFO] External bootstrap: ${_ext}"
unset _ext
case "${PROXY_MODE}" in
    basic)
        _auth_user="$(oc get secret "${CONFLUENT_AUTH_SECRET}" -n "${NS}" -o jsonpath='{.data.username}' 2>/dev/null | base64 --decode || true)"
        echo "[INFO] Web UIs require basic auth - user '${_auth_user}', password:"
        echo "[INFO]   oc get secret ${CONFLUENT_AUTH_SECRET} -n ${NS} -o jsonpath='{.data.password}' | base64 --decode"
        unset _auth_user ;;
    openshift)
        echo "[INFO] The Control Center UI is behind the OpenShift login (oauth-proxy)." ;;
    *)
        if [[ "${CONFLUENT_INSTALL_CONTROL_CENTER}" == "true" ]]; then
            echo "[WARN] Web UIs are exposed WITHOUT authentication (CONFLUENT_AUTH_ENABLED=false)."
        fi ;;
esac
# cfo_license_warning already printed the trial warning once; this line only states the result.
if [[ "${CFO_LICENSE_PRESENT:-false}" == true ]]; then
    echo "[INFO] License: secret ${CFO_LICENSE_SECRET} (spec.license on every CR)."
else
    echo "[INFO] License: none configured - the 30-day trial applies."
fi
if [[ "${CONFLUENT_CREATE_ROUTES}" == "true" ]]; then
    echo "[INFO] Routes:"
    oc get routes -n "${NS}" -l app.kubernetes.io/part-of=confluent \
        -o custom-columns='NAME:.metadata.name,URL:.spec.host' --no-headers 2>/dev/null \
        | while read -r _name _host; do echo "         ${_name}: https://${_host}"; done || true
fi
echo "[INFO] Next: 1.2_confluent_status.sh, then 1.3_confluent_get_instance_details.sh."
