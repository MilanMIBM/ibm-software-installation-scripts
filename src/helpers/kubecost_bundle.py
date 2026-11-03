#!/usr/bin/env python3
"""Kubecost operator bundle (registry+v1) -> plain manifests, for installing the
operator from mirrored images without OLM or a catalog.

Used by src/utilities/kubecost_utils/install_kubecost_operator.sh; the
bundle's manifests/ come from mirror_images/mirror_kubecost_images.sh
(configs/kubecost_config/mirror/<version>/bundle/manifests/).

  render  --bundle DIR --namespace NS --image-map MAP.json [--pull-secret NAME]
          -> JSON v1 List: CRDs, the bundle's other manifests, ServiceAccounts,
             Role/RoleBinding (permissions), ClusterRole/ClusterRoleBinding
             (clusterPermissions) and the Deployment(s), images replaced per
             MAP ({source ref: destination ref}); WATCH_NAMESPACE is the
             install namespace (OLM's OwnNamespace mode)
  example --bundle DIR -> the CSV's first alm-example (a Kubecost CR) as JSON
  csv     --bundle DIR -> {"name", "version"}
"""

import argparse
import copy
import glob
import json
import os
import sys

import yaml

MANAGED = "kubecost-images-install"


def load_bundle(path):
    docs = []
    for f in sorted(glob.glob(os.path.join(path, "*.y*ml"))):
        with open(f, encoding="utf-8") as fh:
            docs.extend(d for d in yaml.safe_load_all(fh) if d)
    csv = next((d for d in docs if d.get("kind") == "ClusterServiceVersion"), None)
    if csv is None:
        sys.exit(f"[ERROR] No ClusterServiceVersion in {path}")
    return csv, [d for d in docs if d is not csv]


def labels(csv):
    return {"app.kubernetes.io/managed-by": MANAGED, "kubecost-install/csv": csv["metadata"]["name"]}


def with_labels(obj, extra):
    obj = copy.deepcopy(obj)
    obj.setdefault("metadata", {}).setdefault("labels", {}).update(extra)
    return obj


def render(csv, others, ns, image_map, pull_secret):
    lab = labels(csv)
    spec = csv["spec"]["install"]["spec"]
    out = []
    for d in others:
        d = with_labels(d, lab)
        if d.get("kind") not in ("CustomResourceDefinition", "ClusterRole", "ClusterRoleBinding"):
            d["metadata"]["namespace"] = ns
        out.append(d)

    sas = {p["serviceAccountName"] for p in spec.get("permissions", []) + spec.get("clusterPermissions", [])}
    sas |= {d["spec"]["template"]["spec"].get("serviceAccountName", "default") for d in spec["deployments"]}
    for sa in sorted(sas - {"default"}):
        obj = {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": sa, "namespace": ns, "labels": lab}}
        if pull_secret:
            obj["imagePullSecrets"] = [{"name": pull_secret}]
        out.append(obj)

    for i, p in enumerate(spec.get("permissions", [])):
        name = f"{p['serviceAccountName']}-{i}" if i else p["serviceAccountName"]
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role",
                    "metadata": {"name": name, "namespace": ns, "labels": lab}, "rules": p["rules"]})
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding",
                    "metadata": {"name": name, "namespace": ns, "labels": lab},
                    "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": name},
                    "subjects": [{"kind": "ServiceAccount", "name": p["serviceAccountName"], "namespace": ns}]})
    for i, p in enumerate(spec.get("clusterPermissions", [])):
        # Cluster-scoped: the namespace in the name keeps installs apart.
        name = f"{p['serviceAccountName']}-{ns}" + (f"-{i}" if i else "")
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole",
                    "metadata": {"name": name, "labels": lab}, "rules": p["rules"]})
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding",
                    "metadata": {"name": name, "labels": lab},
                    "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": name},
                    "subjects": [{"kind": "ServiceAccount", "name": p["serviceAccountName"], "namespace": ns}]})

    missing = set()
    for d in spec["deployments"]:
        ds = copy.deepcopy(d["spec"])
        pod = ds["template"]
        pod.setdefault("metadata", {}).setdefault("annotations", {})["olm.targetNamespaces"] = ns
        pod["metadata"].setdefault("labels", {}).update(lab)
        pspec = pod["spec"]
        for c in pspec.get("containers", []) + pspec.get("initContainers", []):
            if c["image"] in image_map:
                c["image"] = image_map[c["image"]]
            else:
                missing.add(c["image"])
            for e in c.get("env", []) or []:
                ref = (e.get("valueFrom") or {}).get("fieldRef", {}).get("fieldPath", "")
                if "olm.targetNamespaces" in ref:
                    e.pop("valueFrom")
                    e["value"] = ns
        if pull_secret:
            pspec["imagePullSecrets"] = [{"name": pull_secret}]
        out.append({"apiVersion": "apps/v1", "kind": "Deployment",
                    "metadata": {"name": d["name"], "namespace": ns,
                                 "labels": {**(d.get("label") or {}), **lab}},
                    "spec": ds})
    if missing:
        sys.exit(f"[ERROR] No mirrored image for: {', '.join(sorted(missing))}")
    return {"apiVersion": "v1", "kind": "List", "items": out}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("command", choices=("render", "example", "csv"))
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--namespace")
    ap.add_argument("--image-map")
    ap.add_argument("--pull-secret", default="")
    a = ap.parse_args()
    csv, others = load_bundle(a.bundle)
    if a.command == "csv":
        json.dump({"name": csv["metadata"]["name"], "version": csv["spec"].get("version", "")}, sys.stdout)
    elif a.command == "example":
        examples = json.loads(csv["metadata"].get("annotations", {}).get("alm-examples", "[]"))
        json.dump(next((e for e in examples if e.get("kind") == "Kubecost"), {}), sys.stdout)
    else:
        if not (a.namespace and a.image_map):
            ap.error("render needs --namespace and --image-map")
        with open(a.image_map, encoding="utf-8") as fh:
            image_map = json.load(fh)
        json.dump(render(csv, others, a.namespace, image_map, a.pull_secret), sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
