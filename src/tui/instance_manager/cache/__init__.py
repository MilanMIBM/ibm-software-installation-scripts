"""Discovery cache (cache plan §2): ${CONFIG_DIR}/instance_manager_cache/<api-host>--<namespace>/.

Two layers:
  sources  the slow raw inputs (add-on configmaps, zen extensions, trimmed CRDs, S4 create
           parameters per zen id, StorageClass kinds); the providers read through them
  models   derived FormModels, the catalog and an instance snapshot; only used to paint the
           TUI at once, re-derived from sources (CPU) or the cluster in the background
Validity is decided by a fingerprint probe (probe.py) and the cpd_vars summary (summary.py).
Secrets never reach the cache (redact.py).
"""

CACHE_SCHEMA = 1
CACHE_DIRNAME = "instance_manager_cache"
