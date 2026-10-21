#!/usr/bin/env python3
"""Decide what to remove from a restore target cluster (used by
src/utilities/oadp_backup_restore_cp4d_utils/5_uninstall_from_target_cluster.sh).

Reads `oc get <resource> -A -o json` dumps from --dump-dir (one <resource>.json
per resource) and prints a plan, one tab-separated line per object:

    <action>\t<resource>\t<namespace>\t<name>\t<reason>

actions, in the order the shell script applies them:
    webhook    admission webhook configuration (removed first: a webhook whose
               service is gone blocks API calls)
    namespace  project, with everything in it
    olm        Subscription / ClusterServiceVersion / CatalogSource / OperatorGroup
               in a project that stays
    crd        CustomResourceDefinition (its custom resources are removed first)
    cluster    other cluster-scoped object
    note       kept, with the reason (shown to the user, nothing is done)

Scopes:
    restore  the restore: the instance projects, Velero leftovers (handled by
             the shell script), cluster-scoped objects Velero restored (labelled
             velero.io/restore-name), and ones that point into, bind or belong to
             the instance projects. What setup created stays.
    all      restore + everything created since the baseline (or the --since
             time): projects, operators, CRDs, RBAC, webhooks, ... Objects that
             existed before are kept, and so is anything that belongs to an
             operator that existed before (an upgrade of ODF after the cutoff
             creates new objects; they stay).

"Created since" is decided by --baseline (an inventory captured before the
scripts first changed the cluster: resource|namespace|name|uid lines; anything
not in it is new) or, without one, by --since (creationTimestamp >= that time).
"""
import argparse
import datetime as dt
import json
import os
import sys

RESOURCES = {
    "ns": "namespaces",
    "sub": "subscriptions.operators.coreos.com",
    "csv": "clusterserviceversions.operators.coreos.com",
    "cs": "catalogsources.operators.coreos.com",
    "og": "operatorgroups.operators.coreos.com",
    "crd": "customresourcedefinitions.apiextensions.k8s.io",
    "cr": "clusterroles.rbac.authorization.k8s.io",
    "crb": "clusterrolebindings.rbac.authorization.k8s.io",
    "mwh": "mutatingwebhookconfigurations.admissionregistration.k8s.io",
    "vwh": "validatingwebhookconfigurations.admissionregistration.k8s.io",
    "api": "apiservices.apiregistration.k8s.io",
    "pc": "priorityclasses.scheduling.k8s.io",
    "scc": "securitycontextconstraints.security.openshift.io",
    "sc": "storageclasses.storage.k8s.io",
    "cp": "consoleplugins.console.openshift.io",
}
PV = "persistentvolumes"
OLM_PKG_LABEL = "operators.coreos.com/"
VELERO_RESTORE_LABEL = "velero.io/restore-name"
# Objects an operator creates itself (not through OLM), recognised by a label
# prefix, and the projects that operator runs in.
OPERATOR_LABEL_PREFIXES = {
    "platform.opendatahub.io/": {"redhat-ods-operator", "opendatahub-operator-system"},
    "app.opendatahub.io/": {"redhat-ods-operator", "opendatahub-operator-system"},
}


def load(dump_dir, resource):
    path = os.path.join(dump_dir, resource + ".json")
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return []
    with open(path) as f:
        return json.load(f).get("items", [])


def md(o):
    return o.get("metadata", {})


def name(o):
    return md(o).get("name", "")


def ns_of(o):
    return md(o).get("namespace", "") or ""


def labels(o):
    return md(o).get("labels") or {}


def annotations(o):
    return md(o).get("annotations") or {}


def created(o):
    ts = md(o).get("creationTimestamp")
    if not ts:
        return 0.0
    return dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()


def cvo_managed(o):
    """Part of the OpenShift release payload (installed and owned by the CVO)."""
    return any(k.startswith("include.release.openshift.io/") for k in annotations(o))


