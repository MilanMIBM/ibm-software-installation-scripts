"""cr_dashboard - live, read-only terminal dashboard of Kubernetes custom resources.

Shows each CR's state as a glowing dot (healthy / in progress / scaling / stuck /
failing / inactive), how CRs wait on and own each other, % progress and the step
the operator is on. CRD-agnostic core; the `cpd` profile targets an IBM Software
Hub / Cloud Pak for Data instance. Nothing is written to the cluster or to disk.

Run: PYTHONPATH=src python -m tui.cr_dashboard {cpd|cr} ...  (see --help)
"""

__version__ = "0.1.0"
