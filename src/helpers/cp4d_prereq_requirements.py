"""Decide which cluster prerequisites CPD_COMPONENTS needs.

Usage: python3 cp4d_prereq_requirements.py <gpu|rhoai|mcg|knative> [install-options-file]

Rules follow IBM Software Hub 5.4 "Installing prerequisite software", "Installing
operators for services that require GPUs", "Installing Red Hat OpenShift AI",
"Installing and setting up Multicloud Object Gateway" and "Installing Red Hat
OpenShift Serverless Knative Eventing". A service's options are read from the
install-options file the component install passes as --param-file; a service
with no options there is judged on IBM's documented defaults.

Prints one "[needed]" / "[not needed]" line per component in CPD_COMPONENTS that
the prerequisite applies to, and exits 2 if the options file cannot be read.
Where the docs leave a case open, the verdict leans to "needed": an unneeded
operator only costs cluster resources, a missing one breaks the service install.
"""

import os
import sys

PREREQS = ("gpu", "rhoai", "mcg", "knative")

# Always need the GPU operators and Red Hat OpenShift AI. watsonx_ai_ifm serves
# the Inference foundation models and the rest of the wca_z family runs models
# too; IBM's tables do not list them, so they are kept here to fail safe.
# watsonx_data_premium_dependencies installs watsonx_ai and watsonx_ai_ifm.
ALWAYS_GPU_RHOAI = {
    "watsonx_ai", "watsonx_ai_ifm", "watsonx_data_premium_dependencies",
    "wca", "wca_ansible", "wca_z_agentic", "wca_z_understand",
}


def load_options(path):
    # The file is one YAML document per service, each under non_olm (or
    # override_components_meta / custom_spec); merge the per-service blocks.
    opts = {}
    if not path:
        return opts
    import yaml
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if not isinstance(doc, dict):
                continue
            for section in ("non_olm", "override_components_meta", "custom_spec"):
                for svc, cfg in (doc.get(section) or {}).items():
                    if isinstance(cfg, dict):
                        opts.setdefault(svc, {}).update(cfg)
    return opts


def text(v):
    return str(v).strip().lower()


def on(v):
    return text(v) in ("true", "yes", "1")


def enrichments_on(node, under=False):
    # IBM documents no exact key for Speech enrichments, so match any key
    # containing "enrich" that is switched on.
    if isinstance(node, dict):
        return any(enrichments_on(v, under or "enrich" in str(k).lower()) for k, v in node.items())
    if isinstance(node, list):
        return under and bool(node)
    return under and on(node)


def assess(c, opts):
    """Return {prereq: (needed, reason)} for the prerequisites component c relates to."""

    def block(*names):
        for n in names:
            if n in opts:
                return opts[n]
        return {}

    def get(cfg, key, default):
        v = cfg.get(key)
        return default if v is None else v

    def gpu_rhoai(needed, reason):
        return {"gpu": (needed, reason), "rhoai": (needed, reason)}

    if c in ALWAYS_GPU_RHOAI:
        return gpu_rhoai(True, "always required")

    if c in ("ikc_premium", "ikc_standard"):
        key = "ikcPremium" if c == "ikc_premium" else "ikcStandard"
        m = text(get(block(key), "enableModelsOn", "cpu"))
        return gpu_rhoai(m == "gpu", f"{key}.enableModelsOn={m} (needed only for gpu)")

    if c == "wml":
        return {"gpu": (False, "needed only for GPU models, which no install option shows - force it if you use them")}

    if c == "ws_runtimes":
        kinds = get(block("wsRuntimes"), "kinds", []) or []
        gpu = [k for k in (kinds if isinstance(kinds, list) else [kinds]) if "gpu" in text(k)]
        return {"gpu": (bool(gpu), f"GPU runtimes in wsRuntimes.kinds: {', '.join(gpu) or 'none'}")}

    if c == "watsonx_data":
        return {"gpu": (False, "needed only for GPU Milvus indexes, which no install option shows - force it if you use them")}

    if c == "watson_discovery":
        return {"mcg": (True, "always required")}

    if c == "watson_speech":
        e = enrichments_on(block("watsonSpeech"))
        return {"mcg": (True, "always required"),
                **gpu_rhoai(e, f"enrichments {'on' if e else 'off'} (needed only for enrichments)")}

    if c == "watson_assistant":
        t = text(get(block("watsonAssistant"), "watsonxAiType", "none"))
        return {"mcg": (True, "always required"), "knative": (True, "always required"),
                **gpu_rhoai(t == "embedded", f"watsonAssistant.watsonxAiType={t} (needed only for embedded/GPU features)")}

    if c == "watsonx_bi_assistant":
        ifm = on(get(block("watsonxBiAssistant"), "installIFM", True))
        return gpu_rhoai(ifm, f"watsonxBiAssistant.installIFM={str(ifm).lower()} (chart default true)")

    if c == "watsonx_data_premium":
        # The chart reads components (default standard) and ignores the
        # documented "component" key; the operator runs models only for premium.
        comps = get(block("watsonxDataPremium"), "components", ["standard"])
        comps = [text(x) for x in (comps if isinstance(comps, list) else [comps])]
        return gpu_rhoai("premium" in comps,
                         f"watsonxDataPremium.components={','.join(comps)} (needed only for premium)")

    if c == "watsonx_dataintegration":
        u = on(get(block("watsonxDataintegration", "watsonx_dataintegration"),
                   "enableUnstructuredDataIntegration", True))
        return gpu_rhoai(u, f"enableUnstructuredDataIntegration={str(u).lower()} (IBM default true)")

    if c == "watsonx_dataintelligence":
        cfg = block("watsonxDataintelligence")
        m = text(get(cfg, "enableModelsOn", "cpu"))
        u = on(get(cfg, "enableUnstructuredDataIntegration", False))
        return gpu_rhoai(m == "gpu" or u,
                         f"watsonxDataintelligence.enableModelsOn={m}, enableUnstructuredDataIntegration={str(u).lower()}")

    if c == "watsonx_orchestrate":
        cfg = block("watsonxOrchestrate")
        mode = text(get(cfg, "installMode", "agentic"))
        ifm = on(get(get(cfg, "watsonxAI", {}) or {}, "watsonxaiifm", False))
        return {"mcg": (True, "always required"),
                "knative": (mode == "agentic_assistant", f"watsonxOrchestrate.installMode={mode} (needed only for agentic_assistant)"),
                **gpu_rhoai(ifm, f"watsonxOrchestrate.watsonxAI.watsonxaiifm={str(ifm).lower()} (needed only for local models)")}

    return {}


def main():
    if len(sys.argv) not in (2, 3) or sys.argv[1] not in PREREQS:
        print(f"usage: {sys.argv[0]} <{'|'.join(PREREQS)}> [install-options-file]", file=sys.stderr)
        return 2
    prereq = sys.argv[1]
    path = sys.argv[2] if len(sys.argv) == 3 else ""
    try:
        opts = load_options(path)
    except ImportError:
        print("PyYAML is not available to python3", file=sys.stderr)
        return 2
    except Exception as e:  # OSError or yaml.YAMLError
        print(f"cannot read {path}: {e}", file=sys.stderr)
        return 2

    components = [c.strip() for c in os.environ.get("CPD_COMPONENTS", "").split(",") if c.strip()]
    for c in components:
        verdict = assess(c, opts).get(prereq)
        if verdict is not None:
            print(f"[{'needed' if verdict[0] else 'not needed'}] {c}: {verdict[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
