"""Workload and pod health per CR: owner index Pod -> ReplicaSet -> Deployment -> CR (by uid).

Workloads whose owner chain doesn't reach a tracked CR can be attributed by a label
(cpd: icpdsupport/addOnId). The label -> CR map is learned from workloads that are
owned by a tracked CR and carry the same label, so no component table is needed.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from datetime import datetime, timedelta

from .model import PodIssue, WorkloadHealth, WorkloadInfo, now_utc, parse_ts

BAD_WAITING = {"CrashLoopBackOff", "Error", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError",
               "CreateContainerError", "InvalidImageName", "RunContainerError"}
OOM_WINDOW = timedelta(minutes=15)


def _owners(obj: dict) -> list[str]:
    return [o.get("uid") for o in (obj.get("metadata") or {}).get("ownerReferences") or [] if o.get("uid")]


def _uid(obj: dict) -> str | None:
    return (obj.get("metadata") or {}).get("uid")


def _name(obj: dict) -> str:
    return (obj.get("metadata") or {}).get("name", "?")


def _labels(obj: dict) -> dict:
    return (obj.get("metadata") or {}).get("labels") or {}


def _cond(obj: dict, ctype: str) -> dict | None:
    for c in (obj.get("status") or {}).get("conditions") or []:
        if c.get("type") == ctype:
            return c
    return None


class WorkloadIndex:
    """Built from raw lists; `resolve(owner uids)` walks up to the first tracked CR uid."""

    def __init__(self, *, deployments, statefulsets, replicasets, jobs, pods, hpas,
                 tracked_uids: set[str], parent_of_uid: dict[str, str] | None = None,
                 label_key: str | None = None):
        self.tracked = tracked_uids
        self.parent_of_uid = parent_of_uid or {}  # uid -> owner uid, for any known object
        self.label_key = label_key
        self.by_uid: dict[str, dict] = {}
        for coll in (deployments, statefulsets, replicasets, jobs):
            for o in coll:
                if _uid(o):
                    self.by_uid[_uid(o)] = o
        self.deployments, self.statefulsets, self.jobs = deployments, statefulsets, jobs
        self.pods, self.hpas = pods, hpas
        self._label_map: dict[str, str] = {}
        self._learn_labels()

    def _walk(self, uids: list[str], depth: int = 0) -> str | None:
        for u in uids:
            if u in self.tracked:
                return u
            if depth > 6:
                continue
            obj = self.by_uid.get(u)
            if obj is not None:
                hit = self._walk(_owners(obj), depth + 1)
                if hit:
                    return hit
            elif u in self.parent_of_uid:
                hit = self._walk([self.parent_of_uid[u]], depth + 1)
                if hit:
                    return hit
        return None

    def owner_cr(self, obj: dict) -> str | None:
        hit = self._walk(_owners(obj))
        if hit or not self.label_key:
            return hit
        lab = _labels(obj).get(self.label_key)
        return self._label_map.get(lab) if lab else None

    def _learn_labels(self) -> None:
        if not self.label_key:
            return
        votes: dict[str, Counter] = defaultdict(Counter)
        for o in list(self.deployments) + list(self.statefulsets):
            lab = _labels(o).get(self.label_key)
            if not lab:
                continue
            hit = self._walk(_owners(o))
            if hit:
                votes[lab][hit] += 1
        self._label_map = {lab: c.most_common(1)[0][0] for lab, c in votes.items()}

    # ------------------------------------------------------------------
    def _top_workload(self, pod: dict) -> str | None:
        """uid of the Deployment / StatefulSet a pod belongs to (through its ReplicaSet)."""
        for u in _owners(pod):
            obj = self.by_uid.get(u)
            if obj is None:
                continue
            ups = [x for x in _owners(obj) if x in self.by_uid]
            return ups[0] if ups else u
        return None

    def _unready_since(self) -> dict[str, datetime]:
        """workload uid -> earliest Ready=False transition among its pods."""
        out: dict[str, datetime] = {}
        for p in self.pods:
            ready = _cond(p, "Ready") or {}
            if ready.get("status") == "True" or (p.get("status") or {}).get("phase") == "Succeeded":
                continue
            w = self._top_workload(p)
            ts = parse_ts(ready.get("lastTransitionTime")) or parse_ts((p.get("status") or {}).get("startTime"))
            if w and ts and (w not in out or ts < out[w]):
                out[w] = ts
        return out

    def health(self) -> dict[str, WorkloadHealth]:
        out: dict[str, WorkloadHealth] = defaultdict(WorkloadHealth)
        now = now_utc()
        unready = self._unready_since()
        for d in self.deployments:
            cr = self.owner_cr(d)
            if not cr:
                continue
            spec, st = d.get("spec") or {}, d.get("status") or {}
            desired = int(spec.get("replicas", 1) or 0)
            avail = _cond(d, "Available") or {}
            out[cr].workloads.append(WorkloadInfo(
                "Deployment", _name(d), desired, int(st.get("readyReplicas") or 0),
                int(st.get("updatedReplicas") or 0) if desired else 0,
                unready.get(_uid(d)) or parse_ts(avail.get("lastTransitionTime"))))
        for s in self.statefulsets:
            cr = self.owner_cr(s)
            if not cr:
                continue
            spec, st = s.get("spec") or {}, s.get("status") or {}
            desired = int(spec.get("replicas", 1) or 0)
            out[cr].workloads.append(WorkloadInfo(
                "StatefulSet", _name(s), desired, int(st.get("readyReplicas") or 0),
                int(st.get("updatedReplicas") or st.get("currentReplicas") or 0) if desired else 0,
                unready.get(_uid(s))))
        # failed jobs: only the newest job per owner (CronJob history is noise)
        newest: dict[str, dict] = {}
        for j in self.jobs:
            key = (_owners(j) or [_uid(j)])[0]
            ts = parse_ts((j.get("metadata") or {}).get("creationTimestamp"))
            cur = newest.get(key)
            if cur is None or (ts and ts > parse_ts((cur.get("metadata") or {}).get("creationTimestamp"))):
                newest[key] = j
        for j in newest.values():
            failed = _cond(j, "Failed")
            if failed and failed.get("status") == "True":
                cr = self.owner_cr(j)
                if cr:
                    out[cr].failed_jobs.append(PodIssue(_name(j), failed.get("reason") or "Failed",
                                                        parse_ts(failed.get("lastTransitionTime"))))
        for p in self.pods:
            st = p.get("status") or {}
            phase = st.get("phase")
            if phase in ("Succeeded",) or (phase == "Failed" and st.get("reason") == "Evicted"):
                continue
            cr = self.owner_cr(p)
            if not cr:
                continue
            ready = _cond(p, "Ready") or {}
            since = parse_ts(ready.get("lastTransitionTime")) or parse_ts(st.get("startTime"))
            reason = None
            for cs in (st.get("initContainerStatuses") or []) + (st.get("containerStatuses") or []):
                waiting = (cs.get("state") or {}).get("waiting") or {}
                if waiting.get("reason") in BAD_WAITING:
                    reason = waiting["reason"]
                    break
                term = (cs.get("lastState") or {}).get("terminated") or {}
                fin = parse_ts(term.get("finishedAt"))
                if term.get("reason") == "OOMKilled" and fin and now - fin < OOM_WINDOW:
                    reason, since = "OOMKilled", fin
                    break
            if reason:
                out[cr].bad_pods.append(PodIssue(_name(p), reason, since))
                continue
            if phase == "Pending":
                sched = _cond(p, "PodScheduled") or {}
                if sched.get("status") == "False":
                    msg = (sched.get("message") or sched.get("reason") or "Pending").split(".")[0]
                    out[cr].pending_pods.append(PodIssue(_name(p), msg[:90],
                                                         parse_ts(sched.get("lastTransitionTime"))))
        for h in self.hpas:
            spec, st = h.get("spec") or {}, h.get("status") or {}
            ref = spec.get("scaleTargetRef") or {}
            target = next((o for o in list(self.deployments) + list(self.statefulsets)
                           if _name(o) == ref.get("name") and (o.get("kind") or ref.get("kind")) == ref.get("kind")), None)
            if target is None:
                continue
            cr = self.owner_cr(target)
            if cr and st.get("desiredReplicas") is not None and st.get("desiredReplicas") != st.get("currentReplicas"):
                out[cr].hpa_scaling.append(f"{_name(h)} {st.get('currentReplicas')}→{st.get('desiredReplicas')}")
        return dict(out)
