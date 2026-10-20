#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/datastax_mc_config/datastax_mc_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-datastax_mc}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helpers.sh"
mc_require_config

# ==============================================================================
# 2.0 Render the Helm values files for this plane into configs/datastax_mc_config/
# ------------------------------------------------------------------------------
# Layers, applied in this order by 2.1 (later files win, null removes a key):
#   mc-values-<plane>.yaml          DataStax's OpenShift values file (template in
#                                   src/helpers/datastax_mc_helm_values_templates/)
#                                   with its **TOKENS** filled in
#   mc-values-overrides.yaml        this repo's settings: pull secret, storage
#                                   classes/sizes, observability storage (minio
#                                   or s3) and the Loki schema
#   mc-values-restricted-scc.yaml   only with MC_SCC_MODE=restricted-v2
#   MC_EXTRA_VALUES_FILES           your own files, space-separated, last
# The order is written to helm-values-files.txt, which 2.1 reads.
#
# Where DataStax's OpenShift control plane file does not match chart 1.21.2,
# the overrides correct it (each one broke a real install):
#   - Loki schema: the file uses boltdb-shipper v11; chart 1.21 ships Loki 3.x,
#     whose structured metadata needs tsdb v13 (the chart's own default).
#   - Loki affinity: the file writes read/write/backend/gateway affinity as YAML
#     strings; the Loki chart puts them into the pod spec as-is, which the API
#     rejects ("cannot unmarshal string ... of type v1.Affinity"). Re-set as maps.
#   - Object storage credentials: the file puts them in mimir.mimir.extraEnv*
#     (ignored by the Mimir chart) and in loki.backend only, so Mimir and Loki
#     read/write got "Access Denied". Supplied via each chart's global.extraEnvFrom.
#   - Dex: the file sets an http issuer and replaces Dex's volumes with /tmp only,
#     dropping the TLS mount that chart 1.21's HTTPS listener needs ("watch dir
#     for TLS reloader: no such file or directory"). The chart defaults are restored.
#   - Loki backend args: the file's loki.backend.extraArgs (only expand-env)
#     replaces the chart's list of ~30 flags, so the backend ran without the
#     internal TLS the read/write pods use; they could not join it ("unknown
#     message type", read pod never ready). The key is dropped while rendering,
#     and expand-env comes from loki.global.extraArgs instead.
#   Of the file's lists, only these replaced chart defaults (checked on 1.21.2).
# ==============================================================================

mc_require_vars MC_ADMIN_EMAIL MC_ADMIN_PASSWORD MC_STORAGE_CLASS MC_VECTOR_VOLUME_SIZE MC_PULL_SECRET_NAME

OUT_DIR="${MC_CONFIG_DIR}"
mkdir -p "${OUT_DIR}"
BASE_SRC="${MC_VALUES_SRC_DIR}/openshift-${MC_PLANE}-plane.yaml"
BASE_OUT="${OUT_DIR}/mc-values-${MC_PLANE}.yaml"
OVR_OUT="${OUT_DIR}/mc-values-overrides.yaml"
RSCC_OUT="${OUT_DIR}/mc-values-restricted-scc.yaml"
ORDER_OUT="${OUT_DIR}/helm-values-files.txt"
[[ -f "${BASE_SRC}" ]] || mc_die "Missing ${BASE_SRC}"

umask 077
ADMIN_HASH="$(mc_bcrypt "${MC_ADMIN_PASSWORD}")"
ADMIN_USER_ID="00000000-0000-0000-0000-000000000000"
S3_ACCESS_ENV="AWS_ACCESS_KEY_ID"
S3_SECRET_ENV="AWS_SECRET_ACCESS_KEY"

