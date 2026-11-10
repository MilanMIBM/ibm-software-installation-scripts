SCRIPT_DIR="${0:A:h}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done
source "${_b}/src/helpers/multi_cluster_helpers.sh"
_mcm_rc=0
mcm_is_on || _mcm_rc=$?
(( _mcm_rc != 2 )) || exit 1
_mcm_loader=$(( _mcm_rc == 0 ))
# A delineated cluster (one with a .cluster marker) makes the config depend on the
# cluster even with the mode off: a target flag or MCM_CLUSTER pins it, and a flat
# config pointing at it is refused. A target flag with nothing delineated is the
# loader's error to give. Only with neither are the two flat files sourced as before.
[[ -n "$(mcm_delineated_clusters)" ]] && _mcm_loader=1
for _a in "$@"; do
    [[ "${_a}" == --target-cluster(|s)(|=*) || "${_a}" == --all-clusters ]] && _mcm_loader=1
done
if (( _mcm_loader )); then
    # Only calls the Software Hub API, so skip the loader's podman machine start.
    export _CP4D_PREP_DONE=1
    source "${_b}/env_bootstrap.sh"
else
    source configs/cp4d_config/cpd_vars.sh
    source configs/cp4d_config/cpd_instance_details.sh
fi
unset _b _mcm_rc _mcm_loader _a
source "${SCRIPT_DIR}/../../helpers/cpd_api_helpers.sh"

cpdapi_login "${CPD_URL}" "${CPD_USERNAME}" password "${CPD_PASSWORD}" \
  || { echo "[ERROR] Could not sign in to ${CPD_URL} as ${CPD_USERNAME} (HTTP ${API_CODE})." >&2; exit 1; }
TOKEN="${CPDAPI_TOKEN}"

# Now query all registered addons
curl -k -s -X POST "${CPD_URL}/zen-data/v1/addOn/query" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -c "import sys,json; [print(s['Type'], s.get('State','?')) for s in json.load(sys.stdin)['requestObj']]"
