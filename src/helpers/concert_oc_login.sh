#!/bin/zsh
# =============================================================================
# concert_oc_login.sh - log oc in to the cluster in concert_vars.sh (OCP_URL)
# -----------------------------------------------------------------------------
# concert_helpers.sh points OC_LOGIN at this script, so every Concert script's
# eval "${OC_LOGIN}" ends up on OCP_URL, never on whatever cluster the current
# oc context happens to point at. Runs as a child process: the result lives in
# the kubeconfig, so it also works for shared scripts that do not source the
# Concert helpers. In order:
#   1. the current context is OCP_URL and its session is valid -> keep it
#   2. another kubeconfig context for OCP_URL has a valid session -> switch to it
#   3. log in with the config's credentials (OC_LOGIN_FORCE); OCP_CA_FILE, when
#      set, is the CA bundle that signed the API certificate
# then checks that oc really points at OCP_URL, and fails otherwise.
# =============================================================================

set -uo pipefail

want="${OCP_URL%/}"
_server() { oc whoami --show-server "$@" 2>/dev/null; }

# 1. Current session
if [[ "$(_server)" == "${want}" ]] && oc whoami >/dev/null 2>&1; then
    print -r -- "[INFO] oc already logged in to ${want} as $(oc whoami) - skipping login"
    exit 0
fi

# 2. A saved context for the same API server
typeset -A _srv_of
while IFS=$'\t' read -r name srv; do
    [[ -n "${name}" ]] && _srv_of[${name}]="${srv%/}"
done < <(oc config view -o jsonpath='{range .clusters[*]}{.name}{"\t"}{.cluster.server}{"\n"}{end}' 2>/dev/null)
while IFS=$'\t' read -r ctx cluster; do
    [[ -n "${ctx}" && "${_srv_of[${cluster}]:-}" == "${want}" ]] || continue
    if oc --context "${ctx}" whoami >/dev/null 2>&1; then
        oc config use-context "${ctx}" >/dev/null
        print -r -- "[INFO] Switched to saved context ${ctx} ($(oc whoami) on ${want})"
        exit 0
    fi
done < <(oc config view -o jsonpath='{range .contexts[*]}{.name}{"\t"}{.context.cluster}{"\n"}{end}' 2>/dev/null)

# 3. Fresh login
login="${OC_LOGIN_FORCE:?OC_LOGIN_FORCE is not set (source_env_setup.sh)}"
if [[ -n "${OCP_CA_FILE:-}" ]]; then
    [[ -r "${OCP_CA_FILE}" ]] || { print -r -- "[ERROR] OCP_CA_FILE=${OCP_CA_FILE} is not readable." >&2; exit 1; }
    login+=" --certificate-authority=${(q)OCP_CA_FILE}"
fi
print -r -- "[INFO] Logging in to ${want}"
out="$(eval "${login}" 2>&1)"; rc=$?
if (( rc != 0 )); then
    print -r -- "${out}" | grep -v -i 'password' >&2
    if [[ "${out}" == *x509* || "${out}" == *certificate* ]]; then
        print -r -- "[ERROR] ${want} presents a certificate this machine does not trust. Either:
        - set OCP_CA_FILE in concert_vars.sh to the CA bundle that signed it, or
        - log in once interactively (oc login ${want}) and accept the certificate;
          later runs reuse that session (step 1/2 above)." >&2
    fi
    exit "${rc}"
fi

# Verify
got="$(_server)"
if [[ "${got%/}" != "${want}" ]]; then
    print -r -- "[ERROR] oc points at '${got}', expected ${want} (OCP_URL)." >&2
    exit 1
fi
print -r -- "[INFO] Logged in to ${want} as $(oc whoami)"
