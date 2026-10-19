#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# 'sh script.sh' ignores the shebang and runs bash, which can't run this; switch to zsh
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

set -euo pipefail

# Writes an S3 backup bucket config to backup_bucket_configs/<name>_bucket.sh
# (gitignored, owner-only). The OADP DataProtectionApplication on both the source
# and the restore target cluster is pointed at this bucket, so the same config
# is used on both sides. The bucket must already exist; this script does not
# create it or check that it is reachable (2_install_oadp_br_utilities.sh does,
# by waiting for the backup storage location to become Available).
#
# The bucket has to live outside the source cluster for a backup to survive it
# (AWS S3, IBM Cloud Object Storage, MinIO/Ceph elsewhere, ...).
#
# Run with no options, it writes a template named bucket-<6 hex chars> with the
# connection values empty and every field explained in the file; fill it in by
# hand. Options fill in what they name. --interactive asks for the rest instead
# (secrets without echo).
#
#   1.1_generate_backup_bucket_config.sh [options]
#     --name <name>               config name (file: <name>_bucket.sh; default bucket-<id>)
#     --s3-url <url>              S3 endpoint, e.g. https://s3.us-south.cloud-object-storage.appdomain.cloud
#                                 or https://minio.example.com:9000. Pass '' for AWS S3.
#     --bucket-name <bucket>      existing bucket
#     --prefix <prefix>           folder inside the bucket (default cpdbackup)
#     --region <region>           e.g. us-east-1, us-south (default us-east-1; MinIO: minio)
#     --path-style true|false     s3ForcePathStyle; true for COS/MinIO/Ceph, false for AWS
#                                 (default true; false with --s3-url '')
#     --access-key-id <key>       HMAC / S3 access key
#     --secret-access-key <key>   HMAC / S3 secret key
#     --cacert-file <file>        CA bundle for a self-signed endpoint; copied next to the config
#     -i, --interactive           ask for the values not given as options
#     --force                     overwrite an existing config with that name
#     -h, --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Repo root only for now: the env is loaded after the options are parsed,
# because --target decides which config to load.
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; unset _b
source "${REPO_ROOT}/src/helpers/oadp_br_helpers.sh"

CFG_NAME=""
OADP_S3_URL="__unset__"
OADP_BUCKET_NAME=""
OADP_BUCKET_PREFIX=""
OADP_S3_REGION=""
OADP_S3_FORCE_PATH_STYLE=""
OADP_S3_ACCESS_KEY_ID=""
OADP_S3_SECRET_ACCESS_KEY=""
CACERT_SRC=""
OADP_INTERACTIVE=false
FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)              CFG_NAME="${2:?--name needs a value}"; shift 2 ;;
        --s3-url)            OADP_S3_URL="${2?--s3-url needs a value}"; shift 2 ;;
        --bucket-name)       OADP_BUCKET_NAME="${2:?--bucket-name needs a value}"; shift 2 ;;
        --prefix)            OADP_BUCKET_PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
        --region)            OADP_S3_REGION="${2:?--region needs a value}"; shift 2 ;;
        --path-style)        OADP_S3_FORCE_PATH_STYLE="${2:?--path-style needs true or false}"; shift 2 ;;
        --access-key-id)     OADP_S3_ACCESS_KEY_ID="${2:?--access-key-id needs a value}"; shift 2 ;;
        --secret-access-key) OADP_S3_SECRET_ACCESS_KEY="${2:?--secret-access-key needs a value}"; shift 2 ;;
        --cacert-file)       CACERT_SRC="${2:?--cacert-file needs a path}"; shift 2 ;;
        -i|--interactive)    OADP_INTERACTIVE=true; shift ;;
        --force)             FORCE=true; shift ;;
        -h|--help)           oadp_usage "$0"; exit 0 ;;
        *)                   echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done

oadp_prompt CFG_NAME "Config name" "bucket-$(oadp_short_id)"
if [[ ! "${CFG_NAME}" =~ '^[A-Za-z0-9][A-Za-z0-9_.-]*$' ]]; then
    echo "[ERROR] Config name may only contain letters, digits, '.', '_' and '-' (got '${CFG_NAME}')." >&2
    exit 1
fi
OUT_FILE="${BUCKET_CONFIG_DIR}/${CFG_NAME}${BUCKET_CONFIG_SUFFIX}"
if [[ -f "${OUT_FILE}" && "${FORCE}" != "true" ]]; then
    echo "[ERROR] ${OUT_FILE} already exists. Pass --force to overwrite it." >&2
    exit 1
fi

# The S3 URL may legitimately be empty (AWS S3), so it is told apart from "not given".
AWS_S3=false
if [[ "${OADP_S3_URL}" == "__unset__" ]]; then
    OADP_S3_URL=""
    if [[ "${OADP_INTERACTIVE}" == "true" && -t 0 ]]; then
        read -r "OADP_S3_URL?S3 endpoint URL (empty for AWS S3): "
        [[ -z "${OADP_S3_URL}" ]] && AWS_S3=true
    fi
