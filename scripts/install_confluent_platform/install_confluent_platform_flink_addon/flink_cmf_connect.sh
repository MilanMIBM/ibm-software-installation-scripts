#!/bin/zsh
# ==============================================================================
# Confluent Platform for Apache Flink - CMF connection helper
# ------------------------------------------------------------------------------
# SOURCED, not executed. Provides cmf_connect(), which sets CMF_URL to a working
# base URL for the confluent CLI and, when a port-forward was needed, arranges
# for it to be torn down when the calling script exits.
#
#   source "${SCRIPT_DIR}/flink_cmf_connect.sh"
#   cmf_connect
#   confluent flink environment list --url "${CMF_URL}"
#
# Two ways to reach CMF:
#   1. the 'cmf' route, when FLINK_CREATE_ROUTES=true
#   2. oc port-forward, otherwise
#
# The port-forward is the default because the CMF REST API ships without
# authentication, so exposing it on the cluster's public ingress is a decision
# that has to be made deliberately rather than inherited from an install script.
#
# Callers that already have CMF_URL set (an external CMF, or a forward the user
# opened by hand) are left alone.
# ==============================================================================

# ------------------------------------------------------------------------------
# _cmf_reachable <url> - true when CMF answers on that base URL.
# ------------------------------------------------------------------------------
_cmf_reachable() {
    # The environments endpoint is the readiness check: it is the same REST API
    # the confluent CLI drives, so a 200 here means the CLI will work. CMF does
    # NOT expose Spring's /actuator/health - that path 404s even when CMF is
    # fully up, which is a false negative worth avoiding.
    #
    # Checking a real endpoint rather than just opening a socket also
    # distinguishes "CMF is serving" from "the router answered with its own 503
    # page", which a plain connection test cannot.
    curl -sf --max-time 5 "${1}/cmf/api/v1/environments" &>/dev/null
}

