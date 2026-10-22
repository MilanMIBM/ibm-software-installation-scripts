#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: the mirror config only (MIRROR_CONFIG_FILE selects another file) ---
export ENV_TARGET="${MIRROR_CONFIG_FILE:-registry_mirror}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
preg_require_config

# ==============================================================================
# 0.3 Local private registry (air-gapped installs)
# ------------------------------------------------------------------------------
# Runs a registry on this machine (a laptop, a bastion inside the disconnected
# network). By default it is the FINAL registry the cluster pulls from (U7): fill
# it while connected, then the device joins the cluster network - so it needs a
# host name the nodes resolve (LOCAL_REGISTRY_HOST) and must stay up for the
# cluster's lifetime. For anything long-lived prefer a Linux bastion.
#
#   ./0.3_local_registry.sh up        create CA + TLS cert + login, start it
#   ./0.3_local_registry.sh status    container, /v2/ probe, repository count
#   ./0.3_local_registry.sh trust     trust its CA here (podman VM on macOS,
#                                     /etc/containers/certs.d on Linux)
#   ./0.3_local_registry.sh down      stop it (data kept)
#   ./0.3_local_registry.sh export F  archive the storage (+ .sha256) to move it
#   ./0.3_local_registry.sh import F  restore an archive into the storage dir
#   ./0.3_local_registry.sh rm --yes  stop it and delete its data and certs
#
# Engines (LOCAL_REGISTRY_ENGINE):
#   distribution     docker.io/library/registry:2 under podman (macOS or Linux):
#                    TLS from a CA generated here, htpasswd login, delete enabled
#   mirror-registry  Red Hat's mirror registry (Quay) - RHEL x86_64 only;
#                    installed with its own installer (port 8443)
#
# `up` writes registry_mirror_workspace/local-registry/state.env (read by
# detection) and fills MIRROR_REGISTRY_ROOT / _PUSH_USER / _PUSH_PASSWORD /
# _CA_FILE in the mirror config ONLY where they are empty.
# ==============================================================================

CMD="${1:-}"; shift || true
LR="${MIRROR_WORKSPACE}/local-registry"
STATE="$(preg_local_state_file)"
NAME="${LOCAL_REGISTRY_CONTAINER:-mirror-local-registry}"
ENGINE="${LOCAL_REGISTRY_ENGINE:-distribution}"
HOST="${LOCAL_REGISTRY_HOST:-}"
if [[ -z "${HOST}" ]]; then
    HOST="$(hostname -f 2>/dev/null || hostname)"
    HOST="${HOST:l}"
fi
PORT="${LOCAL_REGISTRY_PORT:-5000}"
[[ "${ENGINE}" == mirror-registry && -z "${LOCAL_REGISTRY_PORT:-}" ]] && PORT=8443
NS="${LOCAL_REGISTRY_NAMESPACE:-}"
DATA="${LOCAL_REGISTRY_DIR:-${LR}/data}"
CERTS="${LR}/certs"
AUTHD="${LR}/auth"
IMAGE="${LOCAL_REGISTRY_IMAGE:-docker.io/library/registry:2}"

# Update "export KEY=..." in the mirror config only when its value is empty.
# Values travel through the environment (never argv) and are single-quoted.
config_fill() {   # <KEY> <value>
    KEY="$1" VAL="$2" preg_python -I - "${MIRROR_CONFIG_FILE_PATH}" <<'PY'
import os, re, sys
path, k, v = sys.argv[1], os.environ["KEY"], os.environ["VAL"]
lines = open(path).read().split("\n")
pat = re.compile(r"^export " + re.escape(k) + r"=(.*)$")
for i, line in enumerate(lines):
    m = pat.match(line)
    if m:
        if m.group(1) not in ('""', "''", ""):
            sys.exit(0)
        lines[i] = f"export {k}='" + v.replace("'", "'\\''") + "'"
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write("\n".join(lines))
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        print(f"[INFO] Mirror config: set {k}")
        break
PY
}

# curl with basic auth read from stdin (-K -), so the password is never in argv.
curl_auth() {   # <user> <password> <curl args...>
    local u="$1" p="$2"; shift 2
    print -r -- "user = \"${u}:${p}\"" | curl -K - "$@"
}

