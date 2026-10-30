# ibm-software-installation-scripts

Scripts and config generators for installing **IBM Software Hub / Cloud Pak for Data (and various components)** into a Redhat OpenShift cluster, plus scripts for **Confluent Platform** (with an optional Flink add-on), **IBM Concert** (Concert, Data Apps, Workflows - see [IBM Concert](#ibm-concert)) and a standalone **DataStax Mission Control** (see [DataStax Mission Control](#datastax-mission-control-standalone)).

The Cloud Pak for Data workflow has two stages:

1. **Generating a config** - running marimo notebooks to fill in cluster URL, credentials, entitlement key, storage classes and the components you want. Thereby creating configs used in the installation `cpd_vars.sh` and `install-options.yml` into the subfolder `./configs/cp4d_config/`.
2. **Running the install** - either the full chained script, or the numbered step scripts one at a time. Every script sources the variables from the configs in `./configs/` automatically.

---

## Repository overview

| Path | What's in it |
| --- | --- |
| `*_vars_generation*.py` | Marimo notebooks - the config generators. Branches may include unique streamlined variants with presets for specific installation options. |
| `configs/` | Your generated configs live here (gitignored), one subfolder per product (`cp4d_config/`, `confluent_platform_config/`, …). Every `.sh` directly inside a subfolder is sourced by the install scripts. `openshift_config/` holds the credential files written by the user/service ID utilities. |
| `scripts/install_cloud_pak_for_data/` | The numbered install steps (0 → 5), service instance provisioning (`4.5_service_instance_setups/`), the live CR state dashboard under `check_cr_status/`, plus cleanup/debug scripts under `x_clean_or_debug_cp4d/` |
| `scripts/install_confluent_platform/` | Confluent Platform install steps, utility scripts, and the Flink add-on (`install_confluent_platform_flink_addon/`, has its own README) |
| `scripts/install_ibm_concert/` | IBM Concert install steps (0 → 4) around IBM's own installer, data store provisioning, optional Concert Optimize / Turbonomic (5), plus cleanup/debug scripts under `x_clean_or_debug_concert/` |
| `scripts/install_datastax_mc_standalone/` | DataStax Mission Control on OpenShift with Helm, independent of CP4D: config generator (0), cluster prep (1), install (2), internode NetworkPolicy (3), uninstall under `x_clean_or_debug_datastax_mc/`. DataStax's OpenShift Helm values templates are in `src/helpers/datastax_mc_helm_values_templates/` |
| `scripts/private_registry_mirroring/` | Mirrors the images, operator catalogs, charts and files of the installs above into a private registry (cloud, or local/air-gapped), and points the cluster and the installs at it: config generator and registry tools (0), mapping (1), mirroring and the stop-over bundle (2), cluster configuration (3), plus cleanup/listing under `x_clean_or_debug_registry/` |
| `registry_mirror_workspace/` | The mirroring track's inventory, tools, local registry and default stop-over bundle (gitignored) |
| `concert_workspace/` | IBM Concert installer archives, the extracted installer, runner build context and copied logs (gitignored) |
| `scripts/*.sh` | Shared script plumbing: `0_initial_check_in.sh` (POSIX `sh` zsh check / install, run first), `source_env_setup.sh` (config loading), `0.0_make_executable.sh`, and `operator_install_helpers.sh` (idempotency checks so OLM operator installs are safe to re-run) |
| `src/helpers/` | Jinja2 templates and marimo widgets backing the notebooks, plus Python/zsh helpers: IBM Cloud IAM auth, watsonx.data database registration, IBM License Service, IBM Cloud Secrets Manager, the Software Hub internal vault, the Software Hub → `cpd-cli` release resolver, and DataStax Mission Control's Helm values templates. Shell libraries: `common_helpers.sh` (logging, waits, `h_run_step` for the chained installs), one per track (`concert_`, `confluent_`, `datastax_mc_`, `private_registry_helpers.sh`), `cpd_api_helpers.sh` (Software Hub REST sign-in and calls) and `ocp_utils_helpers.sh` (OpenShift login flags, pull secrets, htpasswd providers). Versions, channels and image tags: `version_resolver.sh` reads them from the release metadata and downloaded CASEs (`cpd_release_meta.py`), the cluster's operator catalogs, registry tag listings (`image_tags.py`) and `version_catalog.json` (the pins nothing else carries - edit defaults there); the lookups the scripts did before are kept in `legacy_version_resolution.sh/.py` and used whenever a new lookup fails |
| `src/cr_yaml_examples/` | Jinja2 custom resource templates rendered by `src/utilities/cpd-cli_utils/create_cr_instance.sh` |
| `src/utilities/` | Extras: `cpd-cli` maintenance (upgrade, OLM image, workspace cleanup, premium features, CR create/delete), IBM Cloud Secrets Manager config storage, OpenShift pull secret/access group/htpasswd/service ID helpers, Software Hub checks and API key vault storage, OADP tenant backup/restore, `helm` / `kubectl` installers |
| `env_bootstrap.sh` | Sourced by every script to find the repo root and load `configs/` (via `scripts/source_env_setup.sh`) |
| `s_env.sh` | `source s_env.sh` in your shell to load the configs and log in to the cluster with `oc` |
| `service_instances/` | Output folder for payloads written by the `4.5_service_instance_setups/` provisioning scripts (gitignored) |
| `datastax_mc_workspace/` | The pinned Helm 3 that Mission Control needs, when the `helm` on PATH is outside 3.14 - 3.18 (gitignored) |
| `cpd-cli-workspace/` | Health check results and logs that `cpd-cli` writes when run from the repo root (gitignored) |

---

## Prerequisites

- OpenShift cluster + `oc` and `cpd-cli` (installers for both under [scripts/install_cloud_pak_for_data/0_initial_setup/](scripts/install_cloud_pak_for_data/0_initial_setup/), macOS only)
- `zsh` - the scripts are zsh scripts; run them directly (`./script.sh`), not with `sh script.sh`. To check for it, run `sh scripts/0_initial_check_in.sh` first (plain `sh`, so it runs before zsh exists, on macOS, Linux, WSL, Git Bash, MSYS2 or Cygwin). If zsh is missing, it offers to install it with the OS's own package manager. If zsh is installed somewhere other than `/bin/zsh`, it offers to link `/bin/zsh` to it.
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

To resume after a failure, start at a named step with `--from` (and leave others out with `--skip`); `--list-steps` shows what a run would do:

```bash
./scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh --from prereq-operators
```

Steps: `registry-config`, `certmanager`, `pull-secret`, `preliminary`, `prereq-operators`, `softwarehub`, `cpd`.

Every chained script (the `full_*` installs for each product, the step sub-chains such as `3.1_full_step_3_*`, the mirroring track and the OADP fresh-cluster restore) takes the same `--from` / `--skip` / `--list-steps` options; `--help` lists its step names. The CP4D patch update uses `--from-step`, since its `--from` is a version.

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

`2.2_install_prerequisite_operators.sh` runs the NVIDIA Node Feature Discovery + GPU operator, Red Hat OpenShift AI (+ Service Mesh), Multicloud Object Gateway and IBM Knative Eventing installs in parallel lanes (`INSTALL_OPERATORS_IN_PARALLEL=false` to run them one by one). Run that way, each operator is installed only when a component in `CPD_COMPONENTS` needs it with its install options (IBM's defaults where `install-options.yml` sets none), following IBM's prerequisite tables in `src/helpers/cp4d_prereq_requirements.py`. Override per operator with `auto` (default), `true` (skip) or `false` (install anyway): `SKIP_GPU_OPERATORS_INSTALL`, `SKIP_RHOAI_INSTALL`, `SKIP_MCG_INSTALL`, `SKIP_KNATIVE_EVENTING_INSTALL`; `RHOAI_CREATE_DSC` does the same for the OpenShift AI DataScienceCluster. Each `2.2.x` script can also be run alone; run directly, it installs its operator whatever `CPD_COMPONENTS` holds (it prints a banner saying so; set its switch to `auto` for the needs-based check).

Steps 3 and 4 are themselves wrappers - the individual sub-steps (`3.2` admin setup, `3.3` Software Hub install, `3.4` entitlements, `3.5` CCS CR, `4.1` components, `4.2` cpd-cli profile, …) sit next to them and can be run on their own when you need to redo just one part. Step 4 also has watsonx Orchestrate pre-verification and watsonx.data OpenSearch install scripts, and `4.x*` scripts for CR upgrades and image pull fixes.

Scripts run `./scripts/0.0_make_executable.sh` on their own if any `.sh` isn't executable or the podman machine isn't running; you can also run it manually.

---

## Useful extras

```bash
# Check cluster readiness before installing
./scripts/install_cloud_pak_for_data/3_install_softwarehub/3.0_cluster_health_check.sh

# Troubleshooting and teardown
ls scripts/install_cloud_pak_for_data/x_clean_or_debug_cp4d/

# Live dashboard of the component CRs (read-only; q to quit, ? for the colour legend)
./scripts/install_cloud_pak_for_data/check_cr_status/x_cr_state_dashboard.sh
```

`check_cr_status/x_cr_state_dashboard.sh` shows every CP4D component CR from `cpd_vars.sh` as a glowing dot - healthy, in progress, scaling, stuck, failing, or inactive - with the chains they wait on and own, % progress and the step the operator is on. It works on whatever the CRs are doing (install, scale change, crash, shutdown), never changes the cluster and writes no files. `--once` prints the state and exits; `--help` lists every option. The code is the `src/tui/cr_dashboard/` package (`src/tui/` holds the Textual TUIs).

After the base install is up:

- `scripts/install_cloud_pak_for_data/4.5_service_instance_setups/` provisions service instances: Db2, EDB Postgres, Databand Postgres, Informix, DataStax HCD, OpenPages and Planning Analytics.
  - `x_service_instance_manager.sh` lists the add-ons that can create service instances and every existing instance with its state (read-only; `--once`, `--explain <type>`, `--storage-report`, `--help`). It discovers each type's fields from the cluster rather than hardcoding them.
  - `x_repair_cpd_cli_profile.sh` checks that the `cpd-cli` profile points at this cluster and authenticates, and repairs it only when it doesn't (`--check` to only report).
- `scripts/install_cloud_pak_for_data/5_component_specific_scripts/` holds per-service follow-ups:
  - `cp4d_databases/`, `cp4d_informix/` - Db2 SCC prep, EDB Postgres and Informix prep
  - `cp4d_general/` - Software Hub admins on a project, CPD projects, service routes, watsonx.data premium UI features
  - `cp4d_streamsets/` - StreamSets project, environment and engine setup end to end
  - `wxd_opensearch/`, `wxd_datastax_hcd/` - watsonx.data OpenSearch and DataStax HCD prep and fixes
  - `wxd_presto_engines/` - create or re-size a custom-sized watsonx.data Presto engine (registered through the lakehouse API so the console and catalogs know it, sized on its `WxdEngine` CR)
  - `wxo_adk_and_custom_model_import/` - watsonx Orchestrate ADK image support, environments and custom model import
  - `wxai_model_gateway_model_import/` - register providers/models with the watsonx.ai model gateway (model definitions under `models/`)

`src/utilities/ibmcloud_secrets_manager_variable_management/` can upload your generated configs to IBM Cloud Secrets Manager and rebuild them from there later (run either script with `--help`).

`src/utilities/cli_tool_utils/` installs workstation CLIs on macOS, Linux and Windows (Git Bash / MSYS2), sha256 verified, into `/usr/local/bin` by default (`--dir` to change it, `--check` to only report). Both do nothing when the tool is already on PATH, and never touch a copy installed elsewhere (e.g. Homebrew's):

- `install_helm.sh` installs Helm `v3.18.4` by default, the version this repo pins for Mission Control and Concert (`--version latest` / `latest-3` for others). The Flink prep and the mirroring tool check offer it when helm is missing, Mission Control's `0.1_fetch_helm.sh` uses it for its pinned helm, and `scripts/0_initial_check_in.sh` reports the helm on PATH.
- `install_kubectl.sh` matches the Kubernetes minor of the cluster you are logged in to, else the latest stable, and warns when the kubectl on PATH is more than one minor away from the cluster. On OpenShift, `oc` already ships a kubectl.

`src/utilities/cpd-cli_utils/` covers `cpd-cli` upkeep: upgrading to a Software Hub version, refreshing/toggling the OLM utils image, cleaning the workspace, enabling premium features, and creating/deleting CR instances from `src/cr_yaml_examples/`.

`src/utilities/oadp_backup_restore_cp4d_utils/` backs up a Software Hub instance to an off-cluster S3 bucket with `cpd-cli oadp tenant-backup` and restores it onto another cluster (bucket and restore target configs are generated into gitignored subfolders there; see its [README](src/utilities/oadp_backup_restore_cp4d_utils/README.md)).

### Cluster fixes

Scripts in `x_clean_or_debug_cp4d/` that repair known IBM / OpenShift faults. Each one detects the fault first and changes nothing when the fault isn't there. `--preview=true` (or `--dry-run`) only reports what it would change.

- `x_fix_nginx_lua_block_config.sh` repairs nginx proxies that crash-loop on an empty Lua block their operator rendered (e.g. watsonx Orchestrate's `wo-uiproxy`). The operator puts the fault back on reconcile, so it also installs a watcher that re-applies the fix (namespace `cpd-cluster-fixes`; `--uninstall=true` removes it).
- `x_fix_etcd_database_space.sh` compacts and defragments operator-embedded etcds that hit `database space exceeded` (e.g. the Milvus etcd behind watsonx Orchestrate / watsonx.data), restarts the pods that crashed on it, and installs a CronJob to repeat the check.
- `x_fix_oauth_missing_idp_secret.sh` clears the `authentication` ClusterOperator's Degraded state when an htpasswd identity provider points at a missing secret. It creates the secret empty, or with `--remove` drops the provider instead.
- `x_toggle_pane_autoheal.sh` turns on or off an automatic retry for the UI error **"Oops, the pane didn't load."** in connection and other property forms. That message is a client-side render crash in IBM's form library; its *Revert* button redraws the form with your values kept. A small script, injected into every CPD page by `ibm-nginx` (through a `ZenExtension`), presses Revert up to 3 times. It reports each occurrence, with the browser's error stack, to the `ibm-nginx` log. `--action=toggle|on|off|status|validate`: `on` first dry-runs `nginx -t` in `ibm-nginx-tester`, `status` shows the state and the reported errors. A user can opt out in their browser with `localStorage.setItem('cpdPaneAutoheal','off')`.

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

For Iceberg ingestion into a watsonx.data catalog backed by COS, see [connector_configs/README.md](scripts/install_confluent_platform/connector_configs/README.md). Set `DO_ICEBERG_WATSONX_SETUP=true` to run the optional integration setup after the standard Confluent install, or run `x.6_confluent_setup_iceberg_watsonx.sh` separately later. It reuses the plugin and SID helpers, grants lakehouse Metastore Admin, and creates or updates the configured connector. Setup inputs and generated credentials stay in ignored local configuration; generic shell and uploadable Avro JSON examples are included. `--dry-run` reports the required work, and `--prepare-only` writes JSON for manual Control Center upload.

Kafka SASL mechanisms are set per listener: `CONFLUENT_SASL_MECHANISM` is the one the brokers and components use, `CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS` lists what in-cluster clients may use, and `CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS` what the EXTERNAL listener accepts. StreamSets (watsonx.data) connects to the internal bootstrap with PLAIN only (SCRAM-SHA-512 failed there), so keep `PLAIN` in the internal list while it is used.

Each script loads only its own product's config, chosen from the folder it lives in (`install_cloud_pak_for_data/` and `src/utilities/` → `cpd`, `install_confluent_platform/` → `confluent`, `install_ibm_concert/` → `concert`, `install_datastax_mc_standalone/` → `datastax_mc`). Override per run with `--env-target <name|path|all>` or `ENV_TARGET=<name|path|all>`; `all` loads every config as before.

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

---

## DataStax Mission Control (standalone)

Installs **DataStax Mission Control** (chart `oci://icr.io/mission-control-helm/mission-control`, 1.21.2 by default) onto OpenShift 4.8+ with Helm, following DataStax's [OpenShift guide](https://docs.datastax.com/en/mission-control/install/install-mc-openshift.html). It is independent of Cloud Pak for Data: it has its own config, cluster login and namespace, and never reads `cpd_vars.sh` at run time. CP4D's built-in DataStax service is handled separately, under `5_component_specific_scripts/wxd_datastax_hcd/`.

Create the config in `configs/datastax_mc_config/datastax_mc_vars.sh`:

```bash
# blank cluster login / entitlement key to fill in
./scripts/install_datastax_mc_standalone/0_initial_setup/0.0_generate_datastax_mc_config.sh --empty
# or copy OCP_URL, the login, IBM_ENTITLEMENT_KEY and STG_CLASS_BLOCK from a CP4D config
./scripts/install_datastax_mc_standalone/0_initial_setup/0.0_generate_datastax_mc_config.sh --from-cpd [path/to/cpd_vars.sh]
```

Both generate a random admin password and MinIO credentials. `--force` replaces an existing file (a timestamped `.bak` is kept); `--plane data`, `--namespace` and `--admin-email` preset those values. The Helm release is always `mission-control`: DataStax's OpenShift values hard-code service names for it. Review the file afterwards. Then run the full install:

```bash
./scripts/install_datastax_mc_standalone/0_x_full_quick_install_script/full_datastax_mc_installprocess.sh
```

| Step | What it does |
| --- | --- |
| `0_initial_setup/0.1` | Uses `helm` from PATH when it is 3.14 - 3.18 (DataStax's supported range), otherwise downloads `MC_HELM_VERSION` (checksum verified) into `datastax_mc_workspace/tools/` |
| `1_prepare_cluster/1.0` | cert-manager Operator for Red Hat OpenShift (the CP4D `1.0` script, reused), a ≥ 1.18.5 version check, and `--enable-certificate-owner-ref` on `CertManager/cluster` so deleted Certificates take their secrets with them |
| `1.1` | Read-only preflight: OpenShift version, Helm, chart reachable, entitlement key, cert-manager, `openshift-dns/dns-default`, storage class, platform nodes, plane-specific settings |
| `1.2` | Namespace, `<release>-registry` pull secret (`cp` + entitlement key), and the key in the cluster-wide pull secret (shared `set_global_pull_secret.sh`). The global secret is needed because the OpenShift values turn off Mission Control's pull secret copying into project namespaces |
| `1.3` | Labels nodes `mission-control.datastax.com/role=platform`, which every component is pinned to (`MC_PLATFORM_NODES`: `all-workers`, `existing` or a node list) |
| `1.4` | SCCs by `MC_SCC_MODE`: `nonroot-v2` (default), `restricted-v2` or `custom` (DataStax's example SCC) |
| `2_install_mission_control/2.0` | Renders the Helm values: DataStax's OpenShift file for the plane with its tokens filled in, then this repo's overrides, then the restricted-v2 layer, then `MC_EXTRA_VALUES_FILES` |
| `2.1` | Object storage secret, a server-side dry run of every rendered object (a rejected manifest stops here, before Helm leaves a half-installed failed release), then `helm upgrade --install` (install and upgrade are the same command; extra args go to helm, e.g. `--dry-run=server`) |
| `2.2` / `2.3` / `2.4` | Passthrough Route to the UI, status (`--wait`), and `datastax_mc_instance_details.sh` with `DATASTAX_MC_URL` / `_USERNAME` / `_PASSWORD` |
| `3_post_install/3.1` | **Run after creating a project (UI or `--create SLUG`), before creating its first database cluster.** Lets the project's service accounts use `nonroot-v2` (HCD/DSE pods run as UID 999, and Mission Control's operators cannot grant SCCs) and copies the pull secret in. `--remove SLUG` undoes it |
| `3.2` | **Data API** (HTTP/JSON, for astrapy and other Data API clients) for a datacenter: a `DataApi` resource, an edge Route, keyspaces (`--keyspace`, default `default_keyspace`), and `datastax_mc_dataapi_instance_details.sh` with the same `DATASTAX_HCD_*` names as the CP4D scripts, plus a ready-made `DATASTAX_HCD_TOKEN`. `--remove` deletes it |
| `3.3` | **CQL gateway** for drivers outside the cluster: a `CqlConnectivity` in Ingress mode under the cluster's apps domain (passthrough Routes, routed by TLS SNI, so no extra DNS), plus its **Secure Connect Bundle** in `configs/datastax_mc_config/scb/` and `datastax_mc_cql_instance_details.sh`. Drivers use the bundle with local DC `dc1` (the gateway's own); apps inside OpenShift can skip the gateway and use the in-cluster contact point it also writes. `--remove` deletes it |
| `3_post_install/3.0` | Optional NetworkPolicy for project namespaces: internode ports 7000/7001 only from database pods (plus `--allow-cidr` for other clusters). DataStax requires this on shared clusters |

Choices worth knowing:

- **Observability storage** (`MC_OBSERVABILITY_STORE`): `minio` (default) runs the chart's in-cluster MinIO for Loki and Mimir. `s3` uses any S3-compatible endpoint (`MC_S3_*`; leave `MC_S3_ENDPOINT` empty for AWS), and the buckets must already exist. DataStax's control plane file assumes AWS S3.
- **Where DataStax's OpenShift file doesn't match chart 1.21.2**, the overrides correct it (details in `2.0_render_values.sh`):
  - Loki schema: boltdb-shipper v11 becomes the chart's tsdb v13.
  - Loki affinities: the file writes them as strings, which the API rejects; they are re-set as maps.
  - Object storage credentials: they now reach every Mimir and Loki component through `global.extraEnvFrom`.
  - Dex: its HTTPS issuer and TLS volume are restored.
- **SCCs**: the 1.4 grant matters most for Loki. The chart's own SCC binding names a `loki` service account, but Loki runs as `mission-control-loki`. Chart 1.21.2 also grants `anyuid` (SCC priority 10) to its other service accounts, and that outranks `restricted-v2` and the custom SCC. So with those modes, most pods are likely still admitted under `anyuid`; `2.3` lists the SCC each pod actually got. `restricted-v2` renders DataStax's null-UID overrides for the operators, UI, Dex and the Vector aggregator. Loki, Mimir, MinIO and kube-state-metrics pin their UIDs regardless and keep `nonroot-v2`.
- **Data plane** (`MC_PLANE=data`): set `MC_VECTOR_AGGREGATOR_URL` to the control plane's aggregator.
- **Login**: `MC_ADMIN_EMAIL` with `MC_ADMIN_PASSWORD` (a Dex static password, bcrypt-hashed at render time with `htpasswd`, or the python `bcrypt` module as a fallback).

Interactive shell: `source s_env.sh datastax_mc`. Teardown: `x_clean_or_debug_datastax_mc/x_uninstall_mission_control.sh`. It refuses while `MissionControlCluster` resources exist (`--force` overrides) and deletes PVCs unless `--keep-pvcs`. Use `--delete-namespace`, `--delete-crds` (only `clusterconfigs.datastax.com`, as DataStax does) and `--unlabel-nodes` to go further.

---

## Private registry mirroring

Mirrors what the installs above pull - images, OLM operator catalogs, Helm charts and plain files - into a private registry, and then points the cluster and the installs at it. It follows IBM Software Hub 5.4's [private registry flow](https://www.ibm.com/docs/en/software-hub/5.4.x?topic=registry-mirroring-images-directly-private-container) (`cpd-cli manage mirror-images`, olm-utils from the private registry, IDMS/ITMS) and reuses each product's own mirroring where it has one (Concert's `1.1`). Two kinds of registry are supported, as two image sources next to `entitled`:

- **`private`**: a cloud or remote registry such as `private.de.icr.io/<namespace>`. The install workstation stays online. Pushing from outside IBM Cloud goes through the public endpoint (`de.icr.io`) while the cluster pulls from `private.`; `MIRROR_REGISTRY_PUSH_FROM=cloud` pushes straight to where the cluster pulls.
- **`local`**: a registry inside a disconnected network (device, bastion, on-prem host). `0.3_local_registry.sh up` can run one on this machine (`registry:2` under podman with its own CA, or Red Hat's mirror-registry on a RHEL x86 bastion). Content goes there either directly (one machine sees both sides) or through a **stop-over**: `--phase=save` writes a bundle on the internet side, the bundle is carried across, and `--phase=load` pushes it on the inside. The inside workstation is assumed to be Linux; macOS works too (`oc-mirror` then runs in a UBI container).

`auto` decides between the two from the registry host; `0.1_detect_registry.sh` shows why.

Every install gets its own path under the registry root (`<root>/cpd`, `<root>/confluent`, `<root>/datastax-mc`, `<root>/concert`), with images keeping their source layout below it. Operator catalogs and anything declared shared (`MIRROR_SHARED_DECLARE`, e.g. UBI base images) go to `<root>/shared`.

Config lives in `configs/registry_mirror_config/registry_mirror_vars.sh` (loaded only by this track, `ENV_TARGET=registry_mirror`). Create it, copying the selections and registry settings from the installs' own configs:

```bash
./scripts/private_registry_mirroring/0_initial_setup/0.0_generate_mirror_config.sh --prefill-from-installs
```

**Nothing is mirrored until** `MIRROR_INSTALLS` and each install's `MIRROR_<ID>_COMPONENTS` / `_CONTENT` are filled in. Re-running the generator keeps your values (a `.bak` is kept) and adds new settings; `--installs cpd,shared` limits the sections. The Red Hat pull secret goes in `configs/registry_mirror_config/redhat-pull-secret.json`. Then run the track:

```bash
# one machine reaches the internet and the registry
./scripts/private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh
# stop-over: internet side, then inside the disconnected network
./scripts/private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh --phase=save
./scripts/private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh --phase=load
```

`--dry-run` maps and shows the cluster changes without mirroring or changing anything; `--no-cluster` stops after segment 2; `--cluster-only` runs only segment 3. Skip steps with `DO_<STEP>=false` (listed at the top of the wrapper). Without `--phase`, the phase is `MIRROR_PHASE`, or detected from what is reachable.

| Step | What it does |
| --- | --- |
| `0_initial_setup/0.0` | Writes the config: the base template plus one section per install (`installs/<id>.sh.j2`). Prefilling asks each install's hook for its components, entitlement key and, where set, registry |
| `0.1` | Classifies the registry root (`local` / `private`), probes it with the push credentials, and with `--write` stores the result in the config |
| `0.2` | Checks the workstation tools and fetches `oc-mirror` (Linux-only: on macOS it runs in a container on the podman VM). `--for-inside` stages the inside workstation's tools (oc, oc-mirror, helm, cpd-cli, Python wheels) into the bundle |
| `0.3` | Local registry on this machine: `up`, `status`, `trust` (adds its CA to this machine), `down`, `export`/`import`, `rm --yes` |
| `1_map_content/1.0` | Builds the inventory from every selected install's `map` hook: per-path `targets.tsv` / `charts.tsv` / `files.tsv`, the operator `ImageSetConfiguration`, and `inventory/report.txt`. Stops on target collisions and reserved paths |
| `1.1` / `1.2` | Checks that every source is reachable with the credentials (sorting failures into auth / missing / TLS / network); estimates the size (`--with-operators`, `--with-cpd`) |
| `1.3` | Lists the images a running reference cluster actually uses, to compare with the inventory |
| `2_download_and_mirror/2.0` | Each product's own mirroring: `cpd-cli manage` (CASE download, `mirror-images` or save/load through IBM's stop-over registry, olm-utils into the registry) and Concert's `1.1` |
| `2.1` | All other images with `oc image mirror`, keeping manifest lists so digest references stay valid. `--path` mirrors one path only |
| `2.2` | Operator catalogs with `oc-mirror` v2 (channel heads) into `<root>/shared`, with the generated IDMS/ITMS/CatalogSources kept for segment 3 |
| `2.3` / `2.4` | Helm charts (OCI) and files; then checks that everything in the inventory is in the registry |
| `2.5` / `2.6` | Stop-over only: builds the transfer bundle (the saved content, mapping, tools, the repository and the config **with secrets blanked**; `--include-configs` adds `configs/`), and verifies and restores it on the inside (`--quick` skips the checksums) |
| `3_configure_cluster/3.0` | Read-only preflight: OpenShift ≥ 4.13, no ImageContentSourcePolicy left, managed platforms, existing mirror sets, CA and pull secret, the registry reachable from a node, and (local) Subscriptions whose package is not in the mirrored catalogs |
| `3.1` / `3.2` | Pull credentials in the global pull secret (`--with-icr` keeps cp.icr.io too); the registry CA in the cluster's `additionalTrustedCA` |
| `3.3` / `3.4` | One IDMS/ITMS for the track (`--prune` removes rules that dropped out), then the CatalogSources/ClusterCatalog. `3.2` - `3.4` wait for the MachineConfigPools to finish rolling |
| `3.5` | Points each install at the registry by writing `configs/<install>_config/registry_overrides.sh`, which is sourced right after that install's `*_vars.sh`. Your generated configs are never edited. `--dry-run` shows the files, `--only <id>` limits it |
| `3.6` | On a worker, pulls one image per path **by its source name**, which only works when the mirror set, pull secret and CA trust work together (`--all` for every image); then each install's `verify-cluster` check |

Choices worth knowing:

- **How each install is redirected** (`3.5`): CP4D gets `PRIVATE_REGISTRY_*`, `CPD_IMAGE_SOURCE` and an olm-utils image from the registry (`<root>/cpd/cpopen/cpd/olm-utils-v4:<version>.<patch>` when that tag is there, else `:<version>`; plus `.<arch>` only when an arch is specified in `MIRROR_CPD_ARCH` or in `OLM_UTILS_IMAGE`), and IBM's `cpd-cli` flow continues from there. DataStax MC gets `MC_IMAGE_SOURCE`, the chart from the registry and `mc-values-registry.yaml` (every chart image, including Mimir's MinIO). Confluent gets the chart refs and image registry; Flink the OCI chart refs (`FLINK_CHART_SOURCE=oci`). Concert gets its mirrored-mode settings, and its own `1.2`/`1.3` step aside because the shared path covers them.
- **The CP4D wrapper** runs segment 3 (`--cluster-only`) before the install when `CPD_IMAGE_SOURCE` is not `entitled` and the mirror config exists (`DO_REGISTRY_CLUSTER_CONFIG=auto`; `true`/`false` force it). Mirroring itself (segments 0 - 2) is not part of the install wrapper.
- **The CP4D notebook** has a third image source, *Local Private Registry (air-gapped)*, and warns when the registry host looks like the other kind.
- **Overrides on and off**: `PREG_SKIP_REGISTRY_OVERRIDES=1` loads the configs without `registry_overrides.sh`. `x_remove_mirror_config.sh` removes the track's cluster resources (`--include-ibm` also IBM's `cloud-pak-for-data-mirror`, `--overrides` the override files).
- **DataStax database servers**: `MIRROR_DATASTAX_MC_HCD_VERSIONS` lists the HCD versions to mirror. Left empty, mapping takes the newest `MIRROR_DATASTAX_MC_HCD_LATEST` (default 3) tagged in `cp.icr.io/cp/ibm-ds-mission-control/hcd`. DSE images are mirrored only for versions listed in `MIRROR_DATASTAX_MC_DSE_VERSIONS`.
- **CP4D images outside the CASE packages** (content `extra-images`), by component: Databand Postgres (`ibm-databand`); StreamSets engine + stage-libs images (`streamsets`, `ibm-streamsets-sdi`, or `watsonx_dataintegration` with `enableRealtimeStreaming: true` in the install options); extra HCD versions for watsonx.data (`watsonx_data_premium`, `datastax_mc` - the CASE ships one). Versions come from `MIRROR_CPD_STREAMSETS_VERSIONS` / `MIRROR_CPD_HCD_VERSIONS`, or else the newest `*_LATEST` (default 3) in the registry. The watsonx Orchestrate ADK proxy pulls at run time and is not covered.
- **OpenShift release images** are not mirrored; the cluster is assumed to exist.

`x_clean_or_debug_registry/` lists what is in the registry per path (`x_list_registry_content.sh`) and deletes content that dropped out of the inventory (`x_prune_registry_paths.sh`, `--all` deletes a whole path; asks first unless `--yes`).

**CP4D patch updates** (`4_update_cpd_patch/`): move `<root>/cpd` to another Software Hub patch of the same release (for example patch 7 → 8) and copy only what that patch changed. Images, CASE packages and olm-utils are handled; operators and extra images stay with segments 1 and 2. Set `PATCH_ID` in `cpd_vars.sh` (or pass `--to N`), then:

```bash
./scripts/private_registry_mirroring/4_update_cpd_patch/4.x_full_cpd_patch_update.sh              # plan, copy, verify, record
./scripts/private_registry_mirroring/4_update_cpd_patch/4.x_full_cpd_patch_update.sh --plan-only  # just show what would be copied
# stop-over: --phase=save outside (writes a patch bundle), --phase=load inside
```

| Step | What it does |
| --- | --- |
| `4.0` | `case-download` for the target patch, then `mirror-images` writing only the mapping files. Each mapping line not already recorded for the current patch is probed in the registry by digest (16 at a time), so no `list-images`. Writes `cpd/patches/<release>-p<to>/report.txt`: which components changed, and what is new or a moved tag. `--estimate` adds the delta size. With `--phase=save` the delta is computed against the last save, or once against the mapping generated from the old patch's CASEs |
| `4.1` | Copies only the delta, running `oc image mirror` on several CASEs in parallel (manifest lists are kept, so digests don't change): to the registry, into a patch bundle (`save`, which also holds the new CASE versions and the patch metadata), or from the bundle (`load`, which also restores the CASEs into cpd-cli's work dir) |
| `4.2` | Verifies the delta by digest (`--full`: every image of the patch), adds the version tags, records the patch (`patches/current`, `history.log`), and moves `native.jsonl`/`inventory.json` to it. It then runs `3.5 --only cpd`, which recreates cpd-cli's container (`--no-tap` skips this) |
| `4.3` | Lists the recorded and planned patches and the history |

**Version tags** keep every patch you have mirrored complete in the registry:

- **Moved tags** are tags that a patch points at a new digest. The old digest is kept as `<tag>-p<old>` and the new one as `<tag>-p<new>`.
- **olm-utils** gets IBM's `<release>.<patch>[.<arch>]` tags. When the registry has the tag for `PATCH_ID`, `3.5` pins `OLM_UTILS_IMAGE` to it, so a `PATCH_ID` the registry was never updated to fails to pull instead of quietly running the previous patch's olm-utils. `2.0` adds that tag too.
- **Other images** already have versioned tags and digests, so both patches stay installable. Nothing is pruned.

**Adding a product**: copy the `_template` files (`0_initial_setup/installs/_template.{conf,sh.j2,sh}`, and `_template.sh` in segments 1 - 3) to `<id>.*`. The `.conf` holds its metadata (config target, default registry path, content kinds). The hooks are called with a verb: `components`/`prefill` (0), `map` (1, required; emits inventory lines), `download`/`verify-registry` (2, only for product-specific mirroring) and `cluster`/`tap`/`verify-cluster` (3). The numbered scripts loop over `MIRROR_INSTALLS` and need no change.
