source configs/cp4d_config/cpd_vars.sh
source configs/cp4d_config/cpd_instance_details.sh
source "${0:A:h}/../../helpers/cpd_api_helpers.sh"

cpdapi_login "${CPD_URL}" "${CPD_USERNAME}" password "${CPD_PASSWORD}" \
  || { echo "[ERROR] Could not sign in to ${CPD_URL} as ${CPD_USERNAME} (HTTP ${API_CODE})." >&2; exit 1; }
TOKEN="${CPDAPI_TOKEN}"

# Now query all registered addons
curl -k -s -X POST "${CPD_URL}/zen-data/v1/addOn/query" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -c "import sys,json; [print(s['Type'], s.get('State','?')) for s in json.load(sys.stdin)['requestObj']]"
