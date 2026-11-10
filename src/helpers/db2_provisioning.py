"""Build new Db2 instances; storage inputs are positive integer GiB quantities."""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

VOLUMES = ("data", "activelogs", "tempts", "meta", "backup", "archivelogs")


def configuration(env):
    profile = env.get("DB2_PROFILE", "general")
    if profile not in {"general", "cognos"}:
        raise ValueError("DB2_PROFILE must be general or cognos")
    name = env.get("DB2_INSTANCE_NAME", "")
    if name and not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", name):
        raise ValueError("DB2_INSTANCE_NAME must be a Kubernetes DNS label")
    sizes = {}
    for name in VOLUMES:
        value = env.get(f"DB2_{name.upper()}_STORAGE_GI", env.get("DB2_STORAGE_CLAIM", "30"))
        if not re.fullmatch(r"[1-9][0-9]*", value):
            raise ValueError(f"DB2_{name.upper()}_STORAGE_GI must be a positive integer in GiB")
        sizes[name] = value + "Gi"
    return sizes, "32768" if profile == "cognos" else "16384"


def build_payload(env):
    sizes, page_size = configuration(env)
    payload = {
        "addon_type": "db2oltp",
        "display_name": env["DB2_INSTANCE_NAME"],
        "namespace": env["PROJECT_CPD_INST_OPERANDS"],
        "addon_version": env["DB2_Version"],
        "create_arguments": {
            "description": "",
            "metadata": {
                "labels": {
                    "cpd_db2": "db2oltp",
                    "db2u/cpdbr": "db2u",
                    "icpdsupport/addOnId": "db2oltp",
                    "icpdsupport/app": env["DB2_INSTANCE_NAME"],
                    "icpdsupport/module": "db2u"
                },
                "annotations": {
                    "openshift.io/required-scc": "restricted-v2"
                }
            },
            "parameters": {
                "account": {
                    "imagePullSecrets": [env["IMAGE_PULL_SECRET"]],
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
                    "zenControlPlaneNamespace": env["PROJECT_CPD_INST_OPERANDS"]
                },
                "environment": {
                    "authentication": {"ldap": {"enabled": False}},
                    "databases": [
                        {
                            "name": "BLUDB",
                            "settings": {"dftPageSize": page_size},
                            "storage": [
                                {
                                    "name": "data",
                                    "spec": {
                                        "accessModes": ["ReadWriteOnce"],
                                        "resources": {"requests": {"storage": sizes["data"]}},
                                        "storageClassName": env["STG_CLASS_BLOCK"]
                                    },
                                    "type": "template"
                                },
                                {
                                    "name": "activelogs",
                                    "spec": {
                                        "accessModes": ["ReadWriteOnce"],
                                        "resources": {"requests": {"storage": sizes["activelogs"]}},
                                        "storageClassName": env["STG_CLASS_BLOCK"]
                                    },
                                    "type": "template"
                                },
                                {
                                    "name": "tempts",
                                    "spec": {
                                        "accessModes": ["ReadWriteOnce"],
                                        "resources": {"requests": {"storage": sizes["tempts"]}},
                                        "storageClassName": env["STG_CLASS_FILE"]
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
                        "password": {"value": env["DB2_PASSWORD"]},
                        "registry": {
                            "DB2_4K_DEVICE_SUPPORT": env["DB2_4K_DEVICE_SUPPORT"],
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
                                    "cpu": env["DB2_CPU_LIMIT"],
                                    "memory": env["DB2_MEMORY_LIMIT"]
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
                            "resources": {"requests": {"storage": sizes["meta"]}},
                            "storageClassName": env["STG_CLASS_FILE"]
                        },
                        "type": "create"
                    },
                    {
                        "name": "backup",
                        "spec": {
                            "accessModes": ["ReadWriteMany"],
                            "resources": {"requests": {"storage": sizes["backup"]}},
                            "storageClassName": env["STG_CLASS_FILE"]
                        },
                        "type": "create"
                    },
                    {
                        "name": "archivelogs",
                        "spec": {
                            "accessModes": ["ReadWriteMany"],
                            "resources": {"requests": {"storage": sizes["archivelogs"]}},
                            "storageClassName": env["STG_CLASS_FILE"]
                        },
                        "type": "create"
                    }
                ],
                "version": env["DB2_Version"],
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

    if env.get("DB2_PROFILE") == "cognos":
        payload["create_arguments"]["parameters"]["environment"]["databases"][0]["settings"]["codeset"] = "UTF-8"
        payload["create_arguments"]["parameters"]["environment"]["instance"]["registry"]["DB2_INLIST_TO_NLJN"] = "YES"
    return payload


def write_payload(path, payload):
    # Exclusive creation prevents overwriting a previous instance's credentials or following symlinks.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(payload, stream, indent=2)


def cli_for(profile):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from tui.instance_manager.providers.cpd.cpdcli import CpdCli
    return CpdCli(profile)


def ensure_new(cli, name):
    if any(r.get("display_name") == name and r.get("service_type") == "db2oltp" for r in cli.list_instances()):
        raise ValueError("Db2 display name already exists")


def wait_ready(cli, name, namespace, timeout=1800):
    """Resolve the CR through its platform ID; display names are not Kubernetes names."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        records = [r for r in cli.list_instances() if r.get("display_name") == name and r.get("service_type") == "db2oltp"]
        if len(records) > 1:
            raise ValueError("Ambiguous Db2 display name")
        if records:
            record = records[0]
            if record.get("provision_status") in {"FAILED", "PROVISION_FAILED"}:
                raise ValueError("Db2 provisioning failed")
            zid = str(record["id"])
            result = subprocess.run(["oc", "get", "db2uinstances", "-n", namespace, "-o", "json"],
                                    capture_output=True, text=True, timeout=60, check=False)
            if result.returncode:
                raise RuntimeError("Cannot read Db2 custom resources")
            matches = []
            for obj in json.loads(result.stdout)["items"]:
                meta = obj.get("metadata", {})
                links = [meta.get("labels", {}).get("icpdsupport/serviceInstanceId"),
                         obj.get("spec", {}).get("zenServiceInstanceId"),
                         obj.get("status", {}).get("instance_id")]
                links.extend(template.get("labels", {}).get("icpdsupport/serviceInstanceId")
                             for template in obj.get("spec", {}).get("podTemplate", {}).values()
                             if isinstance(template, dict))
                if zid in {str(v) for v in links if v is not None}:
                    matches.append(obj)
            if len(matches) > 1:
                raise ValueError("Ambiguous Db2 custom resource")
            if matches:
                state = matches[0].get("status", {}).get("state")
                if state in {"Failed", "FAILED", "Error"}:
                    raise ValueError("Db2 custom resource failed")
                if state == "Ready" and record.get("provision_status") == "PROVISIONED":
                    print("Db2 custom resource is Ready and platform instance is PROVISIONED")
                    return
        time.sleep(10)
    raise ValueError("Db2 readiness timed out; inspect the instance before retrying")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check-name")
    parser.add_argument("--wait")
    parser.add_argument("--submit", type=Path)
    parser.add_argument("--profile")
    parser.add_argument("--namespace")
    args = parser.parse_args()
    try:
        configuration(os.environ)
        if args.check_name or args.wait or args.submit:
            if not args.profile:
                parser.error("--profile is required for CLI operations")
            cli = cli_for(args.profile)
            if args.check_name:
                ensure_new(cli, args.check_name)
            elif args.wait:
                if not args.namespace:
                    parser.error("--namespace is required for --wait")
                wait_ready(cli, args.wait, args.namespace)
            else:
                cli.run("service-instance", "create", f"--from-source={args.submit.resolve()}", timeout=600)
        elif not args.validate:
            if not args.output:
                parser.error("--output is required unless --validate is used")
            write_payload(args.output, build_payload(os.environ))
    except Exception:  # noqa: BLE001 - CLI responses can contain database credentials
        parser.exit(1, "Db2 operation failed; check inputs, profile and instance state before retrying. Existing payloads are never overwritten.\n")


if __name__ == "__main__":
    main()