my_ips() {
    if [[ "$(uname -s)" == Darwin ]]; then
        ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" { print $2 }'
    else
        hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' || true
    fi
}

write_state() {
    mkdir -p "${LR}"
    {
        print -r -- "LOCAL_REGISTRY_ENGINE=${ENGINE}"
        print -r -- "LOCAL_REGISTRY_HOST=${HOST}"
        print -r -- "LOCAL_REGISTRY_PORT=${PORT}"
        print -r -- "LOCAL_REGISTRY_NAMESPACE=${NS}"
        print -r -- "LOCAL_REGISTRY_CA_FILE=$1"
        print -r -- "LOCAL_REGISTRY_CONTAINER=${NAME}"
        print -r -- "LOCAL_REGISTRY_DIR=${DATA}"
    } > "${STATE}"
}

gen_certs() {
    mkdir -p "${CERTS}"
    chmod 700 "${CERTS}"
    if [[ ! -f "${CERTS}/ca.crt" ]]; then
        preg_info "Creating a CA for the local registry"
        # Explicit CA extensions: without them (macOS LibreSSL defaults) clients
        # refuse the CA ("unknown certificate").
        openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
            -keyout "${CERTS}/ca.key" -out "${CERTS}/ca.crt" \
            -subj "/CN=Local mirror registry CA (${HOST})" \
            -addext "basicConstraints=critical,CA:TRUE" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" \
            -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1
    fi
    local -U sans=("DNS:${HOST}" "DNS:${HOST%%.*}" "DNS:localhost" "IP:127.0.0.1")
    local ip
    for ip in $(my_ips); do sans+=("IP:${ip}"); done
    for ip in ${=LOCAL_REGISTRY_EXTRA_SANS:-}; do sans+=("${ip}"); done
    local want="${(j:,:)sans}"
    if [[ ! -f "${CERTS}/registry.crt" || "$(cat "${CERTS}/registry.sans" 2>/dev/null)" != "${want}" ]]; then
        preg_info "Issuing the registry certificate (SANs: ${want})"
        openssl req -newkey rsa:2048 -nodes -keyout "${CERTS}/registry.key" -out "${CERTS}/registry.csr" \
            -subj "/CN=${HOST}" >/dev/null 2>&1
        printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nauthorityKeyIdentifier=keyid\nsubjectKeyIdentifier=hash\n' "${want}" > "${CERTS}/ext.cnf"
        openssl x509 -req -in "${CERTS}/registry.csr" -CA "${CERTS}/ca.crt" -CAkey "${CERTS}/ca.key" \
            -CAcreateserial -out "${CERTS}/registry.crt" -days 825 -sha256 -extfile "${CERTS}/ext.cnf" >/dev/null 2>&1
        cat "${CERTS}/ca.crt" >> "${CERTS}/registry.crt"   # serve the chain
        print -r -- "${want}" > "${CERTS}/registry.sans"
        rm -f "${CERTS}/registry.csr"
    fi
    chmod 600 "${CERTS}"/*.key
}

gen_auth() {
    # Declared ONCE: re-declaring an existing local in zsh prints its value.
    local user="" pw=""
    mkdir -p "${AUTHD}"
    chmod 700 "${AUTHD}"
    if [[ ! -f "${AUTHD}/creds.env" ]]; then
        pw="$(python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(32)))')"
        (umask 077; print -r -- "LOCAL_REGISTRY_USER=mirror" > "${AUTHD}/creds.env"; print -r -- "LOCAL_REGISTRY_PASSWORD=${pw}" >> "${AUTHD}/creds.env")
    fi
    user="$(awk -F= '$1=="LOCAL_REGISTRY_USER"{print $2}' "${AUTHD}/creds.env")"
    pw="$(awk -F= '$1=="LOCAL_REGISTRY_PASSWORD"{print substr($0, index($0, "=") + 1)}' "${AUTHD}/creds.env")"
    if [[ ! -s "${AUTHD}/htpasswd" ]]; then
        if command -v htpasswd >/dev/null 2>&1; then
            print -r -- "${pw}" | htpasswd -Bin "${user}" > "${AUTHD}/htpasswd"
        else
            print -r -- "${pw}" | podman run --rm -i --entrypoint htpasswd docker.io/library/httpd:2 -Bin "${user}" > "${AUTHD}/htpasswd"
        fi
        chmod 600 "${AUTHD}/htpasswd"
    fi
    LR_USER="${user}" LR_PASSWORD="${pw}"
}

wait_up() {
    local code ca="$1"
    for _i in {1..30}; do
        code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' --cacert "${ca}" "https://${HOST}:${PORT}/v2/" 2>/dev/null || true)"
        [[ "${code}" == (200|401) ]] && return 0
        sleep 2
    done
    preg_die "The registry did not answer on https://${HOST}:${PORT}/v2/ (does ${HOST} resolve to this machine? set LOCAL_REGISTRY_HOST)"
}

case "${CMD}" in
    up)
        if [[ "${ENGINE}" == mirror-registry ]]; then
            [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || preg_die "mirror-registry needs RHEL x86_64 - use LOCAL_REGISTRY_ENGINE=distribution here."
            MR="${LR}/mirror-registry"
            mkdir -p "${MR}" "${DATA}"
            if [[ ! -x "${MR}/mirror-registry" ]]; then
                curl -fSL -o "${MR}/mirror-registry.tar.gz" "https://mirror.openshift.com/pub/cgw/mirror-registry/latest/mirror-registry-amd64.tar.gz"
                tar -xzf "${MR}/mirror-registry.tar.gz" -C "${MR}"
            fi
            gen_auth
            "${MR}/mirror-registry" install --quayHostname "${HOST}:${PORT}" --quayRoot "${DATA}" \
                --initUser "${LR_USER}" --initPassword "${LR_PASSWORD}"
            CA="${DATA}/quay-rootCA/rootCA.pem"
        else
            mkdir -p "${DATA}"
            gen_certs
            gen_auth
            CA="${CERTS}/ca.crt"
            if podman container exists "${NAME}"; then
                podman start "${NAME}" >/dev/null
            else
                podman run -d --name "${NAME}" --restart=always -p "${PORT}:5000" \
                    -v "${DATA}:/var/lib/registry:Z" -v "${CERTS}:/certs:ro,Z" -v "${AUTHD}:/auth:ro,Z" \
                    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
                    -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
                    -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM="mirror registry" \
                    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
                    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
                    -e REGISTRY_VALIDATION_DISABLED=true \
                    "${IMAGE}" >/dev/null
            fi
        fi
        wait_up "${CA}"
        write_state "${CA}"
        ROOT="${HOST}:${PORT}${NS:+/${NS}}"
        config_fill MIRROR_REGISTRY_ROOT "${ROOT}"
        config_fill MIRROR_REGISTRY_PUSH_USER "${LR_USER}"
        config_fill MIRROR_REGISTRY_PUSH_PASSWORD "${LR_PASSWORD}"
        config_fill MIRROR_REGISTRY_CA_FILE "${CA}"
        preg_info "Local registry up: https://${ROOT} (login: ${LR_USER}; password in ${AUTHD#${_CP4D_REPO_ROOT}/}/creds.env)"
        preg_info "CA for the cluster (3.2) and other machines: ${CA#${_CP4D_REPO_ROOT}/}"
        [[ "$(uname -s)" == Darwin ]] && preg_warn "macOS: the cluster reaches this registry only if ${HOST}:${PORT} is reachable from the cluster network (firewall, podman port forwarding)."
        ;;
    status)
        [[ -f "${STATE}" ]] || { preg_info "No local registry set up (${STATE#${_CP4D_REPO_ROOT}/} missing)."; exit 0; }
        CA="$(awk -F= '$1=="LOCAL_REGISTRY_CA_FILE"{print $2}' "${STATE}")"
        print -r -- "  engine     ${ENGINE}"
        print -r -- "  endpoint   https://${HOST}:${PORT}${NS:+/${NS}}"
        [[ "${ENGINE}" == distribution ]] && print -r -- "  container  $(podman inspect -f '{{.State.Status}}' "${NAME}" 2>/dev/null || print -rn -- 'not created')"
        print -r -- "  /v2/       HTTP $(curl -s -o /dev/null -m 5 -w '%{http_code}' --cacert "${CA}" "https://${HOST}:${PORT}/v2/" 2>/dev/null || true)"
        if [[ -f "${AUTHD}/creds.env" ]]; then
            u="$(awk -F= '$1=="LOCAL_REGISTRY_USER"{print $2}' "${AUTHD}/creds.env")"
            p="$(awk -F= '$1=="LOCAL_REGISTRY_PASSWORD"{print substr($0, index($0, "=") + 1)}' "${AUTHD}/creds.env")"
            n="$(curl_auth "${u}" "${p}" -s -m 10 --cacert "${CA}" "https://${HOST}:${PORT}/v2/_catalog?n=10000" \
                | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("repositories", [])))' 2>/dev/null || print -rn -- '?')"
            print -r -- "  repos      ${n}"
        fi
        print -r -- "  storage    ${DATA} ($(du -sh "${DATA}" 2>/dev/null | cut -f1))"
        ;;
    trust)
        [[ -f "${STATE}" ]] || preg_die "Run '$0 up' first."
        CA="$(awk -F= '$1=="LOCAL_REGISTRY_CA_FILE"{print $2}' "${STATE}")"
        dir="/etc/containers/certs.d/${HOST}:${PORT}"
        if [[ "$(uname -s)" == Darwin ]]; then
            podman machine ssh "sudo mkdir -p '${dir}' && sudo tee '${dir}/ca.crt' >/dev/null" < "${CA}"
            preg_info "Trusted in the podman VM (${dir}). skopeo/oc on the Mac: the steps pass the CA themselves."
        elif [[ -w /etc/containers ]] || command -v sudo >/dev/null 2>&1; then
            sudo mkdir -p "${dir}" && sudo cp "${CA}" "${dir}/ca.crt"
            preg_info "Trusted for podman/skopeo on this host (${dir})."
        else
            preg_warn "Copy ${CA} to ${dir}/ca.crt as root."
        fi
        ;;
    down)
        [[ "${ENGINE}" == distribution ]] && podman stop "${NAME}" >/dev/null 2>&1 || true
        [[ "${ENGINE}" == mirror-registry ]] && preg_warn "Stop mirror-registry with its own installer (${LR}/mirror-registry/mirror-registry uninstall keeps no data)."
        preg_info "Local registry stopped (data kept in ${DATA})."
        ;;
    export)
        out="${1:?usage: $0 export <archive.tar>}"
        podman stop "${NAME}" >/dev/null 2>&1 || true
        tar -C "${DATA:h}" -cf "${out}" "${DATA:t}"
        print -r -- "$(preg_sha256 "${out}")  ${out:t}" > "${out}.sha256"
        podman start "${NAME}" >/dev/null 2>&1 || true
        preg_info "Exported ${DATA} -> ${out} (+ .sha256)"
        ;;
    import)
        in="${1:?usage: $0 import <archive.tar>}"
        if [[ -f "${in}.sha256" ]]; then
            [[ "$(preg_sha256 "${in}")" == "$(awk '{print $1}' "${in}.sha256")" ]] || preg_die "Checksum mismatch for ${in}"
        fi
        podman stop "${NAME}" >/dev/null 2>&1 || true
        mkdir -p "${DATA:h}"
        tar -C "${DATA:h}" -xf "${in}"
        podman start "${NAME}" >/dev/null 2>&1 || true
        preg_info "Imported ${in} into ${DATA}"
        ;;
    rm)
        [[ "${1:-}" == --yes ]] || preg_die "This deletes the registry data and certificates. Re-run with: $0 rm --yes"
        podman rm -f "${NAME}" >/dev/null 2>&1 || true
        rm -rf "${LR}"
        [[ "${DATA}" == "${LR}"/* ]] || preg_warn "LOCAL_REGISTRY_DIR (${DATA}) is outside the workspace - not deleted."
        preg_info "Local registry removed."
        ;;
    *)
        sed -n '/^# 0.3/,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
