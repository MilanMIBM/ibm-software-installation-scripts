"""WP-B: vars generation for the Confluent operator install mode (contract §5.2, §7.1, §7.3).

Lean: the generators run in throwaway sandbox repos (tests/mcm_harness.py), never against configs/.
The scripts-mode baselines come from `git show 0efad5f:<path>`.
"""

from __future__ import annotations

import difflib
import json
import os
import re
import subprocess
import sys
import textwrap
from pathlib import Path

import jinja2
import pytest

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO))

from mcm_harness import make_sandbox

BASE_REF = "0efad5f"
GEN = "scripts/install_confluent_platform/0_confluent_prepare_template_config.sh"
FLINK_GEN = "scripts/install_confluent_platform/install_confluent_platform_flink_addon/0_flink_prepare_template_config.sh"
J2 = "src/helpers/config_file_jinja2_templates/confluent_variable_template.sh.j2"
VARS = "configs/confluent_platform_config/confluent_vars.sh"
CLUSTER_ID = "AbCdEfGhIjKlMnOpQrStUv"
EXTRAS = ["pyproject.toml", "src/helpers/version_catalog.json", "src/helpers/config_file_jinja2_templates", GEN, FLINK_GEN]

SNIPPET = textwrap.dedent("""\
    # ---- Deploy mode ---------------------------------------------------------------
    # scripts  = the repo renders and applies raw manifests (StatefulSet broker, Deployments, ...).
    # operator = Confluent for Kubernetes (CFK) and cp-fko, installed through OLM, run the platform.
    # Unset or any other value means operator; a scripts-mode install in the namespace then stops every script.
    export CONFLUENT_DEPLOY_MODE="{mode}"
""")
OP_BEGIN = "# >>> confluent operator (managed by 0_confluent_prepare_template_config.sh) >>>"
OP_END = "# <<< confluent operator (managed by 0_confluent_prepare_template_config.sh) <<<"
EXPORT = re.compile(r'^export ([A-Z0-9_]+)="(.*)"$')


def git_show(path):
    return subprocess.run(["git", "show", f"{BASE_REF}:{path}"], cwd=REPO, capture_output=True, text=True, check=True).stdout


def sandbox(base=False):
    sb = make_sandbox(extra=EXTRAS)
    os.symlink(REPO / ".venv", sb.repo / ".venv")
    if base:
        for rel in (GEN, FLINK_GEN):
            (sb.repo / rel).write_text(git_show(rel))
    return sb


def run(sb, script, *args):
    result = sb.run_script(script, args=list(args), env={"ENV_SETUP_QUIET": "1"})
    return result


def vars_text(sb):
    return (sb.repo / VARS).read_text()


def exports(text):
    """[(name, value)] of every export line, in order."""
    return [m.groups() for m in map(EXPORT.match, text.splitlines()) if m]


def section(text, start, end=None):
    """Lines from the first line containing <start> up to the line containing <end> (or the end)."""
    lines = text.splitlines()
    i = next(n for n, line in enumerate(lines) if start in line)
    j = next((n for n, line in enumerate(lines[i + 1:], i + 1) if end and end in line), len(lines) - 1)
    return "\n".join(lines[i:j + 1])


