# Installing on three clusters in one run

In this example, the guide installs IBM Software Hub / Cloud Pak for Data on three clusters
with one command. Two clusters (cluster-a, cluster-b) run their install in the cluster with
entitled images. The third (cluster-c) runs its install on this machine.

## Before you start

- Multi-cluster management is on, or you turn it on in step 1. A cluster folder is one-way.
- A cluster-admin login for each cluster, and `oc`, `cpd-cli`, `podman` and zsh on this
  machine (see [Prerequisites](../../README.md#prerequisites)).
- The three clusters are really three clusters. Two names with the same `OCP_URL`
  count as one cluster, and a run that would use both at the same time is refused.
- Nothing of the same type is running on any of them. One install of each type runs on a
  cluster at a time (today that means one CP4D install per cluster). There is no override.
- This machine stays on for the local install. It runs in the foreground for hours.

What can run where:

- **In the cluster** (`INSTALL_RUN_MODE=cluster`): only Cloud Pak for Data / Software Hub,
  only with `CPD_IMAGE_SOURCE=entitled`, and only the full install, `2.0`, `2.2`, `3.1`,
  `4.0` and the Control Center sub-install. Other chains stop with a message if set to
  `cluster`.
- **On this machine only**: every other product and every `x_*` utility. Confluent Platform
  (and its Flink add-on) is one of them. Its full install takes the same cluster flags and
  runs one cluster after the other here; `--parallel` is refused for it. Its images come
  from public registries (Docker Hub, no entitlement key), or from a private or air-gapped /
  local registry once the mirroring track has pointed it there (see [Confluent Platform](../../README.md#confluent-platform)).

## Steps

1. **Turn on multi-cluster management and add the clusters.**
   Why: each cluster gets its own configs, `oc` session and olm-utils container.

   ```bash
   cd src/utilities/multi_cluster_management_utils
   ./multi_cluster.sh on
   ./multi_cluster.sh add cluster-a --url <CLUSTER_A_API_URL> --use
   ./multi_cluster.sh add cluster-b --url <CLUSTER_B_API_URL>
   ./multi_cluster.sh add cluster-c --url <CLUSTER_C_API_URL>
   ./multi_cluster.sh status
   cd ../../..    # back to the repo root for the next steps
   ```

   `use` sets the current cluster; `targets a,b,c` saves a default target list, if wanted.

2. **Give each cluster its own config.**
   Why: in a multi-cluster run each cluster reads its own `cpd_vars.sh`; an
   `INSTALL_RUN_MODE` exported in the shell does not reach them.
   Run `marimo run softwarehub_cp4d_vars_generation.py` once per cluster with
   **Manage multiple clusters** ticked. The config lands in
   `configs/clusters/<name>/cp4d_config/`.
   (`add ... --copy-from CLUSTER` copies another cluster's configs; log in again and check them.)

3. **Set where each install runs.** Why: the run reads it from each cluster's own file.
   - cluster-a and cluster-b: set `INSTALL_RUN_MODE` to `cluster` and keep `CPD_IMAGE_SOURCE`
     at `entitled`.
   - cluster-c: set `INSTALL_RUN_MODE` to `local`.

   The value must be a plain `"local"` or `"cluster"`. A variable or a command there stops the
   whole run before anything starts.

4. **Only if cluster-c uses a private registry or is air-gapped: mirror first.**
   Why: in-cluster runs only support entitled images, so such a cluster must be the local one.
   Write the mirror config, fill in what to mirror (nothing is mirrored until you do),
   then mirror for that cluster:

   ```bash
   ./scripts/private_registry_mirroring/0_initial_setup/0.0_generate_mirror_config.sh --target-cluster cluster-c --prefill-from-installs
   ./scripts/private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh --target-cluster cluster-c
   ```

   - **Entitled (online)**: no mirroring. This is the only choice for cluster-a and cluster-b.
   - **Private registry** (`CPD_IMAGE_SOURCE=private`): the workstation stays online and
     mirrors straight into the registry.
   - **Air-gapped / local registry** (`CPD_IMAGE_SOURCE=local`): mirror directly if one machine sees
     both sides, or through a stop-over (`--phase=save` outside, carry the bundle,
     `--phase=load` inside). The machine that runs step 6 must still reach all three clusters.

   The CP4D install then sets the cluster up for the registry first (`DO_REGISTRY_CLUSTER_CONFIG=auto`).

5. **Check the in-cluster targets.** Why: catches a missing storage class or image setting
   before anything is launched.

   ```bash
   scripts/install_runner/x_install_runner.sh preflight --target-clusters cluster-a,cluster-b
   ```

6. **Start the run.** Why: one command plans all three clusters before any of them starts.

   ```bash
   scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh --all-clusters   # every registered cluster
   # or name them:
   scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh --target-clusters cluster-a,cluster-b,cluster-c
   ```

7. **Read the plan.** You see each target and where its install runs, then the plan. With
   only one local target (cluster-c), there are no questions. With more than one local target:
   - It asks which local targets run in the cluster instead, this run only (`none`: none).
   - Only one install runs on this machine per run. If several are still local, the current
     cluster runs here and the others are skipped; if the current cluster is not among them,
     it asks which one.
   - `--local-cluster NAME` picks the one that runs here up front, current cluster or not.
     Every other local target is then switched or skipped.
   - It shows the plan and asks for a last confirmation.

   `cancel` at any question ends the whole run, with nothing started (exit code `1`).

8. **Let it run.** Why: the pods do not need you; the local install does.
   - cluster-a and cluster-b launch first, one after the other, without being watched. The
     first launch on a cluster builds a runner image of about 2.5 GB.
   - Then cluster-c runs here in the foreground, for hours.
   - At the end a table of results prints (`ok`, `launched (slot ...)`, `ok (warnings)`,
     `skipped`, `FAILED`), then `x_install_runner.sh status --all-clusters`.
   - Success: exit code `0`, with every row `ok`, `launched` or `ok (warnings)`.

9. **Watch, collect and tear down each in-cluster run.**
   Why: results stay in the pod until you collect them, and the pod keeps your credentials
   until teardown.

   ```bash
   scripts/install_runner/x_install_runner.sh status --all-clusters
   scripts/install_runner/x_watch_install.sh --target-cluster cluster-a
   scripts/install_runner/x_install_runner.sh collect --all-clusters
   scripts/install_runner/x_install_runner.sh teardown --target-cluster cluster-a
   ```

   `status`, `preflight` and `collect` take `--all-clusters`. `stop` and `teardown` do too,
   after a typed confirmation (`--yes-all-clusters` with no terminal). `attach`,
   `x_watch_install.sh`, `resume` and `shell` take one cluster at a time. Collected results land in
   `configs/clusters/<name>/cp4d_config/` and `configs/clusters/<name>/service_instances/`.

## Without questions, or launch only

- **No terminal (CI, a notebook, a pipe):** with one local target, as here, nothing is
  asked. With more, answer in the command; a question left unanswered stops the run with
  nothing started.

  ```bash
  scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh --all-clusters --switch-to-cluster none --local-cluster cluster-c --yes
  ```

  `--switch-to-cluster a,b` switches those local targets for this run (`none` keeps them).
  `--local-cluster NAME` picks the one that runs here. `--yes` skips the last confirmation.
- **`--parallel`:** launches every in-cluster target and returns; nothing runs here. A local
  target must be switched (at the question or with `--switch-to-cluster`), or the whole run
  is refused with nothing launched. So cluster-c could only take part if it uses entitled
  images. `--local-cluster` cannot be used with it.

## If something goes wrong

- **Refused at the start:** a same-type install is already running on that cluster (the
  message names the slot), two names share one URL, or an `INSTALL_RUN_MODE` is not plain.
  Nothing was started.
- **Preflight error on `CPD_IMAGE_SOURCE`:** an in-cluster target is not `entitled`. Set it to
  `entitled`, or make that cluster the local one.
- **A step fails in a pod:** the run waits. Fix the cause, then
  `scripts/install_runner/x_install_runner.sh resume --target-cluster cluster-a`.
- **Ctrl-C during the local install:** it stops the local install (exit code `130`, no status
  at the end). The pods already launched keep going.
- **Removing a cluster later:** collect and tear down its slots first;
  `multi_cluster.sh remove` refuses while a launch record exists.

## See also

- [Managing several clusters](../../README.md#managing-several-clusters)
- [In-cluster runs with multi-cluster management](../../README.md#in-cluster-runs-with-multi-cluster-management)
- [Installs on this machine in a multi-cluster run](../../README.md#installs-on-this-machine-in-a-multi-cluster-run)
- [One install of each type per cluster](../../README.md#one-install-of-each-type-per-cluster)
- [Private registry mirroring](../../README.md#private-registry-mirroring) and [Installation mode variants and image registry options](../../README.md#installation-mode-variants-and-image-registry-options)
- [Local install guide](local-install.md) and [In-cluster install guide](in-cluster-install.md)
