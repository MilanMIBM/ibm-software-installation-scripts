source cp4d_config/cpd_vars.sh
source cp4d_config/cpd_instance_details.sh

TOKEN=$(curl -k -s -X POST "${CPD_URL}/icp4d-api/v1/authorize" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${CPD_USERNAME}\",\"password\":\"${CPD_PASSWORD}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# Now query all registered addons
curl -k -s -X POST "${CPD_URL}/zen-data/v1/addOn/query" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -c "import sys,json; [print(s['Type'], s.get('State','?')) for s in json.load(sys.stdin)['requestObj']]"