elif [[ -z "${OADP_S3_URL}" ]]; then
    AWS_S3=true
fi
oadp_prompt OADP_BUCKET_NAME "Bucket name"
oadp_prompt OADP_BUCKET_PREFIX "Prefix inside the bucket" "cpdbackup"
oadp_prompt OADP_S3_REGION "Region" "us-east-1"
oadp_prompt OADP_S3_FORCE_PATH_STYLE "Force path-style URLs (true for COS/MinIO/Ceph, false for AWS)" "$([[ "${AWS_S3}" == "true" ]] && echo false || echo true)"
oadp_prompt OADP_S3_ACCESS_KEY_ID "Access key ID"
oadp_prompt OADP_S3_SECRET_ACCESS_KEY "Secret access key" "" secret

if [[ "${OADP_S3_FORCE_PATH_STYLE}" != "true" && "${OADP_S3_FORCE_PATH_STYLE}" != "false" ]]; then
    echo "[ERROR] --path-style must be true or false (got '${OADP_S3_FORCE_PATH_STYLE}')." >&2
    exit 1
fi
if [[ -n "${OADP_S3_URL}" && ! "${OADP_S3_URL}" =~ '^https?://' ]]; then
    echo "[ERROR] The S3 URL must start with http:// or https:// (got '${OADP_S3_URL}')." >&2
    exit 1
fi

mkdir -p "${BUCKET_CONFIG_DIR}"
chmod 700 "${BUCKET_CONFIG_DIR}"

CACERT_FILE=""
if [[ -n "${CACERT_SRC}" ]]; then
    [[ -f "${CACERT_SRC}" ]] || { echo "[ERROR] CA file not found: ${CACERT_SRC}" >&2; exit 1; }
    CACERT_FILE="${BUCKET_CONFIG_DIR}/${CFG_NAME}_ca.crt"
    cp "${CACERT_SRC}" "${CACERT_FILE}"
    chmod 600 "${CACERT_FILE}"
fi

umask 077
{
    print -r -- "#==============================================================================="
    print -r -- "# OADP backup bucket: ${CFG_NAME}"
    print -r -- "# Generated by $(basename "$0") on $(date '+%Y-%m-%d %H:%M:%S')"
    print -r -- "# Contains object storage credentials - keep it out of git (it is gitignored)."
    print -r -- "# The bucket must already exist and live outside the cluster being backed up."
    print -r -- "#==============================================================================="
    print -r -- ""
    print -r -- "export OADP_BUCKET_CONFIG_NAME=${(qq)CFG_NAME}"
    print -r -- ""
    print -r -- "# S3 endpoint, e.g. https://s3.us-south.cloud-object-storage.appdomain.cloud (IBM COS)"
    print -r -- "# or https://minio.example.com:9000. Leave empty only for AWS S3."
    print -r -- "export OADP_S3_URL=${(qq)OADP_S3_URL}"
    print -r -- "# Existing bucket, and the folder inside it the backups go to"
    print -r -- "export OADP_BUCKET_NAME=${(qq)OADP_BUCKET_NAME}"
    print -r -- "export OADP_BUCKET_PREFIX=${(qq)OADP_BUCKET_PREFIX}"
    print -r -- "# Region, e.g. us-east-1, us-south (IBM COS), minio (MinIO)"
    print -r -- "export OADP_S3_REGION=${(qq)OADP_S3_REGION}"
    print -r -- "# s3ForcePathStyle: true for IBM COS / MinIO / Ceph, false for AWS S3"
    print -r -- "export OADP_S3_FORCE_PATH_STYLE=${(qq)OADP_S3_FORCE_PATH_STYLE}"
    print -r -- "# HMAC / S3 credentials with read and write access to the bucket"
    print -r -- "export OADP_S3_ACCESS_KEY_ID=${(qq)OADP_S3_ACCESS_KEY_ID}"
    print -r -- "export OADP_S3_SECRET_ACCESS_KEY=${(qq)OADP_S3_SECRET_ACCESS_KEY}"
    print -r -- "# CA bundle file for a self-signed endpoint (empty: system trust)"
    print -r -- "export OADP_S3_CACERT_FILE=${(qq)CACERT_FILE}"
} > "${OUT_FILE}"
# 700, not 600: env_bootstrap.sh chmods every .sh +x, and re-runs that prep while any is not.
chmod 700 "${OUT_FILE}"

echo "[OK] Wrote ${OUT_FILE}"
TODO_VARS=(OADP_BUCKET_NAME OADP_S3_ACCESS_KEY_ID OADP_S3_SECRET_ACCESS_KEY)
# An empty URL the user did not ask for (AWS) is most likely still to be filled in.
[[ "${AWS_S3}" != "true" ]] && TODO_VARS=(OADP_S3_URL "${TODO_VARS[@]}")
oadp_report_empty "${OUT_FILE}" "${TODO_VARS[@]}" || true
echo "[INFO] Next: ${SCRIPT_DIR}/2_install_oadp_br_utilities.sh --bucket ${CFG_NAME}"
