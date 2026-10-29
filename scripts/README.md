# Running an install: entitled, private registry or air-gapped

Start here once the install's config exists (`configs/<product>_config/*_vars.sh`, from its notebook or `0_*` generator; see the [main README](../README.md)). Pick the route that matches where the cluster gets its images from.

| Route                            | The cluster pulls from                                                                                                                                           | Before the install                                        |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| **A. Entitled** (online)         | IBM, Red Hat and Docker Hub registries directly                                                                                                                  | nothing                                                   |
| **B. Private registry** (online) | a cloud or remote registry, e.g. `private.de.icr.io/<namespace>` or `de.icr.io/<namespace>` for container registry on IBM cloud or your own alternative registry | mirror the images into it                                 |
| **C. Local / air-gapped**        | a registry inside the disconnected network                                                                                                                       | mirror the images, carrying them across on disk if needed |

> The full install scripts never mirror anything. For B and C, finish the mirroring first, then run the install.

---

## A. Entitled (online)

Run the full install for your target products, like:

**IBM Software Hub (Cloud Pak For Data and its components)**
```bash
./scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh
```
Resume from a step with `--from <step>` (e.g. `--from softwarehub`); `--help` lists the steps.

**IBM Concert**
```bash
./scripts/install_ibm_concert/0_x_full_quick_install_script/full_concert_installprocess.sh
```

**DataStax HCD Standalone**
```bash
./scripts/install_datastax_mc_standalone/0_x_full_quick_install_script/full_datastax_mc_installprocess.sh
```

**Confluent Platform (+ Flink if configured)**
```bash
./scripts/install_confluent_platform/full_installprocess-confluent_platform.sh   # + Flink add-on when configured
```


---

## B and C: create the mirror config

1. Generate it from the install configs you already have:

   ```bash
   ./scripts/private_registry_mirroring/0_initial_setup/0.0_generate_mirror_config.sh --prefill-from-installs
   ```

2. Check and fill in `configs/registry_mirror_config/registry_mirror_vars.sh`:
   - `MIRROR_REGISTRY_ROOT` and the push/pull credentials (ICR: user `iamapikey`, password = API key). For C1 with a registry started by `0.3_local_registry.sh` (below), leave these empty.
   - `MIRROR_IBM_ENTITLEMENT_KEY`.
   - `MIRROR_INSTALLS`, and per install `MIRROR_<ID>_COMPONENTS` / `MIRROR_<ID>_CONTENT`. **Empty means nothing is mirrored.**
3. Save your Red Hat pull secret as `configs/registry_mirror_config/redhat-pull-secret.json`. `0_initial_setup/0.4_fetch_redhat_pull_secret.sh` copies it from the cluster in your install configs (cpd first). The full process runs it on its own when the file is missing. Alternatively, download it from console.redhat.com.
4. Optional: `private_registry_mirroring/0_initial_setup/0.1_detect_registry.sh` checks the registry and the credentials; `full_registry_mirror_process.sh --dry-run` shows what goes where without mirroring anything.

Keep `IBM_ENTITLEMENT_KEY` in the install configs too: the images are still pulled from IBM first.

---

## B. Private registry (online)

From a machine that reaches both the internet and the registry:

```bash
./scripts/private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh
```

This mirrors everything, checks that it all reached the registry, and then configures the cluster: pull secret, CA, mirror sets and operator catalogs. It also writes `configs/<product>_config/registry_overrides.sh`, which points each install at the registry. Then run the full install scripts from **A**.

Run the mirror script again whenever you change components or versions.

---

## C. Local / air-gapped

**Registry.** Use an existing registry inside the network, or start one on this machine:

```bash
./scripts/private_registry_mirroring/0_initial_setup/0.3_local_registry.sh up
```

Set `LOCAL_REGISTRY_HOST` first, to a host name the cluster nodes can resolve. This machine must then stay up for as long as the cluster runs. For C2, start it on the inside, after unpacking the bundle (step 3).

### C1. One machine can reach both sides

If the same machine reaches the internet and the registry (e.g. a bastion), run it as in **B**. If the registry is on a laptop that only joins the cluster network later:

```bash
# while online
./scripts/private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh --no-cluster
# once inside the cluster network
./scripts/private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh --cluster-only
```

### C2. Stop-over: carry a bundle across

In the mirror config on the internet side, set:

- `MIRROR_TRANSPORT="stopover"` and `MIRROR_IMAGE_SOURCE="local"`;
- `MIRROR_REGISTRY_ROOT` to the inside registry's address, as the cluster nodes will reach it. The target paths are worked out on this side.
- `MIRROR_OCP_MINOR`: the cluster's OpenShift version, e.g. `4.20`.
- Optionally `MIRROR_BUNDLE_DIR` (e.g. a USB disk); the default is `registry_mirror_workspace/bundle`.

**1. Internet side: save the bundle.**

```bash
./scripts/private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh --phase=save
```

The bundle holds the images, catalogs, charts and files, plus the tools for the inside workstation and a copy of this repository. It also holds the mirror config, with its passwords and keys blanked. Your install configs are **not** included.

**2. Carry it across.** Copy the bundle folder over (USB, scp), together with your `configs/<product>_config/` folders.

**3. Inside: load it**, on a workstation that reaches the registry and the cluster:

```bash
mkdir ibm-software-installation-scripts
tar -xzf /path/to/bundle/repo/repo.tar.gz -C ibm-software-installation-scripts
cd ibm-software-installation-scripts
```

- Copy `/path/to/bundle/config/registry_mirror_vars.sh` to `configs/registry_mirror_config/` and fill in the blanked credentials.
- Put the install configs into `configs/`. The cluster step logs in with them and writes `registry_overrides.sh` next to them.

```bash
export MIRROR_BUNDLE_DIR=/path/to/bundle
./scripts/private_registry_mirroring/2_download_and_mirror/2.6_restore_transfer_bundle.sh
export PATH="$PWD/registry_mirror_workspace/tools/bin:$HOME/cpd-cli:$PATH"   # the restored tools
DO_RESTORE=false ./scripts/private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh --phase=load
```

This pushes everything into the registry, checks it, and configures the cluster. Then, on the same workstation, run the full install scripts from **A**.

---

## Notes

- **CP4D**: its full install script runs the cluster step again (`--cluster-only`) whenever the image source is not `entitled`. Re-running it is safe.
- **Concert**: with this track, Concert's own `1.1` - `1.3` mirroring steps are skipped (`CONCERT_MIRROR_VIA_SHARED=true`). Concert Optimize (Turbonomic) has no mirrored mode yet.
- **Going back to entitled**: delete `configs/<product>_config/registry_overrides.sh`. To also remove the cluster resources, use `private_registry_mirroring/x_clean_or_debug_registry/x_remove_mirror_config.sh`.

More detail on every step: [Private registry mirroring](../README.md#private-registry-mirroring) in the main README.
