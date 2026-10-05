# ibm-software-installation-scripts

Scripts and config generators for installing **IBM Software Hub / Cloud Pak for Data (and various components)** into a Redhat OpenShift cluster, plus scripts for **Confluent Platform** (with an optional Flink add-on).

The Cloud Pak for Data workflow has two stages:

1. **Generating a config** - running marimo notebooks to fill in cluster URL, credentials, entitlement key, storage classes and the components you want. Thereby creating configs used in the installation `cpd_vars.sh` and `install-options.yml` into the subfolder `./configs/cp4d_config/`.
2. **Running the install** - either the full chained script, or the numbered step scripts one at a time. Every script sources the variables from the configs in `./configs/` automatically.

---

## Repository overview

| Path                                  | What's in it                                                                                                                                                                             |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `*_vars_generation*.py`               | Marimo notebooks - the config generators. Branches may include unique streamlined variants with presets for specific installation options.                                               |
| `configs/`                            | Your generated configs live here, one subfolder per product (`cp4d_config/`, `confluent_platform_config/`, …). Every `.sh` directly inside a subfolder is sourced by the install scripts |
| `scripts/install_cloud_pak_for_data/` | The numbered install steps (0 → 5), plus cleanup/debug scripts under `x_clean_or_debug_cp4d/`                                                                                            |
| `scripts/install_confluent_platform/` | Confluent Platform install steps, utility scripts, and the Flink add-on (`install_confluent_platform_flink_addon/`, has its own README)                                                  |
| `src/helpers/`                        | Jinja2 templates and marimo widgets backing the notebooks                                                                                                                                |
| `src/utilities/`                      | Extras: cpd-cli maintenance, IBM Cloud Secrets Manager config storage, OpenShift pull secret/access group/htpasswd login helpers, Software Hub checks                                    |
| `env_bootstrap.sh`                    | Sourced by every script to find the repo root and load `configs/` (via `scripts/source_env_setup.sh`)                                                                                    |
| `service_instances/`                  | Output folder for payloads written by the `4.5_service_instance_setups/` provisioning scripts (gitignored)                                                                               |

---

## Prerequisites

- OpenShift cluster + `oc` and `cpd-cli` (installers for both under [scripts/install_cloud_pak_for_data/0_initial_setup/](scripts/install_cloud_pak_for_data/0_initial_setup/), macOS only)
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

Steps 0.1-0.2 and 1.0 are only needed once per workstation/cluster. Steps 3 and 4 are themselves wrappers - the individual sub-steps (`3.2`, `3.3`, `4.1`, `4.2`, …) sit next to them and can be run on their own when you need to redo just one part.

Scripts run `./scripts/0.0_make_executable.sh` on their own if any `.sh` isn't executable or the podman machine isn't running; you can also run it manually.

---

## Useful extras

```bash
# Check cluster readiness before installing
./scripts/install_cloud_pak_for_data/3_install_softwarehub/3.0_cluster_health_check.sh

# Troubleshooting and teardown
ls scripts/install_cloud_pak_for_data/x_clean_or_debug_cp4d/
```

`scripts/install_cloud_pak_for_data/5_component_specific_scripts/` and `4.5_service_instance_setups/` hold per-service follow-ups (Db2, EDB Postgres, Informix, OpenSearch, DataStax HCD, watsonx Orchestrate, service routes, SCC prep) for after the base install is up.

`src/utilities/ibmcloud_secrets_manager_variable_management/` can upload your generated configs to IBM Cloud Secrets Manager and rebuild them from there later (run either script with `--help`).

---

## Confluent Platform

Config lives in `configs/confluent_platform_config/confluent_vars.sh`. Then run in order:

```bash
./scripts/install_confluent_platform/0_confluent_prepare_template_config.sh --size small   # apply sizing preset
./scripts/install_confluent_platform/1.0_confluent_prep.sh
./scripts/install_confluent_platform/1.1_confluent_install.sh
./scripts/install_confluent_platform/1.2_confluent_status.sh
./scripts/install_confluent_platform/1.3_confluent_get_instance_details.sh
```

Auth, connectors, external access and uninstall live under `utility_scripts_confluent_platform/`. For Flink, see [install_confluent_platform_flink_addon/README.md](scripts/install_confluent_platform/install_confluent_platform_flink_addon/README.md).

When both configs exist, Confluent values override CP4D ones; set `ENV_TARGET=<name|path>` to load only a single config.

---