# ------------------------------------------------------------------------------
# cmf_connect - sets CMF_URL, starting a port-forward if that is what it takes.
# ------------------------------------------------------------------------------
cmf_connect() {
    local ns="${PROJECT_CONFLUENT_FLINK}"

    # ------------------------------------------------------------------------
    # Isolate the confluent CLI's own configuration.
    #
    # CMF is addressed purely by --url and needs no confluent login. But the
    # CLI refuses to run ANY command - including these - when the config it
    # finds holds an expired session:
    #
    #   Error: not logged in
    #
    # confluent_cli_login.sh one directory up logs in to MDS and leaves such a
    # context in ~/.confluent/config.json. Once its token ages out, every Flink
    # script here starts failing with an error about a login they never needed,
    # and (worse) a failed `catalog describe` reads as "catalog absent".
    #
    # Pointing HOME at a scratch directory gives the CLI an empty config, so
    # the MDS session and these CMF calls cannot interfere with each other in
    # either direction. Exported so it applies to every confluent invocation in
    # the calling script.
    #
    # KUBECONFIG is pinned to the REAL home first: oc also resolves its config
    # through HOME, and moving it without this makes every later oc call fail
    # with "Missing or incomplete configuration info".
    if [[ -z "${CMF_CLI_HOME:-}" ]]; then
        export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
        CMF_CLI_HOME="$(mktemp -d "${TMPDIR:-/tmp}/flink-cmf-cli.XXXXXX")"
        export CMF_CLI_HOME
        export HOME="${CMF_CLI_HOME}"

        # One cleanup hook for everything this function allocates. Installed
        # here rather than beside the port-forward so it also runs on the paths
        # that never open one (an existing route, or a caller-supplied URL).
        # See the note at the port-forward for why this is zshexit and not a
        # trap: a trap set inside a function fires the moment it returns.
        zshexit() {
            [[ -n "${CMF_PORT_FORWARD_PID:-}" ]] && kill "${CMF_PORT_FORWARD_PID}" 2>/dev/null
            [[ -n "${CMF_CLI_HOME:-}" && "${CMF_CLI_HOME}" == */flink-cmf-cli.* ]] \
                && rm -rf "${CMF_CLI_HOME}"
            return 0
        }
    fi

    # 1. Caller supplied one.
    if [[ -n "${CMF_URL:-}" ]]; then
        echo "[INFO] Using CMF at ${CMF_URL} (from the environment)."
        return 0
    fi

    if ! oc get deployment confluent-manager-for-apache-flink -n "${ns}" &>/dev/null; then
        echo "[ERROR] CMF is not installed in project '${ns}'." >&2
        echo "[ERROR] Run flink_install/1.1_flink_install.sh first." >&2
        return 1
    fi

    # CMF has to be serving before anything is worth trying. A pod that is
    # still starting produces a confusing connection-refused from the CLI.
    if ! oc rollout status deployment/confluent-manager-for-apache-flink \
            -n "${ns}" --timeout=120s &>/dev/null; then
        echo "[ERROR] CMF is not ready in project '${ns}'." >&2
        # The chart labels the pod app.kubernetes.io/name, not app.
        oc get pods -n "${ns}" -l app.kubernetes.io/name=confluent-manager-for-apache-flink >&2 || true
        return 1
    fi

    # 2. The route, when there is one and it is not behind the OpenShift login.
    # x.2_flink_add_auth_openshift.sh repoints the route at an oauth-proxy,
    # which the confluent CLI cannot authenticate to - and which answers the
    # reachability check with a 302 that curl -f counts as success.
    local host route_svc
    host="$(oc get route cmf -n "${ns}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    route_svc="$(oc get route cmf -n "${ns}" -o jsonpath='{.spec.to.name}' 2>/dev/null || true)"
    if [[ -n "${host}" && "${route_svc}" != "${FLINK_CMF_SERVICE}" ]]; then
        echo "[INFO] Route 'cmf' is behind the OpenShift login - port-forwarding instead."
    elif [[ -n "${host}" ]]; then
        if _cmf_reachable "https://${host}"; then
            CMF_URL="https://${host}"
            echo "[INFO] Using CMF at ${CMF_URL} (route)."
            return 0
        fi
        echo "[WARN] Route 'cmf' exists (${host}) but CMF did not answer on it - port-forwarding instead."
    fi

    # 3. Port-forward. A free local port is picked starting from the configured
    # one, so two of these scripts can run at once and a stale forward from an
    # earlier crashed run does not block this one.
    local port="${FLINK_CMF_LOCAL_PORT:-8080}"
    local tries=0
    while (( tries < 20 )) && lsof -iTCP:"${port}" -sTCP:LISTEN &>/dev/null; do
        port=$(( port + 1 )); tries=$(( tries + 1 ))
    done
    if (( tries >= 20 )); then
        echo "[ERROR] No free local port found near ${FLINK_CMF_LOCAL_PORT}." >&2
        return 1
    fi

    echo "[INFO] Port-forwarding to ${FLINK_CMF_SERVICE} on 127.0.0.1:${port}..."
    # --address 127.0.0.1 and a 127.0.0.1 URL, never "localhost": oc
    # port-forward listens on IPv4 only, while the confluent CLI's Go resolver
    # tries ::1 first for "localhost" and fails with
    #   dial tcp [::1]:8080: connect: connection refused
    # even though curl (which falls back to IPv4) reports the tunnel as healthy.
    oc port-forward --address 127.0.0.1 "svc/${FLINK_CMF_SERVICE}" \
        "${port}:${FLINK_CMF_PORT}" -n "${ns}" &>/dev/null &
    CMF_PORT_FORWARD_PID=$!

    # Tear the forward down however the caller exits, using zsh's zshexit hook
    # rather than `trap ... EXIT`.
    #
    # This is not a stylistic choice. In zsh a trap set INSIDE a function is
    # function-local: it fires the moment the function returns, so a trap
    # installed here would kill the port-forward before cmf_connect's caller
    # ever used it. The symptom is a health check that passes followed
    # immediately by "connect: connection refused" from the confluent CLI.
    # Neither `builtin trap` nor `unsetopt LOCAL_TRAPS` changes this.
    #
    # Defining a function IS global, and zshexit runs at real shell exit -
    # after, and without disturbing, the [TIMER] EXIT trap every sibling
    # script installs at its top level.
    #
    # The hook itself is defined once, at the top of this function, and reads
    # CMF_PORT_FORWARD_PID at exit time - so setting the pid here is all that
    # is needed. Redefining zshexit here would drop the scratch-dir cleanup.

    CMF_URL="http://127.0.0.1:${port}"

    # oc port-forward returns immediately; the tunnel is not usable until it has
    # actually connected, so poll rather than sleeping a fixed amount.
    local waited=0
    until _cmf_reachable "${CMF_URL}"; do
        sleep 1; waited=$(( waited + 1 ))
        if ! kill -0 "${CMF_PORT_FORWARD_PID}" 2>/dev/null; then
            echo "[ERROR] The port-forward to ${FLINK_CMF_SERVICE} died immediately." >&2
            echo "[ERROR] Check:  oc get svc ${FLINK_CMF_SERVICE} -n ${ns}" >&2
            return 1
        fi
        if (( waited >= 30 )); then
            echo "[ERROR] CMF did not answer on ${CMF_URL} after ${waited}s." >&2
            return 1
        fi
    done

    echo "[INFO] Using CMF at ${CMF_URL} (port-forward, pid ${CMF_PORT_FORWARD_PID})."
    return 0
}
