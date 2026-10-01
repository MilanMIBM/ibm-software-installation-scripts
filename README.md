# cp4d-installation-scripts

Scripts and config generators for installing **IBM Software Hub / Cloud Pak for Data (and various components)** into a Redhat OpenShift cluster.

The workflow has two stages:

1. **Generating a config** - running marimo notebooks to fill in cluster URL, credentials, entitlement key, storage classes and the components you want. Thereby creating configs used in the installation `cpd_vars.sh` and `install-options.yml` into a subfolder `./cp4d_config/`.
2. **Running the install** - either the full chained script, or the numbered step scripts one at a time. Every script sources the variables from the configs in `./cp4d_config/` automatically.

---

## Repository overview

| Path                    | What's in it                                                                                                                               |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `*_vars_generation*.py` | Marimo notebooks - the config generators. Branches may include unique streamlined variants with presets for specific installation options. |
| `cp4d_config/`          | Your generated config lives here. Every `.sh` in this folder is sourced by the install scripts                                             |
| `example_config/`       | Reference `cpd_vars.sh` and `install-options.yml` to look at if you'd rather hand-write them                                               |
| `src/scripts/`          | The numbered install steps (0 → 4), plus cleanup/debug scripts under `x_clean_or_debug_cpd/`                                               |
| `src/helpers/`          | Jinja2 templates and marimo widgets backing the notebooks                                                                                  |
| `src/utils/`            | Extras: cpd-cli maintenance, config storage helpers, Terraform variant of the cluster prep                                                 |
| `env_bootstrap.sh`      | Sourced by every script to find the repo root and load `cp4d_config/`                                                                      |

---

## Prerequisites

- OpenShift cluster + `oc` and `cpd-cli` (installers for both under [src/scripts/0_initial_setup/](src/scripts/0_initial_setup/), macOS only)
- Python 3.12+
- An IBM entitlement key

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
4. Click **Save directly to ./cp4d_config/**.

That writes:

- `cp4d_config/cpd_vars.sh` - all the `export`s the install scripts rely on
- `cp4d_config/install-options.yml` - component list and install options for `cpd-cli`

The two **Save your … file** buttons next to it download the files to your browser's download folder instead, if you want a copy elsewhere.

> Anything you drop into `cp4d_config/` as a `.sh` file gets sourced, so you can split extra variables into their own files.

---

## 2. Run the install

### Everything at once

```bash
./src/scripts/x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh
```

This chains the steps below in order, timing each one and stopping on the first failure. The `DO_*` toggles at the top of the script let you skip stages you've already completed.

### Step by step

Run these in order - each one is standalone and loads the config itself:

```bash
# 0. One-time workstation + cluster setup
./src/scripts/0_initial_setup/0.1_install_oc-MAC-ONLY.sh
./src/scripts/0_initial_setup/0.2_install_cpd_cli-MAC-ONLY.sh
./src/scripts/0_initial_setup/0.3_set_up_openshift_certmanager.sh

# 1. Global pull secret
./src/scripts/1_global_pull_secrets/1.0_set_up_global_pull_credential.sh

# 2. Prepare the cluster (projects, CASE packages, prerequisite operators)
./src/scripts/2_prepare_cluster/2.0-2.1_preliminary_setup/2.0_preliminary_setup.sh
./src/scripts/2_prepare_cluster/2.2_install_prerequisite_operators/2.2_install_prerequisite_operators.sh

# 3. Install IBM Software Hub
./src/scripts/3_install_softwarehub/3.1_full_step_3_installprocess-softwarehub.sh

# 4. Install the CP4D components you selected
./src/scripts/4_install_components/4.0_full_step_4_installprocess-cpd.sh
```

Steps 0.1-0.3 are only needed once per workstation/cluster. Steps 3 and 4 are themselves wrappers - the individual sub-steps (`3.2`, `3.3`, `4.1`, `4.2`, …) sit next to them and can be run on their own when you need to redo just one part.

If a script isn't executable, run `./src/scripts/0.0_make_executable.sh` once.

---

## Useful extras

```bash
# Check cluster readiness before installing
./src/scripts/3_install_softwarehub/3.0_cluster_health_check.sh

# Troubleshooting and teardown
ls src/scripts/x_clean_or_debug_cpd/
```

`src/scripts/5_component_specific_scripts/` and `4.5_service_instance_setups/` hold per-service follow-ups (Db2, service routes, SCC prep) for after the base install is up. Which of these exist varies by branch.

---
