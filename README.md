# ibm-software-installation-scripts

Scripts and config generators for installing **IBM Software Hub / Cloud Pak for Data (and various components)** into a Redhat OpenShift cluster, plus scripts for **Confluent Platform** (with an optional Flink add-on) and **IBM Concert** (Concert, Data Apps, Workflows - see [IBM Concert](#ibm-concert)).

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
| `scripts/install_ibm_concert/` | IBM Concert install steps (0 → 4) around IBM's own installer, data store provisioning, optional Concert Optimize / Turbonomic (5), plus cleanup/debug scripts under `x_clean_or_debug_concert/` |
| `concert_workspace/` | IBM Concert installer archives, the extracted installer, runner build context and copied logs (gitignored) |
| `scripts/*.sh` | Shared script plumbing: `source_env_setup.sh` (config loading), `0.0_make_executable.sh`, and `operator_install_helpers.sh` (idempotency checks so OLM operator installs are safe to re-run) |
| `src/helpers/` | Jinja2 templates and marimo widgets backing the notebooks, plus Python/zsh helpers: IBM Cloud IAM auth, watsonx.data database registration, IBM License Service, IBM Cloud Secrets Manager, the Software Hub internal vault, and the Software Hub → `cpd-cli` release resolver |
| `src/cr_yaml_examples/` | Jinja2 custom resource templates rendered by `src/utilities/cpd-cli_utils/create_cr_instance.sh` |
| `src/utilities/` | Extras: `cpd-cli` maintenance (upgrade, OLM image, workspace cleanup, premium features, CR create/delete), IBM Cloud Secrets Manager config storage, OpenShift pull secret/access group/htpasswd/service ID helpers, Software Hub checks and API key vault storage, OADP tenant backup/restore |
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

`src/utilities/oadp_backup_restore_cp4d_utils/` backs up a Software Hub instance to an off-cluster S3 bucket with `cpd-cli oadp tenant-backup` and restores it onto another cluster (bucket and restore target configs are generated into gitignored subfolders there; see its [README](src/utilities/oadp_backup_restore_cp4d_utils/README.md)).

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

Kafka SASL mechanisms are set per listener: `CONFLUENT_SASL_MECHANISM` is the one the brokers and components use, `CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS` lists what in-cluster clients may use, and `CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS` what the EXTERNAL listener accepts. StreamSets (watsonx.data) connects to the internal bootstrap with PLAIN only (SCRAM-SHA-512 failed there), so keep `PLAIN` in the internal list while it is used.

Each script loads only its own product's config, chosen from the folder it lives in (`install_cloud_pak_for_data/` and `src/utilities/` → `cpd`, `install_confluent_platform/` → `confluent`, `install_ibm_concert/` → `concert`). Override per run with `--env-target <name|path|all>` or `ENV_TARGET=<name|path|all>`; `all` loads every config as before.

### Version presets

```bash
# Current preset (Confluent Platform 8.2.0)
export CONFLUENT_VERSION="8.2.0"
export CONFLUENT_C3_VERSION="2.5.0"
export FLINK_CMF_CHART_VERSION="2.4.2"
export FLINK_OPERATOR_CHART_VERSION="1.150.3"
export FLINK_APPLICATION_IMAGE="confluentinc/cp-flink:2.0.2-cp3"
export FLINK_SQL_IMAGE="confluentinc/cp-flink-sql:1.19-cp11"
export FLINK_APPLICATION_VERSION="v2_0"
export FLINK_SQL_VERSION="v1_19"
```

```bash
# Recommended (Confluent Platform 8.3.2)
export CONFLUENT_VERSION="8.3.2"
export CONFLUENT_C3_VERSION="2.6.1"
export FLINK_CMF_CHART_VERSION="2.4.3"
export FLINK_OPERATOR_CHART_VERSION="1.150.4"
export FLINK_APPLICATION_IMAGE="confluentinc/cp-flink:2.0.2-cp4"
export FLINK_SQL_IMAGE="confluentinc/cp-flink-sql:1.19-cp12"
export FLINK_APPLICATION_VERSION="v2_0"
export FLINK_SQL_VERSION="v1_19"
```

---

## IBM Concert

Installs **IBM Concert 3.1.x** - Hub, Concert, Concert Data Apps and Concert Workflows (plus Secure Coder, VEIAS and the cross-product integration) - onto an existing OpenShift 4.18+ cluster with IBM's own installer (`bin/setup` from the [IBM/Concert GitHub releases](https://github.com/IBM/Concert/releases)). The scripts prepare everything around it and run it unmodified. Optionally they also install **Concert Optimize** (IBM Turbonomic) on the same cluster and attach it to the Hub.

Config lives in `configs/concert_config/concert_vars.sh`. Create it with the notebook:

```bash
marimo run ibm_concert_vars_generation.py
```

Pick the release, profile (`production` by default, `small`, or `custom` to choose the Hub/Concert scale levels and worker sizing yourself - a live estimate compares resource requests with the workers), product combination, image source (IBM registry, mirrored or air-gapped private registry), where IBM's installer runs, the Hub mode, and which data stores are external, then **Save directly to ./configs/concert_config/**. Every Concert script loads only this file (`ENV_TARGET=concert`); for an interactive shell use `ENV_TARGET=concert source s_env.sh`.

Then run the full install:

```bash
./scripts/install_ibm_concert/0_x_full_quick_install_script/full_concert_installprocess.sh
```

| Step | What it does |
| --- | --- |
| `0_initial_setup/0.1` | Downloads the installer archive (SHA-256 recorded/verified) and a linux helm, extracts to `concert_workspace/<version>/` |
| `0_initial_setup/0.2` | Prepares the **runner**: IBM's installer reads the machine it runs on (`uname -m` - an Apple Silicon Mac would silently disable Concert buddy and the Workflows MCP server - plus bash 4 / GNU tools), so it runs as a **Job in the target cluster** by default (image built in-cluster). `CONCERT_RUNNER=container` (podman here) and `native` (Linux x86 bastion) are the alternatives |
| `1_registry_access_and_mirroring/` | `1.0` optional global pull secret (shared, cpd-cli-free `src/utilities/redhat_openshift_utils/set_global_pull_secret.sh`), `1.1` mirror IBM's images with `oc image mirror` keeping IBM's `/cp/platform-hub` + `/cp/concert` layout (`--phase=save\|load` for air-gap), `1.2`/`1.3` mirror and apply the non-IBM operators/images the data stores and Istio need, `1.4` FaaS insecure-registry entry (only when FaaS is on) |
| `2_prepare_cluster/` | `2.0` preflight, `2.0.1` worker capacity vs the profile (changes MachineSets only with `CONCERT_AUTOSCALE_APPLY=true`), `2.1` projects, `2.2` Service Mesh 3 (CP4D script, reused) + IBM's Workflows Istio setup, `2.3*` provision the external data stores, `2.4` IBM's data store secrets |
| `3_install_concert/` | `3.0` renders `params.ini` from `concert_vars.sh`, `3.1` IBM preview (experimental, off), `3.2` runs IBM's installer (refuses if an external store's secret is missing), `3.3` status (`--wait`), `3.4` URLs → `concert_instance_details.sh` |
| `4_post_install/` | `4.0` rotate the admin password, `4.1` Keycloak users from `concert_users.txt` (or `--from-htpasswd`), `4.2` BYO TLS certificate, `4.3` remote Hub access keys / product registration, `4.5` scale Concert up/down (or on a schedule) with IBM's deployment scaler - no reinstall |
| `5_install_optimize/` | Only with **Concert Optimize** selected in the notebook. `5.1` the Turbonomic `t8c-operator`, pinned to the release IBM's version matrix pairs with the Hub (Hub 3.0.3 ↔ Turbonomic 8.21.2), `5.2` a plain Turbonomic, `5.3` its administrator and license through the REST API (`--license=<file>`), `5.4` Concert mode (IBM's platform-gateway CR) behind a reencrypt Route, `5.5` attach to the Hub with IBM's `manage-product.sh`, `5.6` status (`--wait`) |

