#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh - runs one IBM Concert installer script (bin/setup, ...) the
# same way in every runner mode of scripts/install_ibm_concert:
#
#   cluster    Job in the installer namespace (this image)
#   container  podman run on the workstation (this image)
#   native     a Linux x86 bastion, called directly with the env vars below
#
# Usage:  entrypoint.sh <path relative to the ibm-concert dir> [args...]
#         entrypoint.sh __shell__ '<bash command>'   (debugging / log access)
#
# Env:
#   CONCERT_VERSION        required - selects /work/<version>/ibm-concert
#   CONCERT_WORK_DIR       default /work (a PVC in cluster mode)
#   CONCERT_ARCHIVE_PATH   default /opt/concert/ibm-concert.tar.gz
#   CONCERT_FILES_DIR      default /config/files (params.ini, override values, certs)
#
# The archive is extracted once per version. IBM's installer keeps its state
# in the cluster; locally it only writes per-run files and logs, which stay on
# the work volume so a later run (or x_fetch_installer_logs.sh) can read them.
# =============================================================================
set -euo pipefail

: "${CONCERT_VERSION:?CONCERT_VERSION must be set}"
WORK_DIR="${CONCERT_WORK_DIR:-/work}"
ARCHIVE="${CONCERT_ARCHIVE_PATH:-/opt/concert/ibm-concert.tar.gz}"
FILES_DIR="${CONCERT_FILES_DIR:-/config/files}"

export HOME="${WORK_DIR}/home"
# bin/oc pins ambiguous resource names (see the file) for IBM's scripts.
export PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin:${PATH}"
mkdir -p "${HOME}"

INSTALL_ROOT="${WORK_DIR}/${CONCERT_VERSION}"
INSTALL_DIR="${INSTALL_ROOT}/ibm-concert"

if [[ ! -f "${INSTALL_ROOT}/.extracted" ]]; then
    echo "[runner] Extracting $(basename "${ARCHIVE}") into ${INSTALL_ROOT}"
    mkdir -p "${INSTALL_ROOT}"
    tar -xzf "${ARCHIVE}" -C "${INSTALL_ROOT}"
    touch "${INSTALL_ROOT}/.extracted"
fi

# params.ini always comes from the config, never from an earlier run's copy:
# IBM's upgrade path reads etc/params.ini, so it must match concert_vars.sh.
# File references in it are written as /config/files/<name>; point them at
# wherever the files really are (differs only for the native runner).
if [[ -f "${FILES_DIR}/params.ini" ]]; then
    sed "s#/config/files/#${FILES_DIR}/#g" "${FILES_DIR}/params.ini" > "${INSTALL_DIR}/etc/params.ini"
fi

echo "[runner] arch=$(uname -m) user=$(id -u) version=${CONCERT_VERSION} dir=${INSTALL_DIR}"
cd "${INSTALL_DIR}"

script="${1:?usage: entrypoint.sh <script> [args...]}"
shift

if [[ "${script}" == "__shell__" ]]; then
    exec bash -c "$*"
fi

case "${script}" in
    /*|*..*) echo "[runner] refusing script path outside the installer: ${script}" >&2; exit 2 ;;
esac
if [[ ! -x "${INSTALL_DIR}/${script}" ]]; then
    echo "[runner] not found or not executable: ${INSTALL_DIR}/${script}" >&2
    exit 2
fi

exec "./${script}" "$@"
