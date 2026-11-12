# Installing from this machine

This guide covers a regular install that runs from your workstation, on one cluster.
It is the default mode (`INSTALL_RUN_MODE=local`). In this example the steps focus on IBM
Software Hub / Cloud Pak for Data (CP4D); the other products follow the same pattern
(see [Other products](#other-products)).

## Before you start

- An OpenShift cluster, and a cluster-admin login for it.
- `zsh`, `podman`, Python 3.14+ and [uv](https://docs.astral.sh/uv/) on this machine. Run `uv sync` once.
- `oc` and `cpd-cli`. On macOS the repo installs both for you (step 2); on any other OS, install them yourself.
- An IBM entitlement key.
- Where the cluster gets its images from: IBM directly (entitled), a private registry, or a
  local registry in a disconnected network. See [Image sources](#image-sources).
- Time. A full CP4D install runs in the foreground for hours. Keep the terminal open and the
  machine awake: closing the terminal or pressing Ctrl-C stops the chain. Only an in-cluster run
  (CP4D with entitled images only) survives that (see the [in-cluster guide](in-cluster-install.md)).
- Multi-cluster management off, or one cluster only. For several clusters, see the
  [multi-cluster guide](multi-cluster-install.md).

## Steps

1. **Check the shell.**
   Why: every script is a zsh script, and this check runs before zsh exists. Run
   `sh scripts/0_initial_check_in.sh`. If zsh is missing or not at `/bin/zsh`, it offers to install or link it.

2. **Install the CLIs (macOS only, once per workstation).**
   Why: the install drives the cluster with `oc` and `cpd-cli`. These two scripts download and
   install them for you, on macOS only. On Linux, Windows or any other OS, get the builds for your
   platform and install them yourself, then skip this step.

   ```bash
   ./scripts/install_cloud_pak_for_data/0_initial_setup/0.1_install_oc-MAC-ONLY.sh
   ./scripts/install_cloud_pak_for_data/0_initial_setup/0.2_install_cpd_cli-MAC-ONLY.sh
   ```

3. **Generate the config.**
   Why: every script loads its settings from the config files under `configs/`.

   ```bash
   marimo run softwarehub_cp4d_vars_generation.py
   ```

   In the browser, fill in the cluster login, entitlement key, storage classes and projects,
   pick the components and the image source, review the two files, then click
   **Save to the folder shown above**. This writes `cpd_vars.sh` and `install-options.yml` into
   `configs/cp4d_config/`. Leave `INSTALL_RUN_MODE` at `local`.

4. **Check the cluster (optional).**
   Why: it finds readiness problems before an hours-long run. Run
   `./scripts/install_cloud_pak_for_data/3_install_softwarehub/3.0_cluster_health_check.sh`.

5. **Run the install.** Pick one of the two ways.
   Why: the full chain does everything in order; the numbered steps let you go one stage at a time.

   ```bash
   # Everything at once
   ./scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh

   # Or step by step (1.0 is only needed once per cluster)
   ./scripts/install_cloud_pak_for_data/1_global_pull_secret_and_certmanager/1.0_set_up_openshift_certmanager.sh
   ./scripts/install_cloud_pak_for_data/1_global_pull_secret_and_certmanager/1.1_set_up_global_pull_credential.sh
   ./scripts/install_cloud_pak_for_data/2_prepare_cluster/2.0-2.1_preliminary_setup/2.0_preliminary_setup.sh
   ./scripts/install_cloud_pak_for_data/2_prepare_cluster/2.2_install_prerequisite_operators/2.2_install_prerequisite_operators.sh
   ./scripts/install_cloud_pak_for_data/3_install_softwarehub/3.1_full_step_3_installprocess-softwarehub.sh
   ./scripts/install_cloud_pak_for_data/4_install_components/4.0_full_step_4_installprocess-cpd.sh
   ```

   The full chain's steps are `registry-config`, `certmanager`, `pull-secret`, `preliminary`,
   `prereq-operators`, `softwarehub` and `cpd`. To add Software Hub Control Center at the end, set
   `INSTALL_SWHUB_CONTROL_CENTER` to `true` in `cpd_vars.sh`
   ([details](../../README.md#optional-software-hub-control-center)).

6. **Use the results.** Why: the install writes what you need next to your config.
   - The Software Hub URL, admin login and API key are in `configs/cp4d_config/cpd_instance_details.sh` (step 3.3.1).
   - The `cpd-cli` profile is set up for this cluster (step 4.2). `x_repair_cpd_cli_profile.sh` in
     `4.5_service_instance_setups/` checks or repairs it later.
   - Nothing needs collecting: the files are already here (`x_install_runner.sh collect` is only for in-cluster runs).

### What you will see

- Each step starts with a `==> Running:` line and is timed. The chain stops on the first
  failed step, and the `[ERROR]` line names the `--from <step>` that resumes it.
- To watch the component CRs from a second terminal (read-only), run
  `./scripts/install_cloud_pak_for_data/check_cr_status/x_cr_state_dashboard.sh`.
- At the end the chain prints a `[TIMER] ... completed in ...` line, whatever the result.
  Success is a zero exit code. The optional Control Center step only warns if it fails.
- A full install takes from about an hour to many hours, depending on the components.
- One install of each type runs on a cluster at a time. A local CP4D run is refused while a
  CP4D install you launched into the same cluster from this machine still runs. There is no override.

## Resuming and skipping

The full chain and its sub-chains take `--list-steps`, `--from` and `--skip`. `--help` lists the step names.

```bash
CHAIN=./scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh
$CHAIN --list-steps                  # show what a run would do
$CHAIN --from prereq-operators       # resume at a step after a failure
$CHAIN --skip certmanager,pull-secret
```

Steps 3 and 4 are wrappers. Their sub-steps (3.2 admin, 3.3 Software Hub, 3.4 entitlements,
4.1 components, 4.2 `cpd-cli` profile and so on) sit next to them and can be run on their own.

## Image sources

The image source you pick in the notebook sets `CPD_IMAGE_SOURCE`: `entitled` (the default),
`private` or `local`. The install chain never mirrors anything: for private and local, mirror first,
then install. See [scripts/README.md](../../scripts/README.md) for the full routes.

- **Entitled (online).** The cluster pulls from IBM's registry. Nothing to do before step 5.
- **Private registry (online).** Mirror first, from a machine that reaches the internet and the registry.
  Nothing is mirrored until the mirror config's selections are filled in; the prefill copies them
  from your install configs, so review the file before you run the track:

  ```bash
  ./scripts/private_registry_mirroring/0_initial_setup/0.0_generate_mirror_config.sh --prefill-from-installs
  ./scripts/private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh
  ```

  Then run step 5. Its `registry-config` step runs the track's cluster step again (pull secret,
  CA trust, mirror sets), which is safe.
- **Air-gapped / local registry.** Use a registry inside the network, or start one with
  `./scripts/private_registry_mirroring/0_initial_setup/0.3_local_registry.sh up`. If one machine sees
  both sides, mirror as above. Otherwise carry a bundle across: `--phase=save` on the internet side,
  `--phase=load` inside, then run step 5 on the inside workstation. The stop-over needs a few extra
  mirror settings first (section C2 of [scripts/README.md](../../scripts/README.md)).
- **Patch updates (private and local).** To move the registry to another Software Hub patch of the
  same release, set `PATCH_ID` in `cpd_vars.sh` and run
  `./scripts/private_registry_mirroring/4_update_cpd_patch/4.x_full_cpd_patch_update.sh`
  (`--plan-only` to preview). It copies only what the patch changed. Its resume flag is
  `--from-step`, since its `--from` is a patch number.

## Other products

These run from this machine only (no in-cluster mode). Each follows the same pattern: generate its
config, then run its full install script, which takes the same `--from` / `--skip` / `--list-steps`.

| Product | Config | Full install |
| --- | --- | --- |
| Confluent Platform (+ Flink) | `marimo run confluent_platform_vars_generation.py`, or `scripts/install_confluent_platform/0_confluent_prepare_template_config.sh --size small` | `scripts/install_confluent_platform/full_installprocess-confluent_platform.sh` |
| DataStax Mission Control | `scripts/install_datastax_mc_standalone/0_initial_setup/0.0_generate_datastax_mc_config.sh --empty` (or `--from-cpd`) | `scripts/install_datastax_mc_standalone/0_x_full_quick_install_script/full_datastax_mc_installprocess.sh` |
| IBM Concert | `marimo run ibm_concert_vars_generation.py` | `scripts/install_ibm_concert/0_x_full_quick_install_script/full_concert_installprocess.sh` |

**What Confluent Platform supports today:**

- OpenShift, installed from this machine. There is no in-cluster mode for it.
- A KRaft Kafka cluster (always installed), plus optional Schema Registry, Kafka Connect, ksqlDB,
  REST Proxy and Control Center.
- T-shirt sizes `xsmall`, `small`, `medium` and `large`. Every size except `xsmall` survives the loss of one broker.
- SASL client auth, MDS / RBAC, and external Kafka access over passthrough Routes.
- The Flink add-on, which runs after the platform when its settings are in the config.
- An optional Iceberg ingestion setup into a watsonx.data catalog.
- Online, from public registries (Docker Hub images, no entitlement key). Private and air-gapped / local registries through the mirroring track.

DataStax Mission Control and Concert also take private and local registries through the same
mirroring track. Concert Optimize (Turbonomic) has no mirrored mode yet. Concert is started
from this machine, but IBM's installer itself runs as a Job in the cluster by default.

## If something goes wrong

- **A step failed.** Fix the cause, then rerun the chain with the `--from <step>` the error names.
- **The terminal closed mid-run.** The chain stopped. Run it again with `--from` at the step it was on.
- **Refused because another install runs.** Wait for it, or watch it with the command the message names.
- **Known cluster faults and teardown.** See `scripts/install_cloud_pak_for_data/x_clean_or_debug_cp4d/`.
  Its fix scripts detect the fault first and take `--preview=true` to only report.

## See also

- [Generate your config](../../README.md#1-generate-your-config) and [Run the install](../../README.md#2-run-the-install) in the README
- [Useful extras](../../README.md#useful-extras): service instances, component follow-ups, `cpd-cli` upkeep
- [Private registry mirroring](../../README.md#private-registry-mirroring) and [scripts/README.md](../../scripts/README.md)
- [Confluent Platform](../../README.md#confluent-platform), [IBM Concert](../../README.md#ibm-concert), [DataStax Mission Control](../../README.md#datastax-mission-control-standalone)
- [In-cluster install guide](in-cluster-install.md) and [multi-cluster install guide](multi-cluster-install.md)