Defaults and why:

- **External data stores**, provisioned into `ibm-concert-datastores`: PostgreSQL 16 (CloudNativePG, HA in production, with `pgvector`), S3 buckets (ODF Multicloud Object Gateway - reused if present), MySQL for Workflows, Redis for Data Apps, Neo4j when VEIAS is selected. IBM decides external vs built-in only by secrets that must exist **before** a product's first install, and the choice cannot be changed afterwards. Each store can be switched to IBM's built-in one or to an existing server in the notebook.
- **Workflows with Istio** (Service Mesh 3), FaaS off - IBM does not support both together.
- **Hub `auto`**: a local Hub, or a remote one when its URL and access key are set; `local` ignores remote settings.
- **Optimize off** by default. When selected, it runs in its own namespace (`turbonomic`) on the Concert cluster. It needs the cluster to pull from `icr.io/cpopen` (no mirrored/air-gapped mode yet), a Turbonomic license from Passport Advantage (`CONCERT_OPTIMIZE_LICENSE_FILE`), and IBM's minimum of 4 vCPU / 32 GB on top of Concert. Concert Observe (Instana) is not covered: it installs with `stanctl` onto its own Linux hosts.

`x_clean_or_debug_concert/` has status/debug helpers (`x_fetch_installer_logs.sh`, `x_runner_shell.sh`, `x_concert_mustgather.sh`, `x_delete_stuck_pods_concert.sh`, `x_restart_concert_components.sh`) and teardown (`x_uninstall_concert.sh`, `x_uninstall_optimize.sh` - keeps Turbonomic's volumes unless `--delete-namespace`, `x_uninstall_datastores.sh` - destroys all data).