def normalise(text, sb):
    text = text.replace(str(sb.root), "<ROOT>")
    text = re.sub(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", "<TS>", text)
    return re.sub(r"\[TIMER\] .* completed in .*", "[TIMER] <N>", text)


@pytest.fixture
def sb():
    with sandbox() as box:
        yield box


# ---------------------------------------------------------------------------------------------
# 0_confluent_prepare_template_config.sh
# ---------------------------------------------------------------------------------------------
def test_new_file_defaults_to_operator_with_settings_block_and_plain(sb):
    result = run(sb, GEN, "--size", "small", "--cluster-id", CLUSTER_ID)
    assert result.returncode == 0, result.stdout + result.stderr
    text = vars_text(sb)
    values = dict(exports(text))
    assert SNIPPET.format(mode="operator") in text
    assert '[INFO] CONFLUENT_DEPLOY_MODE="operator" written to confluent_vars.sh.' in result.stdout
    # operator settings section (§2.2) and the managed block (§2.3, small preset)
    assert "# Confluent operator mode - added by 0_confluent_prepare_template_config.sh on" in text
    assert values["CONFLUENT_OPERATOR_CHANNEL"] == "3.4"
    assert values["CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL"] == "Manual"
    assert values["CONFLUENT_OPERATOR_INIT_IMAGE"] == "${CONFLUENT_REGISTRY}/confluent-init-container:3.4.0"
    assert "CONFLUENT_OPERATOR_ENABLE_CMF_DAY2_OPS" not in values
    block = section(text, OP_BEGIN, OP_END)
    assert 'export CONFLUENT_KRAFT_REPLICAS="3"' in block and 'export CONFLUENT_C3_STORAGE_SIZE="10Gi"' in block
    assert text.index("# <<< confluent sizing") < text.index(OP_BEGIN)
    # plan O9: PLAIN forced, SCRAM dropped (impl plain)
    assert values["CONFLUENT_SASL_MECHANISM"] == "PLAIN"
    assert values["CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS"] == "PLAIN"
    assert values["CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS"] == "PLAIN"
    assert "[INFO] CONFLUENT_SASL_MECHANISM: SCRAM-SHA-512 -> PLAIN (operator mode, plan O9)" in result.stdout
    assert "No CONFLUENT_LICENSE_KEY - Confluent Platform runs on the 30-day trial license." in result.stderr
    assert subprocess.run(["zsh", "-n", str(sb.repo / VARS)], check=False).returncode == 0

    # Re-run: idempotent apart from the timestamps; flags rewrite their line; kraft flags win.
    again = run(sb, GEN, "--size", "medium", "--approval", "automatic", "--sasl-impl", "scram",
                "--kraft-replicas", "5", "--kraft-storage", "30Gi")
    assert again.returncode == 0, again.stdout + again.stderr
    text2 = vars_text(sb)
    values2 = dict(exports(text2))
    assert text2.count(OP_BEGIN) == 1 and text2.count("export CONFLUENT_DEPLOY_MODE=") == 1
    assert text2.count("export CONFLUENT_OPERATOR_SOURCE=") == 1
    assert values2["CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL"] == "Automatic"
    assert values2["CONFLUENT_OPERATOR_SASL_IMPL"] == "scram"
    assert (values2["CONFLUENT_KRAFT_REPLICAS"], values2["CONFLUENT_KRAFT_STORAGE_SIZE"]) == ("5", "30Gi")
    assert values2["CONFLUENT_KSQLDB_STORAGE_SIZE"] == "20Gi"  # medium preset
    assert "outside Confluent Support" in again.stderr


def test_switch_is_refused_then_allowed_and_back(sb):
    assert run(sb, GEN, "--size", "small", "--cluster-id", CLUSTER_ID, "--deploy-mode", "scripts").returncode == 0
    before = vars_text(sb)
    refused = run(sb, GEN, "--deploy-mode", "operator")
    assert refused.returncode == 1
    assert "is in scripts mode; switching to operator needs --switch-deploy-mode (a fresh install, plan O19)" in refused.stderr
    assert vars_text(sb) == before

    switched = run(sb, GEN, "--deploy-mode", "operator", "--switch-deploy-mode")
    assert switched.returncode == 0, switched.stdout + switched.stderr
    text = vars_text(sb)
    assert 'export CONFLUENT_DEPLOY_MODE="operator"' in text and text.count("export CONFLUENT_DEPLOY_MODE=") == 1
    assert "x.8_confluent_wipe_scripts_mode.sh" in switched.stdout
    assert OP_BEGIN in text

    back = run(sb, GEN, "--deploy-mode", "scripts", "--switch-deploy-mode")
    assert back.returncode == 0, back.stdout + back.stderr
    text = vars_text(sb)
    assert 'export CONFLUENT_DEPLOY_MODE="scripts"' in text
    assert OP_BEGIN not in text and "Removed the operator managed block" in back.stdout
    assert "export CONFLUENT_OPERATOR_SOURCE=" in text  # the settings section stays (harmless)


def test_legacy_file_without_toggle_warns_and_writes_no_mode(sb):
    assert run(sb, GEN, "--size", "small", "--cluster-id", CLUSTER_ID, "--deploy-mode", "scripts").returncode == 0
    path = sb.repo / VARS
    path.write_text(path.read_text().replace(SNIPPET.format(mode="scripts"), ""))
    result = run(sb, GEN, "--size", "small")
    assert result.returncode == 0, result.stdout + result.stderr
    assert ("has no CONFLUENT_DEPLOY_MODE - the scripts treat it as operator mode. Run with --deploy-mode scripts "
            "to keep a scripts-mode install, or --deploy-mode operator.") in result.stderr
    text = path.read_text()
    assert "CONFLUENT_DEPLOY_MODE" not in text and OP_BEGIN not in text
    assert 'export CONFLUENT_SASL_MECHANISM="SCRAM-SHA-512"' in text  # no operator forcing


def test_scripts_mode_delta_is_exactly_the_snippet():
    """§7.3 gen_platform_fresh + Flink helm: base vs new differ only by the snippet and one INFO line."""
    with sandbox(base=True) as base, sandbox() as new:
        b = run(base, GEN, "--size", "small", "--cluster-id", CLUSTER_ID)
        n = run(new, GEN, "--size", "small", "--cluster-id", CLUSTER_ID, "--deploy-mode", "scripts")
        assert b.returncode == n.returncode == 0, n.stdout + n.stderr
        b_out, n_out = normalise(b.stdout, base).splitlines(), normalise(n.stdout, new).splitlines()
        added = [line[2:] for line in difflib.ndiff(b_out, n_out) if line.startswith("+ ")]
        removed = [line for line in difflib.ndiff(b_out, n_out) if line.startswith("- ")]
        assert added == ['[INFO] CONFLUENT_DEPLOY_MODE="scripts" written to confluent_vars.sh.'] and not removed
        assert normalise(b.stderr, base) == normalise(n.stderr, new)
        b_file, n_file = normalise(vars_text(base), base), normalise(vars_text(new), new)
        assert n_file.replace("\n" + SNIPPET.format(mode="scripts"), "", 1) == b_file
        assert n_file.index("export CONFLUENT_BROKER_JMX_PORT=") < n_file.index("# ---- Deploy mode") < n_file.index("# >>> confluent sizing")

        # Flink add-on in scripts mode (helm): byte-identical
        b = run(base, FLINK_GEN, "--size", "small")
        n = run(new, FLINK_GEN, "--size", "small")
        assert b.returncode == n.returncode == 0, n.stdout + n.stderr
        assert normalise(b.stdout, base) == normalise(n.stdout, new)
        assert normalise(b.stderr, base) == normalise(n.stderr, new)
        n_file = normalise(vars_text(new), new)
        assert n_file.replace("\n" + SNIPPET.format(mode="scripts"), "", 1) == normalise(vars_text(base), base)
        assert "FLINK_OLM_" not in n_file


@pytest.mark.parametrize("line", ["export CONFLUENT_DEPLOY_MODE=scripts", "export CONFLUENT_DEPLOY_MODE='scripts'"])
def test_existing_scripts_file_is_byte_identical_and_hand_quoting_is_read(line):
    """§7.3 gen_platform_write / Flink: an existing scripts-mode file; a hand-edited (unquoted or single-quoted)
    mode line still reads as scripts, so no operator setting, PLAIN forcing or cp-fko block appears."""
    with sandbox(base=True) as base, sandbox() as new:
        assert run(base, GEN, "--size", "small", "--cluster-id", CLUSTER_ID).returncode == 0
        start = vars_text(base) + "\n" + line + "\n"  # the same starting file in both trees
        for box in (base, new):
            path = box.repo / VARS
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(start)
            path.chmod(0o600)
        for script in (GEN, FLINK_GEN):
            b, n = run(base, script, "--size", "small"), run(new, script, "--size", "small")
            assert b.returncode == n.returncode == 0, n.stdout + n.stderr
            assert normalise(n.stdout, new) == normalise(b.stdout, base)
            assert normalise(n.stderr, new) == normalise(b.stderr, base)
            assert normalise(vars_text(new), new) == normalise(vars_text(base), base)
        assert "CONFLUENT_OPERATOR_SOURCE" not in vars_text(new) and "FLINK_OLM_" not in vars_text(new)
        assert oct((new.repo / VARS).stat().st_mode & 0o777) == "0o600"


def test_rewrites_keep_the_file_mode(sb):
    assert run(sb, GEN, "--size", "small", "--cluster-id", CLUSTER_ID).returncode == 0
    path = sb.repo / VARS
    path.chmod(0o600)
    result = run(sb, GEN, "--size", "small", "--approval", "Automatic")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "[INFO] CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL: Manual -> Automatic" in result.stdout
    assert oct(path.stat().st_mode & 0o777) == "0o600"


def test_flink_olm_append_and_cmf_25_pin(sb):
    assert run(sb, GEN, "--size", "small", "--cluster-id", CLUSTER_ID).returncode == 0  # operator
    result = run(sb, FLINK_GEN, "--size", "small")
    assert result.returncode == 0, result.stdout + result.stderr
    text = vars_text(sb)
    values = dict(exports(text))
    assert values["FLINK_CMF_CHART_VERSION"] == "2.5.0"
    assert values["FLINK_SQL_IMAGE"] == "confluentinc/cp-flink-sql:1.19-cmf2.5-cp1"
    assert (values["FLINK_OLM_CHANNEL"], values["FLINK_OLM_STARTING_CSV"]) == ("stable-v1.16", "cp-fko.v1.16.1-cp1")
    assert values["FLINK_CFK_NAMESPACE"] == "${PROJECT_CONFLUENT_FLINK}"
    assert "FLINK_OPERATOR_SOURCE" not in values  # follows the platform mode
    assert "# Confluent Flink operator mode - added by" in text
    assert subprocess.run(["zsh", "-n", str(sb.repo / VARS)], check=False).returncode == 0

    again = run(sb, FLINK_GEN, "--size", "small", "--operator-source", "existing")
    assert again.returncode == 0, again.stdout + again.stderr
    text = vars_text(sb)
    assert text.count("export FLINK_OLM_PACKAGE=") == 1
    assert dict(exports(text))["FLINK_OPERATOR_SOURCE"] == "existing"


def test_flink_existing_cmf_24_warns(sb):
    assert run(sb, GEN, "--size", "small", "--cluster-id", CLUSTER_ID, "--deploy-mode", "scripts").returncode == 0
    assert run(sb, FLINK_GEN, "--size", "small").returncode == 0  # helm: CMF 2.4.x pinned
    result = run(sb, FLINK_GEN, "--size", "small", "--operator-source", "olm")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "CMF 2.4.x pairs with cp-fko stable-v1.15" in result.stderr
    values = dict(exports(vars_text(sb)))
    assert values["FLINK_OPERATOR_SOURCE"] == "olm"
    assert values["FLINK_OLM_CHANNEL"] == "stable-v1.15"


# ---------------------------------------------------------------------------------------------
# confluent_variable_template.sh.j2
# ---------------------------------------------------------------------------------------------
def j2_context():
    ctx = json.loads((REPO / "tests/fixtures/confluent_j2_context.json").read_text())
    ctx.pop("_comment", None)
    return ctx


def render(text, ctx):
    return jinja2.Environment(keep_trailing_newline=True).from_string(text).render(**ctx)


def operator_context(size="small"):
    from src.helpers import confluent_id_options_templates as o

    rest = {r["key"]: r["value"] for r in o.default_confluent_operator}
    selects = {k: options[0] for k, options in o.confluent_operator_select_keys.items()}
    merged = {**selects, **rest}
    return {
        **j2_context(),
        "confluent_deploy_mode": "operator",
        "confluent_operator": {k: merged[k] for k in o.confluent_operator_var_order},
        "confluent_operator_sizing": dict(o.confluent_operator_size_presets[size]),
        "flink_operator_source": "olm",
        "flink_operator_olm": {r["key"]: r["value"] for r in o.default_flink_operator_olm},
    }


def test_j2_scripts_render_is_baseline_plus_snippet():
    ctx = j2_context()
    base = render(git_show(J2), ctx)
    new = render((REPO / J2).read_text(), {**ctx, "confluent_deploy_mode": "scripts", "flink_operator_source": "helm"})
    anchor = "# Topology from https://github.com/confluentinc/cp-all-in-one (KRaft variant).\n"
    assert new == base.replace(anchor, anchor + SNIPPET.format(mode="scripts"), 1)


def test_j2_operator_render_has_the_blocks_and_parity_with_0_(sb):
    text = render((REPO / J2).read_text(), operator_context())
    assert 'export CONFLUENT_DEPLOY_MODE="operator"' in text
    assert text.index("# <<< confluent sizing") < text.index(OP_BEGIN) < text.index(OP_END) < text.index("# >>> confluent flink")
    assert 'export FLINK_OLM_CHANNEL="stable-v1.16"' in text
    script = sb.repo / "rendered.sh"
    script.write_text(text)
    assert subprocess.run(["zsh", "-n", str(script)], check=False).returncode == 0

    # 0_ writes the same operator names and values, in the same order
    assert run(sb, GEN, "--size", "small", "--cluster-id", CLUSTER_ID).returncode == 0
    written = vars_text(sb)
    gen_settings = exports(section(written, "# Confluent operator mode - added by", "# >>> confluent sizing"))
    j2_settings = exports(section(text, "# Confluent operator mode", OP_BEGIN))
    assert gen_settings and gen_settings == j2_settings
    assert exports(section(written, OP_BEGIN, OP_END)) == exports(section(text, OP_BEGIN, OP_END))


# ---------------------------------------------------------------------------------------------
# confluent_id_options_templates.py and the notebook
# ---------------------------------------------------------------------------------------------
def test_options_module_imports():
    from src.helpers import confluent_id_options_templates as o
    from src.helpers import confluent_operator_config as c

    assert o.default_confluent_deploy_mode == "operator" and o.confluent_deploy_mode_options == ["operator", "scripts"]
    assert {r["deploy_mode_id"] for r in o.confluent_deploy_mode_records} == {"operator", "scripts"}
    assert o.confluent_operator_size_presets is c.KRAFT_PRESETS
    assert o.flink_operator_source_options[0] == "follow" and o.flink_cmf_resource_mode_options[0] == "follow"
    keys = [r["key"] for r in o.default_confluent_operator]
    assert set(keys) | set(o.confluent_operator_select_keys) == set(o.confluent_operator_var_order)
    assert not set(keys) & set(o.confluent_operator_select_keys)
    assert set(o.confluent_operator_var_order) <= c.ALLOWED_VARS
    assert o.operator_mode_overrides == {"CONFLUENT_SASL_MECHANISM": "PLAIN"}
    assert o.flink_operator_mode_overrides["FLINK_CMF_CHART_VERSION"] == "2.5.0"
    assert o.without_scram("PLAIN,SCRAM-SHA-512") == "PLAIN" and o.without_scram("SCRAM-SHA-256") == "PLAIN"


NOTEBOOK_DRIVER = textwrap.dedent("""\
    import json, sys
    sys.path.insert(0, ".")
    import importlib.util
    spec = importlib.util.spec_from_file_location("nb", "confluent_platform_vars_generation.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    class W:
        def __init__(self, value):
            self.value = value
    import marimo as mo
    # {"dropdown": v} = a real one-option dropdown (layout cells call .style on it)
    defs = {k: (mo.ui.dropdown(options=[v["dropdown"]], value=v["dropdown"]) if isinstance(v, dict) else W(v))
            for k, v in json.loads(sys.argv[1]).items()}
    outputs, values = module.app.run(defs=defs)
    warn = values.get("security_warnings")
    print("RESULT=" + json.dumps({"rendered": values["rendered_variables_file_confluent"],
                                  "warnings": str(getattr(warn, "text", "")) if warn is not None else ""}))
""")


@pytest.mark.parametrize("mode", ["operator", "scripts"])
def test_notebook_renders_the_mode(mode):
    with make_sandbox(extra=["confluent_platform_vars_generation.py", "src/helpers/config_file_jinja2_templates",
                             "src/helpers/sortable-kv-dependencies", "src/helpers/version_catalog.json",
                             "pyproject.toml"]) as box:
        (box.repo / "nb_driver.py").write_text(NOTEBOOK_DRIVER)
        widgets = {"run_button": True, "save_to_config_dir_button": False, "cluster_url_input": "https://api.x.example.com:6443"}
        if mode == "scripts":
            widgets["deploy_mode_select"] = {"dropdown": "scripts"}
        done = subprocess.run([sys.executable, "nb_driver.py", json.dumps(widgets)], cwd=box.repo, env=box.env(),
                              capture_output=True, text=True, timeout=240, check=False)
        assert done.returncode == 0, done.stdout[-3000:] + done.stderr[-3000:]
        result = json.loads(next(line for line in done.stdout.splitlines() if line.startswith("RESULT="))[7:])
        text = result["rendered"]
        assert f'export CONFLUENT_DEPLOY_MODE="{mode}"' in text
        if mode == "operator":
            assert OP_BEGIN in text and 'export CONFLUENT_KRAFT_REPLICAS="3"' in text
            assert 'export CONFLUENT_SASL_MECHANISM="PLAIN"' in text
            assert 'export CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS="PLAIN"' in text
            assert 'export FLINK_CMF_CHART_VERSION="2.5.0"' in text and 'export FLINK_OLM_CHANNEL="stable-v1.16"' in text
            assert "export FLINK_OPERATOR_SOURCE" not in text
            assert "drops SCRAM from the listener lists" in result["warnings"]
        else:
            assert OP_BEGIN not in text and "FLINK_OLM_" not in text
            assert 'export CONFLUENT_SASL_MECHANISM="SCRAM-SHA-512"' in text
        script = box.repo / "rendered.sh"
        script.write_text(text)
        assert subprocess.run(["zsh", "-n", str(script)], check=False).returncode == 0

