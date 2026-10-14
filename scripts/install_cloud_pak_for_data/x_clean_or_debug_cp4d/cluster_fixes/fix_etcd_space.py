#!/usr/bin/env python3
"""Detect and repair etcd members that are out of (or close to) their space quota.

Embedded etcds shipped by IBM operators (e.g. ibm-lh-*-milvus-etcd for watsonx
Orchestrate / watsonx.data Milvus) run without auto-defrag. Compaction frees
pages inside the bbolt file but only `defrag` gives them back, so the file grows
until it hits the 2 GiB default quota, etcd raises a NOSPACE alarm, writes fail
and clients crash with "mvcc: database space exceeded".

For every running pod in the namespace whose container image looks like etcd,
the script runs `etcdctl endpoint status` inside it and treats the member as
needing a fix when any of these hold:
  * a NOSPACE alarm is raised
  * the DB file is >= --size-ratio of the quota
  * the DB file holds >= --free-bytes of reclaimable space that is also more
    than half of the file
Fix: optional snapshot onto the member's PVC, compact to (revision -
--retain-revisions), defrag, then disarm NOSPACE only if the live data is
below --max-inuse-ratio of the quota (otherwise the quota itself is too small
and the script fails instead of masking it). Finally, controller-owned pods in
the namespace that crashed with "database space exceeded" are deleted so they
restart against the recovered etcd.

Only stdlib + the `oc` CLI are used, so the same file runs locally and inside
the in-cluster CronJob (openshift/cli image, which has python3 but no jq).
"""
import argparse
import json
import re
import subprocess
import sys
import time

CLIENT_ERROR = "database space exceeded"


def log(level, msg):
    print(f"[{level}] {msg}", flush=True)


def oc(*args, check=True):
    res = subprocess.run(["oc", *args], capture_output=True, text=True)
    if check and res.returncode != 0:
        raise RuntimeError(f"oc {' '.join(args[:6])}...: {res.stderr.strip()}")
    return res


def etcdctl(ns, pod, container, *args, check=True):
    return oc("-n", ns, "exec", pod, "-c", container, "--", "etcdctl", *args, check=check)


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def status(ns, pod, container):
    out = etcdctl(ns, pod, container, "endpoint", "status", "-w", "json").stdout
    st = json.loads(out)[0]["Status"]
    return {
        "revision": int(st["header"]["revision"]),
        "db": int(st["dbSize"]),
        "inuse": int(st.get("dbSizeInUse", st["dbSize"])),
        "nospace": any("NOSPACE" in e for e in st.get("errors") or []),
    }


def reachable(ns, pod, container):
    try:
        status(ns, pod, container)
        return True
    except (RuntimeError, ValueError, KeyError, IndexError):
        return False


def etcd_members(ns):
    """(pod, container, pvc_mount_path) for running pods with an etcd-like container."""
    pods = json.loads(oc("-n", ns, "get", "pods", "--field-selector=status.phase=Running", "-o", "json").stdout)["items"]
    for pod in pods:
        pvc_vols = {v["name"] for v in pod["spec"].get("volumes", []) if "persistentVolumeClaim" in v}
        for c in pod["spec"]["containers"]:
            image_name = c["image"].split("@")[0].rsplit("/", 1)[-1]
            if not re.search(r"etcd", image_name, re.I):
                continue
            mount = next((m["mountPath"] for m in c.get("volumeMounts", []) if m["name"] in pvc_vols), None)
            yield pod["metadata"]["name"], c["name"], mount


def snapshot(ns, pod, container, mount, db_bytes, preview):
    if not mount:
        raise RuntimeError("no PVC mount found for a snapshot; rerun with --no-snapshot to skip it")
    df = oc("-n", ns, "exec", pod, "-c", container, "--", "df", "-Pk", mount).stdout.splitlines()[-1].split()
    avail = int(df[3]) * 1024
    if avail < db_bytes * 1.2:
        raise RuntimeError(f"only {human(avail)} free on {mount} for a {human(db_bytes)} snapshot; rerun with --no-snapshot to skip it")
    path = f"{mount.rstrip('/')}/pre-defrag-{time.strftime('%Y%m%d-%H%M%S')}.db"
    if preview:
        log("PREVIEW", f"would snapshot to {pod}:{path}")
        return
    etcdctl(ns, pod, container, "snapshot", "save", path)
    log("OK", f"snapshot saved to {pod}:{path} (delete it once the fix is confirmed)")


