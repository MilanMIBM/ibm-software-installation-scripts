"""CR object (dict) -> CRState: status, progress, message, versions, scale/shutdown fields.

First match wins per field: per-kind override -> CRD printer columns -> heuristics.
Status keys differ per kind (wkcStatus, dsStatus, controlPlaneStatus, zenStatus,
cpd-schedulingStatus, phase, state, ...), so the heuristics look for them by shape.
"""

from __future__ import annotations

import re

from .model import CRState, Phase, parse_ts

# 'Running' as a status *value* means healthy (OperandRequest phase, IBMLicensing); for ansible
# operators 'Running' is a *condition* ("Running reconciliation"), which is not read as a status.
COMPLETED = {"completed", "succeeded", "success", "successful", "ready", "available", "active",
             "installed", "deployed", "running", "healthy", "ok", "reconciled"}
IN_PROGRESS = {"inprogress", "in progress", "installing", "upgrading", "reconciling", "pending",
               "progressing", "creating", "updating", "scaling", "initializing", "deploying",
               "notready", "not ready"}
FAILED = {"failed", "failure", "error", "degraded", "crashloopbackoff"}
SHUTDOWN = {"shutdown", "shut down", "shuttingdown", "shutting down", "stopped", "paused", "disabled",
            "quiesced"}

DEFAULT_SCALE_FIELDS = ("scaleConfig", "autoScaleConfig", "replicas", "size")
_SCALE_KEY = re.compile(r"(^scale|replicas$|Replicas$)")

# Built-in per-kind overrides for known exceptions (user overrides win).
BUILTIN_OVERRIDES: dict[str, dict] = {
    "IBMLicensing": {"status": ".status.state"},        # ACTIVE when healthy (cluster-scoped 'instance')
    "CommonService": {"status": ".status.phase"},       # Succeeded
}


def get_path(obj, path: str):
    """Minimal JSONPath: '.status.dsStatus', '.status.versions.reconciled', '{.status.x}'."""
    if obj is None or not path:
        return None
    path = path.strip().strip("{}").lstrip("$")
    cur = obj
    for part in [p for p in path.split(".") if p]:
        m = re.fullmatch(r"([^\[]+)(?:\[(\d+)\])?", part)
        if not m:
            return None
        key, idx = m.group(1), m.group(2)
        if not isinstance(cur, dict) or key not in cur:
            return None
        cur = cur[key]
        if idx is not None:
            if not isinstance(cur, list) or int(idx) >= len(cur):
                return None
            cur = cur[int(idx)]
    return cur


def map_status(value) -> Phase:
    if value is None:
        return Phase.UNKNOWN
    v = str(value).strip().lower()
    if v in FAILED or v.startswith("fail"):
        return Phase.FAILED
    if v in SHUTDOWN or v.startswith("shut"):
        return Phase.SHUTDOWN
    if v in COMPLETED or v.startswith("complete"):
        return Phase.COMPLETED
    if v in IN_PROGRESS or "progress" in v or v.endswith("ing"):
        return Phase.IN_PROGRESS
    return Phase.UNKNOWN


def parse_progress(value) -> int | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return max(0, min(100, int(value)))
    m = re.search(r"(\d+(?:\.\d+)?)\s*%?", str(value))
    return max(0, min(100, int(float(m.group(1))))) if m else None


def _status_key_value(status: dict, kind: str):
    """The '<something>Status' string field, preferring '<kind>Status'."""
    want = kind.lower() + "status"
    cands = [(k, v) for k, v in status.items()
             if isinstance(v, str) and k.lower().endswith("status") and k.lower() != "status"]
    for k, v in cands:
        if k.lower() == want:
            return v
    for k, v in cands:
        if map_status(v) != Phase.UNKNOWN:
            return v
    return cands[0][1] if cands else None


def _printer_paths(columns: list[dict]) -> dict[str, str]:
    out = {}
    for col in columns or []:
        name = (col.get("name") or "").lower()
        path = col.get("jsonPath") or ""
        if not path.startswith(".status"):
            continue
        if name in ("status", "phase", "state") and "status" not in out:
            out["status"] = path
        elif name in ("progress", "percent", "percentage") and "progress" not in out:
            out["progress"] = path
        elif name in ("message", "progress message") and "message" not in out:
            out["message"] = path
        elif name in ("reconciled", "reconciled version", "version") and "version" not in out:
            out["version"] = path
    return out


def _reconciled_version(status: dict, path: str | None, obj: dict, kind: str) -> str | None:
    if path:
        v = get_path(obj, path)
        if isinstance(v, str) and v:
            return v
    versions = status.get("versions")
    if isinstance(versions, dict) and isinstance(versions.get("reconciled"), str):
        return versions["reconciled"]
    if isinstance(versions, list):  # DataStage: [{name: operator, ...}, {name: DataStage, version: 5.4.8}]
        named = [v for v in versions if isinstance(v, dict) and v.get("version")]
        for v in named:
            if str(v.get("name", "")).lower() == kind.lower():
                return str(v["version"])
        others = [v for v in named if str(v.get("name", "")).lower() != "operator"]
        if others:
            return str(others[0]["version"])
    for key in ("currentVersion", "reconciledVersion", "version"):
        if isinstance(status.get(key), str):
            return status[key]
    return None


