# ibm-software-installation-scripts

Scripts and config generators for installing **IBM Software Hub / Cloud Pak for Data (and various components)** into a Redhat OpenShift cluster, plus scripts for **Confluent Platform** (with an optional Flink add-on).

The Cloud Pak for Data workflow has two stages:

1. **Generating a config** - running marimo notebooks to fill in cluster URL, credentials, entitlement key, storage classes and the components you want. Thereby creating configs used in the installation `cpd_vars.sh` and `install-options.yml` into the subfolder `./configs/cp4d_config/`.
2. **Running the install** - either the full chained script, or the numbered step scripts one at a time. Every script sources the variables from the configs in `./configs/` automatically.

---

## Repository overview

| Path | What's in it |
| --- | --- |
| `*_vars_generation*.py` | Marimo notebooks - the config generators. Branches may include unique streamlined variants with presets for specific installation options. |
| `configs/` | Your generated configs live here (gitignored), one subfolder per product (`cp4d_config/`, `confluent_platform_config/`, …). Every `.sh` directly inside a subfolder is sourced by the install scripts. `openshift_config/` holds the credential files written by the user/service ID utilities. |
| `scripts/install_cloud_pak_for_data/` | The numbered install steps (0 → 5), service instance provisioning (`4.5_service_instance_setups/`), plus cleanup/debug scripts under `x_clean_or_debug_cp4d/` |
| `scripts/install_confluent_platform/` | Confluent Platform install steps, utility scripts, and the Flink add-on (`install_confluent_platform_flink_addon/`, has its own README) |
| `scripts/*.sh` | Shared script plumbing: `source_env_setup.sh` (config loading), `0.0_make_executable.sh`, and `operator_install_helpers.sh` (idempotency checks so OLM operator installs are safe to re-run) |
| `src/helpers/` | Jinja2 templates and marimo widgets backing the notebooks, plus Python/zsh helpers: IBM Cloud IAM auth, watsonx.data database registration, IBM License Service, IBM Cloud Secrets Manager, the Software Hub internal vault, and the Software Hub → `cpd-cli` release resolver |
| `src/cr_yaml_examples/` | Jinja2 custom resource templates rendered by `src/utilities/cpd-cli_utils/create_cr_instance.sh` |
| `src/utilities/` | Extras: `cpd-cli` maintenance (upgrade, OLM image, workspace cleanup, premium features, CR create/delete), IBM Cloud Secrets Manager config storage, OpenShift pull secret/access group/htpasswd/service ID helpers, Software Hub checks and API key vault storage |
| `env_bootstrap.sh` | Sourced by every script to find the repo root and load `configs/` (via `scripts/source_env_setup.sh`) |
| `s_env.sh` | `source s_env.sh` in your shell to load the configs and log in to the cluster with `oc` |
| `service_instances/` | Output folder for payloads written by the `4.5_service_instance_setups/` provisioning scripts (gitignored) |
| `cpd-cli-workspace/` | Health check results and logs that `cpd-cli` writes when run from the repo root (gitignored) |

---

## Prerequisites