def fix_member(ns, pod, container, mount, a):
    try:
        st = status(ns, pod, container)
    except (RuntimeError, ValueError, KeyError, IndexError) as e:
        log("SKIP", f"{ns}/{pod} [{container}]: etcdctl status failed ({str(e).splitlines()[0][:160]})")
        return 0

    free = st["db"] - st["inuse"]
    reasons = []
    if st["nospace"]:
        reasons.append("NOSPACE alarm")
    if st["db"] >= a.quota_bytes * a.size_ratio:
        reasons.append(f"DB at {st['db'] / a.quota_bytes:.0%} of quota")
    if free >= a.free_bytes and free > st["db"] / 2:
        reasons.append(f"{human(free)} reclaimable")
    summary = f"{ns}/{pod}: db={human(st['db'])} in-use={human(st['inuse'])} quota={human(a.quota_bytes)}"
    if not reasons:
        log("OK", f"{summary} - healthy")
        return 0
    log("FOUND", f"{summary} - {', '.join(reasons)}")

    if a.snapshot:
        snapshot(ns, pod, container, mount, st["db"], a.preview)

    target = st["revision"] - a.retain_revisions
    if a.preview:
        log("PREVIEW", f"would compact to revision {target}, defrag" + (", disarm NOSPACE" if st["nospace"] else ""))
        return 1

    if target > 0:
        res = etcdctl(ns, pod, container, "compact", str(target), check=False)
        if res.returncode == 0:
            log("OK", f"compacted to revision {target}")
        elif "compacted" in res.stderr:
            log("INFO", f"revision {target} already compacted")
        else:
            raise RuntimeError(f"compact failed: {res.stderr.strip()}")
    etcdctl(ns, pod, container, "defrag", f"--command-timeout={a.defrag_timeout}s")
    after = status(ns, pod, container)
    log("OK", f"defragmented: db {human(st['db'])} -> {human(after['db'])}")

    if after["nospace"]:
        if after["inuse"] >= a.quota_bytes * a.max_inuse_ratio:
            raise RuntimeError(
                f"live data is {human(after['inuse'])} (>= {a.max_inuse_ratio:.0%} of quota); "
                "NOSPACE alarm left raised - the etcd quota needs raising, defrag alone won't hold"
            )
        etcdctl(ns, pod, container, "alarm", "disarm")
        log("OK", "NOSPACE alarm disarmed")
    return 1


def restart_crashed_clients(ns, preview):
    pods = json.loads(oc("-n", ns, "get", "pods", "-o", "json").stdout)["items"]
    for pod in pods:
        name = pod["metadata"]["name"]
        for cs in pod.get("status", {}).get("containerStatuses", []):
            if cs.get("ready") or not cs.get("lastState", {}).get("terminated"):
                continue
            out = oc("-n", ns, "logs", name, "-c", cs["name"], "--previous", check=False).stdout
            if CLIENT_ERROR not in out:
                continue
            if not pod["metadata"].get("ownerReferences"):
                log("WARN", f"{ns}/{name} crashed on '{CLIENT_ERROR}' but has no controller; restart it manually")
            elif preview:
                log("PREVIEW", f"would delete {ns}/{name} (crashed on '{CLIENT_ERROR}')")
            else:
                oc("-n", ns, "delete", "pod", name, "--wait=false")
                log("OK", f"deleted {ns}/{name} (crashed on '{CLIENT_ERROR}')")
            break


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-n", "--namespace", action="append", required=True, help="namespace to scan (repeatable)")
    ap.add_argument("--preview", action="store_true", help="report only, change nothing")
    ap.add_argument("--no-snapshot", dest="snapshot", action="store_false", help="skip the pre-fix snapshot")
    ap.add_argument("--quota-bytes", type=int, default=2 * 1024**3, help="etcd quota-backend-bytes (default 2 GiB)")
    ap.add_argument("--size-ratio", type=float, default=0.8, help="treat DB >= this share of quota as a problem")
    ap.add_argument("--free-bytes", type=int, default=256 * 1024**2, help="treat this much reclaimable space as a problem")
    ap.add_argument("--max-inuse-ratio", type=float, default=0.7, help="only disarm NOSPACE below this share of quota")
    ap.add_argument("--retain-revisions", type=int, default=1000)
    ap.add_argument("--defrag-timeout", type=int, default=120, help="seconds")
    ap.add_argument("--list-members", action="store_true", help="print '<namespace> <pod>' per etcd pod and exit")
    a = ap.parse_args()

    if a.list_members:
        for ns in a.namespace:
            # Only members etcdctl can reach, so the CronJob's exec grant stays minimal.
            for pod in sorted({p for p, c, _ in etcd_members(ns) if reachable(ns, p, c)}):
                print(ns, pod)
        return 0

    found = failed = 0
    for ns in a.namespace:
        try:
            members = list(etcd_members(ns))
        except RuntimeError as e:
            log("ERROR", str(e))
            failed += 1
            continue
        if not members:
            log("INFO", f"{ns}: no etcd pods found")
        for pod, container, mount in members:
            try:
                found += fix_member(ns, pod, container, mount, a)
            except RuntimeError as e:
                log("ERROR", f"{ns}/{pod}: {e}")
                failed += 1
        try:
            restart_crashed_clients(ns, a.preview)
        except RuntimeError as e:
            log("ERROR", str(e))
            failed += 1
    if not found and not failed:
        log("OK", "no etcd space problems found")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