# --- Observability storage endpoint (control plane) ---------------------------
STORE="${MC_OBSERVABILITY_STORE:-minio}"
if [[ "${MC_PLANE}" == control ]]; then
    case "${STORE}" in
        minio)
            mc_require_vars MC_MINIO_ROOT_USER MC_MINIO_ROOT_PASSWORD
            S3_ENDPOINT="${MC_RELEASE_NAME}-minio.${MC_NAMESPACE}.svc:9000"
            S3_REGION="${MC_S3_REGION:-us-east-1}"
            S3_INSECURE=true
            S3_PATH_STYLE=true ;;
        s3)
            mc_require_vars MC_S3_REGION MC_S3_ACCESS_KEY_ID MC_S3_SECRET_ACCESS_KEY MC_LOGS_BUCKET MC_METRICS_BUCKET
            S3_REGION="${MC_S3_REGION}"
            S3_ENDPOINT="${MC_S3_ENDPOINT:-s3.${S3_REGION}.amazonaws.com}"
            [[ "${S3_ENDPOINT}" == *://* ]] && mc_die "MC_S3_ENDPOINT must be host[:port] without a scheme (got '${S3_ENDPOINT}')."
            mc_is_true "${MC_S3_INSECURE:-false}" && S3_INSECURE=true || S3_INSECURE=false
            mc_is_true "${MC_S3_FORCE_PATH_STYLE:-false}" && S3_PATH_STYLE=true || S3_PATH_STYLE=false ;;
        *) mc_die "MC_OBSERVABILITY_STORE must be minio or s3 (got '${STORE}')." ;;
    esac
else
    mc_require_vars MC_VECTOR_AGGREGATOR_URL
    S3_REGION="${MC_S3_REGION:-us-east-1}"
fi

# --- 1) DataStax base file with its tokens filled in --------------------------
# Tokens that are a whole YAML value are written as quoted strings; tokens inside
# a larger scalar (REGION, the env var names) are inserted raw and must be plain.
MC_TOK_ADMIN_EMAIL="${MC_ADMIN_EMAIL}" \
MC_TOK_HASHED_ADMIN_PASSWORD="${ADMIN_HASH}" \
MC_TOK_ADMIN_USER_ID="${ADMIN_USER_ID}" \
MC_TOK_OBSERVABILITY_VECTOR_VOLUME_SIZE="${MC_VECTOR_VOLUME_SIZE}" \
MC_TOK_OBSERVABILITY_VECTOR_STORAGE_CLASS="${MC_STORAGE_CLASS}" \
MC_TOK_VECTOR_VOLUME_SIZE="${MC_VECTOR_VOLUME_SIZE}" \
MC_TOK_VECTOR_STORAGE_CLASS="${MC_STORAGE_CLASS}" \
MC_TOK_VECTOR_AGGREGATOR_URL="${MC_VECTOR_AGGREGATOR_URL:-}" \
MC_TOK_OBSERVABILITY_LOGS_STORAGE_RETENTION="${MC_LOGS_RETENTION:-7d}" \
MC_TOK_OBSERVABILITY_LOGS_BUCKET_NAME="${MC_LOGS_BUCKET:-loki-chunks}" \
MC_TOK_OBSERVABILITY_BUCKET_NAME="${MC_METRICS_BUCKET:-mimir-tsdb}" \
MC_TOK_OBSERVABILITY_METRICS_STORAGE_CLASS="${MC_STORAGE_CLASS}" \
MC_TOK_OBSERVABILITY_METRICS_STORAGE_RETENTION="${MC_METRICS_RETENTION:-7d}" \
MC_TOK_OBSERVABILITY_METRICS_ALERTS_VOLUME_SIZE="${MC_METRICS_ALERTS_VOLUME_SIZE:-1Gi}" \
MC_TOK_OBSERVABILITY_METRICS_COMPACTOR_VOLUME_SIZE="${MC_METRICS_COMPACTOR_VOLUME_SIZE:-5Gi}" \
MC_TOK_OBSERVABILITY_METRICS_INGESTER_VOLUME_SIZE="${MC_METRICS_INGESTER_VOLUME_SIZE:-10Gi}" \
MC_TOK_OBSERVABILITY_METRICS_STORE_GATEWAY_VOLUME_SIZE="${MC_METRICS_STORE_GATEWAY_VOLUME_SIZE:-5Gi}" \
MC_TOK_OBSERVABILITY_S3_REGION="${S3_REGION}" \
MC_TOK_REGION="${S3_REGION}" \
MC_TOK_OBSERVABILITY_S3_SECRET_NAME="${MC_S3_SECRET_NAME:-${MC_RELEASE_NAME}-observability-s3}" \
MC_TOK_OBSERVABILITY_S3_ACCESS_KEY_ENV_VAR="${S3_ACCESS_ENV}" \
MC_TOK_OBSERVABILITY_S3_SECRET_KEY_ENV_VAR="${S3_SECRET_ENV}" \
MC_TOK_OBSERVABILITY_S3_ACCESS_KEY_SECRET_KEY="${S3_ACCESS_ENV}" \
MC_TOK_OBSERVABILITY_S3_SECRET_KEY_SECRET_KEY="${S3_SECRET_ENV}" \
python3 - "${BASE_SRC}" "${BASE_OUT}" <<'PY'
import json, os, re, sys

src, dst = sys.argv[1], sys.argv[2]
token = re.compile(r"\*\*([A-Z0-9_]+)\*\*")
whole = re.compile(r"^(\s*(?:- )?[\w.-]*:?\s*)\*\*([A-Z0-9_]+)\*\*\s*$")
plain = re.compile(r"^[A-Za-z0-9._:/-]*$")
missing = set()

def value(name):
    v = os.environ.get("MC_TOK_" + name)
    if v is None:
        missing.add(name)
        return ""
    return v

# Keys dropped from DataStax's file so the chart's defaults apply (see header).
DROP = {("loki", "backend", "extraArgs")}
keyline = re.compile(r"^(\s*)([\w.-]+):")

out = []
path = []          # [(indent, key)] of the enclosing mapping keys
skip_indent = None # dropping lines indented deeper than this
with open(src) as f:
    for line in f:
        if line.lstrip().startswith("#"):
            continue
        if line.strip():
            indent = len(line) - len(line.lstrip())
            if skip_indent is not None:
                # list items may sit at the dropped key's own indent
                if indent > skip_indent or (indent == skip_indent and line.lstrip().startswith("- ")):
                    continue
                skip_indent = None
            k = keyline.match(line)
            if k:
                while path and path[-1][0] >= indent:
                    path.pop()
                path.append((indent, k.group(2)))
                if tuple(p[1] for p in path) in DROP:
                    skip_indent = indent
                    continue
        m = whole.match(line.rstrip("\n"))
        if m:
            out.append(f"{m.group(1)}{json.dumps(value(m.group(2)))}\n")
            continue
        def raw(m):
            v = value(m.group(1))
            if not plain.match(v):
                sys.exit(f"[ERROR] {m.group(1)}={v!r} is used inside a larger value and must be plain text")
            return v
        out.append(token.sub(raw, line))

if missing:
    sys.exit("[ERROR] No value for token(s): " + ", ".join(sorted(missing)))
with open(dst, "w") as f:
    f.write(f"# Rendered by 2.0_render_values.sh from {os.path.basename(src)} - do not edit, re-run 2.0\n")
    f.writelines(out)
PY
mc_info "Base values:      ${BASE_OUT#${_CP4D_REPO_ROOT}/}"

# --- 2) Repo overrides ---------------------------------------------------------
y() { mc_yaml_str "$1"; }
SC="$(y "${MC_STORAGE_CLASS}")"
S3_SECRET="$(y "${MC_S3_SECRET_NAME:-${MC_RELEASE_NAME}-observability-s3}")"
# Same placement as DataStax's file, but as a map (see header).
PLATFORM_AFFINITY="{nodeAffinity: {requiredDuringSchedulingIgnoredDuringExecution: {nodeSelectorTerms: [{matchExpressions: [{key: mission-control.datastax.com/role, operator: In, values: [platform]}]}]}}}"
{
    echo "# Rendered by 2.0_render_values.sh - do not edit, re-run 2.0"
    echo "global:"
    echo "  imageConfig:"
    echo "    defaults:"
    echo "      pullSecrets:"
    echo "        - $(y "${MC_PULL_SECRET_NAME}")"
    if [[ "${MC_PLANE}" == control ]]; then
        echo "ui:"
        echo "  baseUrl: $(y "${MC_UI_BASE_URL:-}")"
        echo "dex:"
        echo "  config:"
        echo "    issuer: \"https://${MC_RELEASE_NAME}-dex:5554/dex\""
        echo "  volumes:"
        echo "    - {name: tmp-dir, emptyDir: {}}"
        echo "    - {name: tls-certs, secret: {secretName: mission-control-dex-tls, defaultMode: 420}}"
        echo "  volumeMounts:"
        echo "    - {name: tmp-dir, mountPath: /tmp, readOnly: false}"
        echo "    - {name: tls-certs, mountPath: /etc/dex/tls, readOnly: true}"
        echo "loki:"
        echo "  global:"
        echo "    extraArgs: [\"-config.expand-env=true\"]"
        echo "    extraEnvFrom: [{secretRef: {name: ${S3_SECRET}}}]"
        echo "  backend:"
        echo "    affinity: ${PLATFORM_AFFINITY}"
        echo "    persistence: {size: $(y "${MC_LOKI_VOLUME_SIZE:-10Gi}"), storageClass: ${SC}}"
        echo "  write:"
        echo "    affinity: ${PLATFORM_AFFINITY}"
        echo "    persistence: {size: $(y "${MC_LOKI_VOLUME_SIZE:-10Gi}"), storageClass: ${SC}}"
        echo "  read:"
        echo "    affinity: ${PLATFORM_AFFINITY}"
        echo "    persistence: {size: $(y "${MC_LOKI_VOLUME_SIZE:-10Gi}"), storageClass: ${SC}, storageClassName: ${SC}}"
        echo "  gateway:"
        echo "    affinity: ${PLATFORM_AFFINITY}"
        echo "  loki:"
        echo "    schemaConfig:"
        echo "      configs:"
        echo "        - from: \"2025-06-13\""
        echo "          object_store: s3"
        echo "          store: tsdb"
        echo "          schema: v13"
        echo "          index: {period: 24h, prefix: mc_loki_}"
        echo "    storage:"
        echo "      s3:"
        echo "        endpoint: $(y "${S3_ENDPOINT}")"
        echo "        region: $(y "${S3_REGION}")"
        echo "        s3: null"
        echo "        insecure: ${S3_INSECURE}"
        echo "        s3ForcePathStyle: ${S3_PATH_STYLE}"
        echo "mimir:"
        echo "  global:"
        echo "    extraEnvFrom: [{secretRef: {name: ${S3_SECRET}}}]"
        echo "  nginx:"
        echo "    affinity: ${PLATFORM_AFFINITY}"
        echo "  mimir:"
        echo "    structuredConfig:"
        echo "      blocks_storage:"
        echo "        s3:"
        echo "          endpoint: $(y "${S3_ENDPOINT}")"
        echo "          region: $(y "${S3_REGION}")"
        echo "          insecure: ${S3_INSECURE}"
        if [[ "${STORE}" == minio ]]; then
            echo "  minio:"
            echo "    enabled: true"
            echo "    rootUser: $(y "${MC_MINIO_ROOT_USER}")"
            echo "    rootPassword: $(y "${MC_MINIO_ROOT_PASSWORD}")"
            echo "    persistence: {size: $(y "${MC_MINIO_VOLUME_SIZE:-20Gi}"), storageClass: ${SC}}"
            echo "    users: []"
            echo "    buckets:"
            _buckets=("${MC_METRICS_BUCKET:-mimir-tsdb}" mimir-ruler "${MC_LOGS_BUCKET:-loki-chunks}" loki-ruler loki-admin mc-medusa)
            for _bucket in "${(@u)_buckets}"; do
                echo "      - {name: $(y "${_bucket}"), policy: none, purge: false}"
            done
        else
            echo "  minio:"
            echo "    enabled: false"
        fi
    fi
} > "${OVR_OUT}"
if [[ "${MC_PLANE}" == control ]]; then
    mc_info "Overrides:        ${OVR_OUT#${_CP4D_REPO_ROOT}/} (observability store: ${STORE})"
else
    mc_info "Overrides:        ${OVR_OUT#${_CP4D_REPO_ROOT}/}"
fi

# --- 3) restricted-v2 ---------------------------------------------------------
# DataStax's openshift-overrides-restricted-scc.yaml, minus its dev/test Loki
# filesystem mode (the storage above stays in charge), plus the nulls its own
# docs call for but the file omits: the operator's container-level UID and the
# Vector aggregator's pod/container UIDs.
rm -f "${RSCC_OUT}"
if [[ "${MC_SCC_MODE}" == restricted-v2 ]]; then
    cat > "${RSCC_OUT}" <<'EOF'
# Rendered by 2.0_render_values.sh (MC_SCC_MODE=restricted-v2) - do not edit, re-run 2.0
podSecurityContext: null
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
  runAsUser: null
  runAsGroup: null
k8ssandra-operator:
  podSecurityContext: null
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop: [ALL]
    seccompProfile:
      type: RuntimeDefault
    runAsUser: null
    runAsGroup: null
  cass-operator:
    podSecurityContext: null
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
      seccompProfile:
        type: RuntimeDefault
      runAsUser: null
      runAsGroup: null
aggregator:
  podSecurityContext: null
  securityContext:
    runAsUser: null
agent:
  podSecurityContext: null
loki:
  rbac:
    sccEnabled: true
  podSecurityContext: null
EOF
    mc_info "restricted-v2:    ${RSCC_OUT#${_CP4D_REPO_ROOT}/}"
fi

# --- Order file -----------------------------------------------------------------
{
    print -r -- "${BASE_OUT}"
    print -r -- "${OVR_OUT}"
    [[ -f "${RSCC_OUT}" ]] && print -r -- "${RSCC_OUT}"
    for _extra in ${=MC_EXTRA_VALUES_FILES:-}; do
        [[ -f "${_extra}" ]] || mc_die "MC_EXTRA_VALUES_FILES: ${_extra} not found."
        print -r -- "${_extra:A}"
    done
} > "${ORDER_OUT}"
mc_info "Helm -f order:    ${ORDER_OUT#${_CP4D_REPO_ROOT}/}"
sed 's/^/                    /' "${ORDER_OUT}"