class Plan:
    def __init__(self):
        self.lines = []
        self.seen = set()

    def add(self, action, resource, ns, nm, reason):
        key = (action, resource, ns, nm)
        if key in self.seen:
            return
        self.seen.add(key)
        self.lines.append((action, resource, ns, nm, reason))

    def note(self, resource, ns, nm, reason):
        self.add("note", resource, ns, nm, reason)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump-dir", required=True)
    ap.add_argument("--scope", choices=["restore", "all"], required=True)
    ap.add_argument("--instance-ns", default="", help="comma-separated instance projects")
    ap.add_argument("--keep-ns", default="", help="comma-separated projects never to remove")
    ap.add_argument("--baseline", help="inventory file: resource|namespace|name|uid lines")
    ap.add_argument("--since", type=float, help="epoch seconds; objects created at or after it are new")
    a = ap.parse_args()
    if a.scope == "all" and not a.baseline and a.since is None:
        ap.error("--scope all needs --baseline or --since")

    instance_ns = {n for n in a.instance_ns.split(",") if n}
    keep_ns = {n for n in a.keep_ns.split(",") if n}

    baseline = None
    if a.baseline:
        baseline = set()
        with open(a.baseline) as f:
            for line in f:
                parts = line.rstrip("\n").split("|")
                if len(parts) == 4:
                    baseline.add(tuple(parts))

    def is_new(resource, o):
        if a.scope != "all":
            return False
        if baseline is not None:
            return (resource, ns_of(o), name(o), md(o).get("uid", "")) not in baseline
        return created(o) >= a.since

    data = {k: load(a.dump_dir, r) for k, r in RESOURCES.items()}
    pvs = load(a.dump_dir, PV)
    plan = Plan()
    all_scope = a.scope == "all"

    # ---------------------------------------------------------------- projects
    new_sub_ns = {ns_of(s) for s in data["sub"] if is_new(RESOURCES["sub"], s)}
    ns_names = {name(n) for n in data["ns"]}
    ns_delete = set()
    for n in data["ns"]:
        nm = name(n)
        if nm in keep_ns:
            if nm in instance_ns:
                plan.note(RESOURCES["ns"], "", nm, "kept (--keep-namespace)")
            continue
        if nm in instance_ns:
            ns_delete.add(nm)
            plan.add("namespace", RESOURCES["ns"], "", nm, "instance project")
            continue
        if not all_scope or not is_new(RESOURCES["ns"], n):
            continue
        if nm in ("default", "openshift") or nm.startswith("kube-") or cvo_managed(n):
            continue
        if nm.startswith("openshift-") and nm not in new_sub_ns:
            plan.note(RESOURCES["ns"], "", nm, "new openshift-* project without an operator the scripts installed: kept")
            continue
        ns_delete.add(nm)
        plan.add("namespace", RESOURCES["ns"], "", nm, "created since the baseline")

    # ------------------------------------------------- operators in kept projects
    def kept_ns(nsname):
        return nsname not in ns_delete

    sub_delete = []
    if all_scope:
        for s in data["sub"]:
            if kept_ns(ns_of(s)) and ns_of(s) not in keep_ns and is_new(RESOURCES["sub"], s):
                sub_delete.append(s)
    sub_delete_keys = {(ns_of(s), name(s)) for s in sub_delete}
    kept_subs = [s for s in data["sub"] if kept_ns(ns_of(s)) and (ns_of(s), name(s)) not in sub_delete_keys]

    removed_pkgs = {(s.get("spec", {}).get("name", ""), ns_of(s)) for s in data["sub"]
                    if not kept_ns(ns_of(s)) or (ns_of(s), name(s)) in sub_delete_keys}
    kept_pkgs = {(s.get("spec", {}).get("name", ""), ns_of(s)) for s in kept_subs}

    def sub_csvs(s):
        st = s.get("status", {})
        return {c for c in (st.get("installedCSV"), st.get("currentCSV")) if c}

    claimed_by_kept = {(ns_of(s), c) for s in kept_subs for c in sub_csvs(s)}
    claimed_by_removed = {(ns_of(s), c) for s in sub_delete for c in sub_csvs(s)}

    def copied(csv):
        return "olm.copiedFrom" in labels(csv) or csv.get("status", {}).get("reason") == "Copied"

    removed_csvs = {(ns_of(c), name(c)) for c in data["csv"] if not copied(c) and not kept_ns(ns_of(c))}
    csv_delete = []
    if all_scope:
        for c in data["csv"]:
            key = (ns_of(c), name(c))
            if copied(c) or not kept_ns(ns_of(c)) or ns_of(c) in keep_ns or key in claimed_by_kept:
                continue
            pkg_labels = [k[len(OLM_PKG_LABEL):].rpartition(".") for k in labels(c) if k.startswith(OLM_PKG_LABEL)]
            if any((p, n) in kept_pkgs for p, _, n in pkg_labels):
                continue
            if key in claimed_by_removed or is_new(RESOURCES["csv"], c):
                csv_delete.append(c)
                removed_csvs.add(key)

    def owner_removed(o):
        """True: belongs to an operator being removed. False: to one that stays.
        None: no OLM ownership labels."""
        found = False
        for k in labels(o):
            if k.startswith(OLM_PKG_LABEL):
                pkg, _, nsname = k[len(OLM_PKG_LABEL):].rpartition(".")
                found = True
                if nsname in ns_delete or (pkg, nsname) in removed_pkgs:
                    return True
        lb = labels(o)
        if "olm.owner.namespace" in lb:
            found = True
            if lb["olm.owner.namespace"] in ns_delete or (lb["olm.owner.namespace"], lb.get("olm.owner", "")) in removed_csvs:
                return True
        elif "olm.owner" in lb:
            # Owner CSV without its namespace: look it up by name.
            found = True
            if lb["olm.owner"] in {c for _, c in removed_csvs} and lb["olm.owner"] not in kept_csv_names:
                return True
        for prefix, op_nss in OPERATOR_LABEL_PREFIXES.items():
            if any(k.startswith(prefix) for k in lb):
                present = op_nss & ns_names
                if present:
                    found = True
                    if present <= ns_delete:
                        return True
        return False if found else None

    kept_csv_names = {name(c) for c in data["csv"] if not copied(c) and (ns_of(c), name(c)) not in removed_csvs}

    for s in sub_delete:
        plan.add("olm", RESOURCES["sub"], ns_of(s), name(s), "operator subscription created since the baseline")
    for c in csv_delete:
        plan.add("olm", RESOURCES["csv"], ns_of(c), name(c), "operator installed since the baseline")
    if all_scope:
        used_sources = {(s.get("spec", {}).get("sourceNamespace", ""), s.get("spec", {}).get("source", "")) for s in kept_subs}
        for cs in data["cs"]:
            if not kept_ns(ns_of(cs)) or ns_of(cs) in keep_ns or not is_new(RESOURCES["cs"], cs):
                continue
            if (ns_of(cs), name(cs)) in used_sources:
                plan.note(RESOURCES["cs"], ns_of(cs), name(cs), "new catalog source, but an operator that stays uses it: kept")
                continue
            plan.add("olm", RESOURCES["cs"], ns_of(cs), name(cs), "catalog source created since the baseline")
        csv_delete_keys = {(ns_of(c), name(c)) for c in csv_delete}
        for og in data["og"]:
            nsname = ns_of(og)
            if not kept_ns(nsname) or nsname in keep_ns or not is_new(RESOURCES["og"], og):
                continue
            others = [c for c in data["csv"] if ns_of(c) == nsname and not copied(c) and (nsname, name(c)) not in csv_delete_keys]
            if others or any(ns_of(s) == nsname for s in kept_subs):
                plan.note(RESOURCES["og"], nsname, name(og), "new operator group, but operators that stay use it: kept")
                continue
            plan.add("olm", RESOURCES["og"], nsname, name(og), "operator group created since the baseline")

    # ----------------------------------------------------- cluster-scoped objects
    def svc_namespaces(kind, o):
        if kind in ("mwh", "vwh"):
            return {((w.get("clientConfig") or {}).get("service") or {}).get("namespace") for w in o.get("webhooks") or []} - {None}
        if kind == "api":
            svc = (o.get("spec") or {}).get("service") or {}
            return {svc["namespace"]} if svc.get("namespace") else set()
        return set()

    def sa_subjects_only_in(o, nss):
        subj = o.get("subjects") or []
        return bool(subj) and all(x.get("kind") == "ServiceAccount" and x.get("namespace") in nss for x in subj)

    pv_classes = {}
    for pv in pvs:
        sc = (pv.get("spec") or {}).get("storageClassName")
        claim_ns = ((pv.get("spec") or {}).get("claimRef") or {}).get("namespace")
        if sc and claim_ns not in ns_delete:
            pv_classes[sc] = pv_classes.get(sc, 0) + 1
        if claim_ns in ns_delete and (pv.get("spec") or {}).get("persistentVolumeReclaimPolicy") == "Retain":
            plan.note(PV, "", name(pv), f"volume of a removed project ({claim_ns}) with reclaim policy Retain: stays until you delete it")

    for kind in ("mwh", "vwh", "api", "cr", "crb", "crd", "pc", "scc", "sc", "cp"):
        res = RESOURCES[kind]
        action = {"mwh": "webhook", "vwh": "webhook", "crd": "crd"}.get(kind, "cluster")
        for o in data[kind]:
            nm = name(o)
            if cvo_managed(o) or nm.startswith("system:") or md(o).get("ownerReferences"):
                continue
            owner = owner_removed(o)
            svc_ns = svc_namespaces(kind, o)

            # --- the restore (both scopes) ---
            if VELERO_RESTORE_LABEL in labels(o):
                plan.add(action, res, "", nm, "created by the restore (" + labels(o)[VELERO_RESTORE_LABEL] + ")")
                continue
            if kind != "crd":
                if svc_ns & instance_ns:
                    plan.add(action, res, "", nm, "points at a service in the instance projects")
                    continue
                if kind == "crb" and sa_subjects_only_in(o, instance_ns):
                    plan.add(action, res, "", nm, "binds only service accounts of the instance projects")
                    continue
                if labels(o).get("olm.owner.namespace") in instance_ns:
                    plan.add(action, res, "", nm, "belongs to an operator in the instance projects")
                    continue
            if not all_scope:
                continue

            # --- everything else the scripts changed ---
            if owner is True:
                plan.add(action, res, "", nm, "belongs to an operator that is removed")
                continue
            if svc_ns and svc_ns <= ns_delete:
                plan.add(action, res, "", nm, "points at a service in a removed project")
                continue
            if svc_ns:
                # Serves a project that stays: removing it would break that project.
                continue
            if kind == "crb" and sa_subjects_only_in(o, ns_delete):
                plan.add(action, res, "", nm, "binds only service accounts of removed projects")
                continue
            if owner is False or not is_new(res, o):
                continue
            if nm.startswith(("openshift-", "openshift:")):
                plan.note(res, "", nm, "new, but named like an OpenShift object and not owned by a removed operator: kept")
                continue
            if kind == "api" and not svc_ns:
                continue
            if kind == "crd":
                group = (o.get("spec") or {}).get("group", "")
                if group.endswith(("openshift.io", "k8s.io")):
                    plan.note(res, "", nm, "new OpenShift/Kubernetes API group, not owned by a removed operator: kept")
                    continue
            if kind == "sc" and pv_classes.get(nm):
                plan.note(res, "", nm, f"new storage class still used by {pv_classes[nm]} volume(s) outside the removed projects: kept")
                continue
            plan.add(action, res, "", nm, "created since the baseline")

    order = {"webhook": 0, "namespace": 1, "olm": 2, "crd": 3, "cluster": 4, "note": 5}
    olm_order = {RESOURCES["sub"]: 0, RESOURCES["csv"]: 1, RESOURCES["cs"]: 2, RESOURCES["og"]: 3}
    plan.lines.sort(key=lambda l: (order[l[0]], olm_order.get(l[1], 9), l[1], l[2], l[3]))
    out = sys.stdout
    for line in plan.lines:
        out.write("\t".join(line) + "\n")


def pull_secret_revert(baseline_file, current_file, out_file):
    """Put the global pull secret's registry entries back to the baseline:
    entries added since are removed, changed ones get their old value back.
    Prints one line per change; writes the result only when something changed."""
    with open(baseline_file) as f:
        base = json.load(f).get("auths", {})
    with open(current_file) as f:
        cur_doc = json.load(f)
    cur = cur_doc.get("auths", {})
    new = {}
    changes = []
    for reg, val in cur.items():
        if reg not in base:
            changes.append(f"remove {reg} (added since the baseline)")
        elif base[reg] != val:
            new[reg] = base[reg]
            changes.append(f"restore {reg} (changed since the baseline)")
        else:
            new[reg] = val
    for reg, val in base.items():
        if reg not in cur:
            new[reg] = val
            changes.append(f"restore {reg} (removed since the baseline)")
    if changes:
        cur_doc["auths"] = new
        with open(out_file, "w") as f:
            json.dump(cur_doc, f)
        os.chmod(out_file, 0o600)
    for c in changes:
        print(c)


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "pull-secret":
        pull_secret_revert(*sys.argv[2:])
    else:
        main()
