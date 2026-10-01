#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ---

for var in OC_LOGIN CPDM_OC_LOGIN PREP_DB2; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${OC_LOGIN}"
DB2_USERNAME="db2admin"
DB2_PASSWORD="apass123!"
export DB2_Version="12.1.3.0-cn3-${IMAGE_ARCH}"
DB2_CPU_LIMIT="2" # 2vCPUs also can be defined as "2000m"
DB2_MEMORY_LIMIT="8Gi" # 8GB
DB2_STORAGE_CLAIM=30 # 30GB default, applied on all storage classes volume claims, adjust manually if necessary
DB2_4K_DEVICE_SUPPORT=ON # ON / OFF

DB2_ID=$((RANDOM % 9000000 + 1000000)) # Random 7 digit id suffix
export DB2_PAYLOAD_FILE="${SERVICE_INSTANCE_FILE_DIR}/db2oltp.json"
export DB2_INSTANCE_NAME="db2oltp-1${DB2_ID}"

export CPD_PROFILE_NAME="${CPD_USERNAME}-profile"

# --- Build the CPD service-instance payload (zen-data/v3/service_instances schema)

python3 - <<PYEOF
import json

payload = {
    "addon_type": "db2oltp",
    "display_name": "${DB2_INSTANCE_NAME}",
    "namespace": "${PROJECT_CPD_INST_OPERANDS}",
    "addon_version": "${DB2_Version}",
    "create_arguments": {
        "description": "",
        "metadata": {
            "labels": {
                "cpd_db2": "db2oltp",
                "db2u/cpdbr": "db2u",
                "icpdsupport/addOnId": "db2oltp",
                "icpdsupport/app": "${DB2_INSTANCE_NAME}",
                "icpdsupport/module": "db2u"
            },
            "annotations": {
                "openshift.io/required-scc": "restricted-v2"
            }
        },
        "parameters": {
            "account": {
                "imagePullSecrets": ["${IMAGE_PULL_SECRET}"],
                "securityConfig": {
                    "nonRootInstall": True,
                    "privilegedSysctlInit": False
                }
            },
            "addOns": {
                "graph": {"enabled": False},
                "opendataformats": {"workloadProfile": "default"},
                "qrep": {"enabled": False, "license": {}},
                "rest": {"enabled": True}
            },
            "advOpts": {
                "db2SecurityPlugin": "cloud_gss_plugin",
                "zenControlPlaneNamespace": "${PROJECT_CPD_INST_OPERANDS}"
            },
            "environment": {
                "authentication": {"ldap": {"enabled": False}},
                "databases": [
                    {
                        "name": "BLUDB",
                        "settings": {"dftPageSize": "16384"},
                        "storage": [
                            {
                                "name": "data",
                                "spec": {
                                    "accessModes": ["ReadWriteOnce"],
                                    "resources": {"requests": {"storage": "${DB2_STORAGE_CLAIM}Gi"}},
                                    "storageClassName": "${STG_CLASS_BLOCK}"
                                },
                                "type": "template"
                            },
                            {
                                "name": "activelogs",
                                "spec": {
                                    "accessModes": ["ReadWriteOnce"],
                                    "resources": {"requests": {"storage": "${DB2_STORAGE_CLAIM}Gi"}},
                                    "storageClassName": "${STG_CLASS_BLOCK}"
                                },
                                "type": "template"
                            },
                            {
                                "name": "tempts",
                                "spec": {
                                    "accessModes": ["ReadWriteOnce"],
                                    "resources": {"requests": {"storage": "${DB2_STORAGE_CLAIM}Gi"}},
                                    "storageClassName": "${STG_CLASS_FILE}"
                                },
                                "type": "template"
                            }
                        ]
                    }
                ],
                "dbType": "db2oltp",
                "instance": {
                    "dbmConfig": {
                        "SRVCON_PW_PLUGIN": "IBMIAMauthpwfile",
                        "group_plugin": "IBMIAMauthgroup",
                        "srvcon_auth": "GSS_SERVER_ENCRYPT",
                        "srvcon_gssplugin_list": "IBMIAMauth"
                    },
                    "password": {"value": "${DB2_PASSWORD}"},
                    "registry": {
                        "DB2_4K_DEVICE_SUPPORT": "${DB2_4K_DEVICE_SUPPORT}",
                        "DB2_FMP_RUN_AS_CONNECTED_USER": "NO",
                        "DB2AUTH": "OSAUTHDB,ALLOW_LOCAL_FALLBACK,PLUGIN_AUTO_RELOAD"
                    }
                },
                "partitionConfig": {"total": 1},
                "ssl": {
                    "allowSslOnly": False,
                    "certLabel": "CN=zen-ca-cert",
                    "secretName": "db2oltp-internal-tls"
                }
            },
            "license": {"accept": True},
            "nodes": 1,
            "podTemplate": {
                "db2u": {
                    "resource": {
                        "db2u": {
                            "limits": {
                                "cpu": "${DB2_CPU_LIMIT}",
                                "memory": "${DB2_MEMORY_LIMIT}"
                            }
                        }
                    }
                }
            },
            "storage": [
                {
                    "name": "meta",
                    "spec": {
                        "accessModes": ["ReadWriteMany"],
                        "resources": {"requests": {"storage": "${DB2_STORAGE_CLAIM}Gi"}},
                        "storageClassName": "${STG_CLASS_FILE}"
                    },
                    "type": "create"
                },
                {
                    "name": "backup",
                    "spec": {
                        "accessModes": ["ReadWriteMany"],
                        "resources": {"requests": {"storage": "${DB2_STORAGE_CLAIM}Gi"}},
                        "storageClassName": "${STG_CLASS_FILE}"
                    },
                    "type": "create"
                },
                {
                    "name": "archivelogs",
                    "spec": {
                        "accessModes": ["ReadWriteMany"],
                        "resources": {"requests": {"storage": "${DB2_STORAGE_CLAIM}Gi"}},
                        "storageClassName": "${STG_CLASS_FILE}"
                    },
                    "type": "create"
                }
            ],
            "version": "${DB2_Version}",
            "volumeSources": [
                {
                    "visibility": ["db2u"],
                    "volumeSource": {"secret": {"secretName": "zen-service-broker-secret"}}
                },
                {
                    "visibility": ["db2u"],
                    "volumeSource": {"configMap": {"name": "management-ingress-ibmcloud-cluster-info"}}
                }
            ]
        }
    }
}

with open("${DB2_PAYLOAD_FILE}", "w") as f:
    json.dump(payload, f, indent=2)
PYEOF

# --- Log into the cluster and create the resource.

eval "${OC_LOGIN}"
eval "${CPDM_OC_LOGIN}"

cpd-cli service-instance create \
    --profile=${CPD_PROFILE_NAME} \
    --from-source=${DB2_PAYLOAD_FILE} \
    --verbose

# --- Observe the progress in provisioning of Db2

echo "Waiting for ${DB2_INSTANCE_NAME} to reach Ready state..."
sleep 120
oc wait db2uinstance "${DB2_INSTANCE_NAME}" --for=jsonpath='{.status.state}'=Ready --timeout=30m || true

cpd-cli service-instance status "${DB2_INSTANCE_NAME}" --profile=${CPD_USERNAME} --service-type=db2oltp