def _ansible_conditions(st: CRState) -> None:
    """ansible-operator Running / Successful / Failure conditions -> reconcile flags."""
    conds = {c.get("type"): c for c in st.conditions if isinstance(c, dict)}
    run = conds.get("Running")
    if run is not None:
        st.reconciling = (run.get("status") == "True" and run.get("reason") == "Running")
        res = run.get("ansibleResult") or {}
        if isinstance(res, dict):
            st.last_reconcile_end = parse_ts(res.get("completion")) or st.last_reconcile_end
            try:
                if int(res.get("failures") or 0) > 0:
                    st.reconcile_failed = True
            except (TypeError, ValueError):
                pass
    fail = conds.get("Failure")
    if fail is not None and fail.get("status") == "True":
        st.reconcile_failed = True
        st.reconcile_failed_msg = fail.get("message") or st.reconcile_failed_msg
    if st.reconcile_failed and not st.reconcile_failed_msg:
        st.reconcile_failed_msg = "last reconcile reported failures"


def _scale_fields(spec: dict, fields: list[str] | None) -> dict[str, str]:
    out = {}
    if fields:
        for f in fields:
            key = f.split(".")[-1]
            v = get_path({"spec": spec}, f if f.startswith(".spec") else ".spec." + f)
            if v is not None:
                out[key] = str(v)
        return out
    for k, v in (spec or {}).items():
        scale_key = k in DEFAULT_SCALE_FIELDS or _SCALE_KEY.search(k)
        small = isinstance(v, (str, int, float, bool)) or (isinstance(v, (dict, list)) and len(str(v)) < 200)
        if scale_key and small:
            out[k] = str(v)
    return out


def normalize(obj: dict | None, kind: str, printer_columns: list[dict] | None = None,
              override: dict | None = None) -> CRState:
    if not obj:
        return CRState(exists=False, phase=Phase.NOT_CREATED)
    meta = obj.get("metadata") or {}
    status = obj.get("status") or {}
    spec = obj.get("spec") or {}
    ov = {**BUILTIN_OVERRIDES.get(kind, {}), **(override or {})}
    pc = _printer_paths(printer_columns or [])

    st = CRState(exists=True)
    st.uid = meta.get("uid")
    st.owner_uids = tuple(o.get("uid") for o in meta.get("ownerReferences") or [] if o.get("uid"))
    st.controller_uid = next((o.get("uid") for o in meta.get("ownerReferences") or [] if o.get("controller")), None)
    st.generation = meta.get("generation")
    st.created = parse_ts(meta.get("creationTimestamp"))
    st.conditions = [c for c in status.get("conditions") or [] if isinstance(c, dict)]
    hist = status.get("reconcileHistory")
    st.reconcile_history = [str(h) for h in hist] if isinstance(hist, list) else []

    # --- status
    raw = None
    for path in (ov.get("status"), pc.get("status")):
        if path:
            raw = get_path(obj, path)
            if raw is not None:
                break
    if raw is None:
        raw = _status_key_value(status, kind)
    if raw is None:
        raw = status.get("phase") or status.get("state")
    if raw is None and isinstance(status.get("status"), str):   # databandInstaller: status.status
        raw = status["status"]
    if raw is None and st.conditions:
        conds = {c.get("type"): c.get("status") for c in st.conditions}
        if conds.get("Failure") == "True" or conds.get("Failed") == "True":
            raw = "Failed"
        elif conds.get("Ready") == "True" or conds.get("Available") == "True":
            raw = "Completed"
        elif conds.get("Ready") == "False":
            raw = "InProgress"
    st.raw_status = str(raw) if raw is not None else None
    st.phase = map_status(raw)

    # --- progress / message
    prog = None
    for path in (ov.get("progress"), pc.get("progress"), ".status.progress", ".status.percent"):
        if path:
            prog = parse_progress(get_path(obj, path))
            if prog is not None:
                break
    st.progress = prog
    msg = None
    for path in (ov.get("message"), pc.get("message"), ".status.progressMessage", ".status.message",
                 ".status.statusMessage"):
        if path:
            v = get_path(obj, path)
            if isinstance(v, str) and v.strip():
                msg = v.strip()
                break
    if msg is None:
        dated = sorted(((parse_ts(c.get("lastTransitionTime")), c) for c in st.conditions
                        if c.get("message")), key=lambda t: (t[0] is not None, t[0]), reverse=True)
        if dated:
            msg = dated[0][1].get("message")
    st.message = msg
    if st.progress is None and st.phase == Phase.COMPLETED:
        st.progress = 100

    st.reconciled_version = _reconciled_version(status, ov.get("version") or pc.get("version"), obj, kind)

    # --- shutdown / scale
    sd = get_path(obj, ov["shutdown"]) if ov.get("shutdown") else spec.get("shutdown")
    st.shutdown = str(sd).strip().lower() in ("true", "1", "yes") if sd is not None else False
    if st.shutdown and st.phase != Phase.FAILED:
        st.phase = Phase.SHUTDOWN
    st.spec_scale = _scale_fields(spec, ov.get("scale_fields"))

    # --- timestamps / ansible flags
    times = [parse_ts(c.get("lastTransitionTime")) for c in st.conditions]
    times = [t for t in times if t]
    st.last_transition = max(times) if times else None
    _ansible_conditions(st)
    return st