- OpenShift cluster + `oc` and `cpd-cli` (installers for both under [scripts/install_cloud_pak_for_data/0_initial_setup/](scripts/install_cloud_pak_for_data/0_initial_setup/), macOS only)
- `zsh` - the scripts are zsh scripts; run them directly (`./script.sh`), not with `sh script.sh`
- `podman` (macOS: scripts start the podman machine automatically when needed)
- Python 3.14+ and [uv](https://docs.astral.sh/uv/)
- An IBM entitlement key - *[You can get one here if you have entitlements or IBM Software Access Catalog](https://myibm.ibm.com/products-services/containerlibrary)*

```bash
uv sync          # or: uv add -r requirements.txt
```

---

## 1. Generate your config

Run the config generator notebook:

```bash
marimo run softwarehub_cp4d_vars_generation.py
```

Use `marimo edit softwarehub_cp4d_vars_generation.py` instead if you want to change the notebook itself rather than just fill in the configuration.

In the browser UI:

1. Fill in cluster URL, OCP username/password or token, entitlement key, storage classes, project names.
2. Select the components to install.
3. Review the rendered `cpd_vars.sh` and `install-options.yml` in the editors at the bottom - you can edit them in place.
4. Click **Save directly to ./configs/cp4d_config/**.

That writes:

- `configs/cp4d_config/cpd_vars.sh` - all the `export`s the install scripts rely on
- `configs/cp4d_config/install-options.yml` - component list and install options for `cpd-cli`

The two **Save your … file** buttons next to it download the files to your browser's download folder instead, if you want a copy elsewhere.

> Anything you drop into a `configs/` subfolder (e.g. `configs/cp4d_config/`) as a `.sh` file gets sourced, so you can split extra variables into their own files.

---

## 2. Run the install

### Everything at once

```bash
./scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh
```

This chains the steps below in order, timing each one and stopping on the first failure. The `DO_*` toggles at the top of the script let you skip stages you've already completed.

### Step by step

Run these in order - each one is standalone and loads the config itself:

```bash
# 0. One-time workstation + cluster setup
./scripts/install_cloud_pak_for_data/0_initial_setup/0.1_install_oc-MAC-ONLY.sh
./scripts/install_cloud_pak_for_data/0_initial_setup/0.2_install_cpd_cli-MAC-ONLY.sh

# 1. Cert manager + global pull secret
./scripts/install_cloud_pak_for_data/1_global_pull_secret_and_certmanager/1.0_set_up_openshift_certmanager.sh
./scripts/install_cloud_pak_for_data/1_global_pull_secret_and_certmanager/1.1_set_up_global_pull_credential.sh

# 2. Prepare the cluster (projects, CASE packages, prerequisite operators)
./scripts/install_cloud_pak_for_data/2_prepare_cluster/2.0-2.1_preliminary_setup/2.0_preliminary_setup.sh
./scripts/install_cloud_pak_for_data/2_prepare_cluster/2.2_install_prerequisite_operators/2.2_install_prerequisite_operators.sh

# 3. Install IBM Software Hub
./scripts/install_cloud_pak_for_data/3_install_softwarehub/3.1_full_step_3_installprocess-softwarehub.sh

# 4. Install the CP4D components you selected
./scripts/install_cloud_pak_for_data/4_install_components/4.0_full_step_4_installprocess-cpd.sh
```

Steps 0.1-0.2 and 1.0 are only needed once per workstation/cluster.

`2.2_install_prerequisite_operators.sh` installs NVIDIA Node Feature Discovery + GPU operator, Red Hat OpenShift AI (+ Service Mesh) and Multicloud Object Gateway in parallel lanes (`INSTALL_OPERATORS_IN_PARALLEL=false` to run them one by one), and adds IBM Knative Eventing only when `watsonx_orchestrate` or `watson_assistant` is selected. Each `2.2.x` script can also be run alone.

Steps 3 and 4 are themselves wrappers - the individual sub-steps (`3.2` admin setup, `3.3` Software Hub install, `3.4` entitlements, `3.5` CCS CR, `4.1` components, `4.2` cpd-cli profile, …) sit next to them and can be run on their own when you need to redo just one part. Step 4 also has watsonx Orchestrate pre-verification and watsonx.data OpenSearch install scripts, and `4.x*` scripts for CR upgrades and image pull fixes.

Scripts run `./scripts/0.0_make_executable.sh` on their own if any `.sh` isn't executable or the podman machine isn't running; you can also run it manually.

---

## Useful extras

```bash
# Check cluster readiness before installing
./scripts/install_cloud_pak_for_data/3_install_softwarehub/3.0_cluster_health_check.sh

# Troubleshooting and teardown
ls scripts/install_cloud_pak_for_data/x_clean_or_debug_cp4d/
```

After the base install is up:

- `scripts/install_cloud_pak_for_data/4.5_service_instance_setups/` provisions service instances: Db2, EDB Postgres, Databand Postgres, Informix, DataStax HCD, OpenPages and Planning Analytics.
- `scripts/install_cloud_pak_for_data/5_component_specific_scripts/` holds per-service follow-ups:
  - `cp4d_databases/`, `cp4d_informix/` - Db2 SCC prep, EDB Postgres and Informix prep
  - `cp4d_general/` - Software Hub admins on a project, CPD projects, service routes, watsonx.data premium UI features
  - `cp4d_streamsets/` - StreamSets project, environment and engine setup end to end
  - `wxd_opensearch/`, `wxd_datastax_hcd/` - watsonx.data OpenSearch and DataStax HCD prep and fixes
  - `wxo_adk_and_custom_model_import/` - watsonx Orchestrate ADK image support, environments and custom model import
  - `wxai_model_gateway_model_import/` - register providers/models with the watsonx.ai model gateway (model definitions under `models/`)

`src/utilities/ibmcloud_secrets_manager_variable_management/` can upload your generated configs to IBM Cloud Secrets Manager and rebuild them from there later (run either script with `--help`).

`src/utilities/cpd-cli_utils/` covers `cpd-cli` upkeep: upgrading to a Software Hub version, refreshing/toggling the OLM utils image, cleaning the workspace, enabling premium features, and creating/deleting CR instances from `src/cr_yaml_examples/`.

### Users, service IDs and API keys

Scripts in `src/utilities/redhat_openshift_utils/` and `src/utilities/softwarehub_utils/`, run in this order:

1. `set_htpasswd_users.sh` - htpasswd login users for people (credentials in `configs/openshift_config/htpasswd_credentials.txt`); `set_cluster_access_groups.sh` creates read-only/edit OpenShift groups, and `grant_softwarehub_admin_to_ocp_admins.sh` gives cluster admins Software Hub admin rights.
2. `set_service_id_user_proxies.sh` - non-human service ID accounts on a hidden identity provider, added to Software Hub (credentials in `configs/openshift_config/service_id_credentials.txt`).
3. `generate_service_id_cpd_apikeys.sh` - a fresh Software Hub API key per service ID (this revokes any previous key).
4. `store_cpd_apikeys_in_vault.sh` - stores those API keys (and optionally username/password) as secrets in the Software Hub internal vault; safe to re-run.

Pull secrets: `set_default_pull_secret.sh` and `set_namespace_pull_secret.sh`. Software Hub checks: `get_instance_addon_list.sh` and `wxo-prereq-check.sh`.

---

## Confluent Platform

Config lives in `configs/confluent_platform_config/confluent_vars.sh`. Create it in one of two ways:

- **Notebook** - `marimo run confluent_platform_vars_generation.py`: pick the cluster login, t-shirt size, storage classes, security options and components (optionally the Flink add-on), then **Save directly to ./configs/confluent_platform_config/**. An existing `confluent_vars.sh` is copied to `confluent_vars.sh.bak` first.
- **Templating script** - `./scripts/install_confluent_platform/0_confluent_prepare_template_config.sh --size small` (plus `install_confluent_platform_flink_addon/0_flink_prepare_template_config.sh` for Flink).

The two are compatible: re-running the `0_*` scripts on a notebook-generated file only rewrites the managed sizing blocks.

Then run the full install:

```bash
./scripts/install_confluent_platform/full_installprocess-confluent_platform.sh
```

It runs `1.0` prep → `1.1` install → `1.2` status → `1.3` instance details (it does not run step `0`). If `confluent_vars.sh` holds the Flink settings, the Flink add-on's full install follows automatically; set `DO_FLINK_ADDON=false` to skip it. Each step can be toggled the same way (`DO_CONFLUENT_PREP=false`, …), or run the numbered `1.x_*.sh` scripts one at a time instead.

Auth, connectors, external access and uninstall live under `utility_scripts_confluent_platform/`. `x.0_confluent_uninstall.sh` also removes the Flink add-on first when its settings are present (`DO_FLINK_UNINSTALL=false` to keep it), carrying over the same data policy; `x.1_confluent_reinstall.sh` rebuilds the platform only and leaves Flink in place. `source scripts/install_confluent_platform/confluent_cli_login.sh` installs the `confluent` CLI if needed and logs it in to the deployed cluster. `x.5_confluent_add_cert_to_vault.sh` publishes the Kafka CA certificates found on the cluster (external listener, and in-cluster for `SASL_SSL`) to the Software Hub internal vault as `certificate` secrets shared with the *All Users* group, so CPD services can pick them when connecting to Kafka; it reads the Software Hub login from `configs/cp4d_config/cpd_instance_details.sh` and is safe to re-run after a certificate rotation. For Flink (install steps, auth, sample job, Kafka connection), see [install_confluent_platform_flink_addon/README.md](scripts/install_confluent_platform/install_confluent_platform_flink_addon/README.md).

When both configs exist, Confluent values override CP4D ones; set `ENV_TARGET=<name|path>` to load only a single config.

---
