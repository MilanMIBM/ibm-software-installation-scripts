#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/ocp_utils_helpers.sh"

# Local oc + jq (CPDM_OC_LOGIN only logs in the cpd-cli container).
eval "${OC_LOGIN}"

# Fixes the authentication ClusterOperator being Degraded with e.g.
#   OAuthServerConfigObservationDegraded: error validating secret
#   openshift-config/htpasswd-secret: secret "htpasswd-secret" not found
# by removing every identity provider in oauth/cluster whose secret is missing
# from openshift-config. Nobody can log in through such a provider anyway.
# Re-add a password login afterwards with set_htpasswd_users.sh if needed.
# Usage: x_fix_oauth_missing_idp_secret.sh [--dry-run]
#---
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
#---

SECRETS_JSON=$(oc get secrets -n openshift-config -o json | jq '[.items[].metadata.name]')
OAUTH_JSON=$(oc get oauth cluster -o json)

# Secret an identity provider points at, by provider type ("" if none).
_IDP_SECRET='(.htpasswd.fileData.name // .ldap.bindPassword.name // .openID.clientSecret.name
              // .github.clientSecret.name // .gitlab.clientSecret.name // .google.clientSecret.name
              // .keystone.tlsClientKey.name // .basicAuth.tlsClientKey.name // "")'

BROKEN=(${(f)"$(jq -r --argjson s "${SECRETS_JSON}" "
    (.spec.identityProviders // [])[] | ${_IDP_SECRET} as \$sec
    | select(\$sec != \"\" and (\$sec | IN(\$s[]) | not))
    | \"\(.name) (secret: \(\$sec))\"" <<< "${OAUTH_JSON}")"})

if [[ -z "${BROKEN[1]:-}" ]]; then
    echo "[INFO] All identity providers have their secrets. Nothing to fix."
    oc get co authentication
    exit 0
fi

echo "[INFO] Identity providers with a missing secret in openshift-config:"
printf '  - %s\n' "${BROKEN[@]}"

if ${DRY_RUN}; then
    echo "[DRY-RUN] Would remove them from oauth/cluster."
    exit 0
fi

KEPT=$(jq -c --argjson s "${SECRETS_JSON}" "
    [(.spec.identityProviders // [])[] | ${_IDP_SECRET} as \$sec
     | select(\$sec == \"\" or (\$sec | IN(\$s[])))]" <<< "${OAUTH_JSON}")

oc patch oauth cluster --type=merge -p "{\"spec\":{\"identityProviders\":${KEPT}}}"
echo "[OK] Removed ${#BROKEN} identity provider(s). Remaining: $(jq -r 'map(.name) | join(", ")' <<< "${KEPT}")"
echo "[INFO] If a GitOps tool (e.g. TechZone ArgoCD) owns oauth/cluster, it may put them back."

htpw_wait_auth_rollout
oc get co authentication
