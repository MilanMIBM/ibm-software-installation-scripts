# In-cluster install (one cluster)

An in-cluster run moves the install chain from your machine into a pod on the
cluster. Your terminal shows the pod's output as if it ran here, but you can
close it, or turn the machine off, and the install keeps going. This example uses IBM
Software Hub / Cloud Pak for Data, the install that has an in-cluster mode today.

## What runs in the cluster today

- **Cloud Pak for Data / Software Hub only**, and only with
  `CPD_IMAGE_SOURCE=entitled` (images pulled from IBM's entitled registry).
- **Only these chains**: the full install (`full_swhub_x_cpd_installprocess.sh`),
  `2.0`, `2.2`, `3.1`, `4.0` and the Control Center sub-install.
- **Private registry and air-gapped / local registry installs** of CP4D do not
  run in the cluster. The preflight stops them with nothing changed. Run them
  from this machine (see the [local guide](local-install.md)). The mirroring
  scripts in `scripts/private_registry_mirroring/` also run from this machine,
  before that local install.
- **Every other product runs from this machine**: Confluent Platform and its
  Flink add-on, DataStax Mission Control, IBM Concert, Kubecost, and every
  `x_*` utility. Their configs don't set `INSTALL_RUN_MODE`, so they run here
  (local) even when the cluster's CP4D runs in the cluster.
- **A chain with no install module that still gets `cluster`** (`--run-mode
  cluster`, or a CP4D chain other than the full chain, 2.0, 2.2, 3.1 and 4.0)
  asks whether to run on this machine instead, for this run only. The config is
  not changed. `--local-install-fallback` answers yes. With no terminal and no
  flag it stops before any work. On several clusters it asks once, then runs
  them one at a time (`--parallel` is ignored).
- **Confluent Platform today**: a local run only, with no in-cluster mode. Online
  from public registries (Docker Hub, no entitlement key), or from a private or
  air-gapped / local registry the mirroring track has filled ([details](local-install.md#other-products)).
- **One install of each type per cluster.** A second CP4D launch on the same
  cluster stops while the first one runs. There is no override. Different
  install types on one cluster are allowed.

## Before you start

- A generated CP4D config (`configs/cp4d_config/cpd_vars.sh` and
  `install-options.yml`), made with the notebook as in the
  [README](../../README.md#1-generate-your-config).
- A **cluster-admin** login in that config. The pod gets cluster-admin for the
  run and removes it when the run ends.
- A storage class for the runner's volume (`STG_CLASS_BLOCK` by default, or
  set `INSTALL_RUNNER_STORAGE_CLASS`).
- The cluster's internal image registry in `Managed` state. Without it, set
  `INSTALL_RUNNER_IMAGE_SOURCE` to `build-local-push` (build here with podman
  and push to `PRIVATE_REGISTRY_LOCATION`) or `prebuilt` (with
  `INSTALL_RUNNER_IMAGE`).
- An IBM entitlement key with access to the entitled images.

## Steps

**1. Check the cluster.** Why: a weak cluster fails hours into the install.

```bash
./scripts/install_cloud_pak_for_data/3_install_softwarehub/3.0_cluster_health_check.sh
```

**2. Choose the run mode.** Why: the chain only moves to a pod when told to.
Either pick "Where do the install chains run?" in the notebook's *In-cluster
runs* section, or set `INSTALL_RUN_MODE` to `cluster` in `cpd_vars.sh`. For one
run only, add `--run-mode cluster` to the chain instead; it beats the config.

**3. Run the preflight (optional).** Why: it checks storage, registry, image
source and the same-type lock without changing anything.

```bash
./scripts/install_runner/x_install_runner.sh preflight
```

**4. Start the chain.** Why: this launches the run in its own slot.

```bash
./scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh --run-mode cluster
```

What you see:

- `Preflight passed.`, then the runner image. The first run builds it (about
  2.5 GB), so allow extra time. Later runs reuse it (`Runner image is up to date`).
- The slot: a namespace `install-runner-cpd-<instance>` with a pod, a volume and
  a copy of your config. `Staging run ...` counts the files sent.
- `Run <run> is in slot <slot>. You can close this terminal`, then the live
  install output. A full install takes hours.
- **Ctrl-C only stops watching.** The install keeps going in the pod.

Add `--parallel` to launch and return without watching.

**5. Watch again or check status.** Why: you can reconnect at any time.

```bash
./scripts/install_runner/x_watch_install.sh                # the live terminal
./scripts/install_runner/x_watch_install.sh --from-start   # the whole run so far
./scripts/install_runner/x_install_runner.sh status        # every install on the cluster
```

**6. Resume after a failed step.** Why: a failed run stops and waits for you.
Fix the cause, then:

```bash
./scripts/install_runner/x_install_runner.sh resume
./scripts/install_runner/x_install_runner.sh resume --retry-warned   # also repeat warned steps
```

Finished steps are skipped. If the pod is lost (a node drain, for example), a
new pod continues by itself.

**7. Collect the results.** Why: the files the run wrote, such as the instance
details, stay in the pod until you bring them back.

```bash
./scripts/install_runner/x_install_runner.sh collect
```

Success looks like `Run finished: completed` at the end of the watch, with the
collect command to run next. Collect brings back only the files the run
changed. They go back to
`configs/cp4d_config/` and `service_instances/`, and your local `cpd-cli`
profile is rebuilt. A file you changed here during the run stays; the pod's
copy lands next to it as `<file>.in-cluster-<run>`.

**8. Tear down.** Why: the slot holds a copy of your config, credentials
included, until you delete it.

```bash
./scripts/install_runner/x_install_runner.sh teardown
```

Exit codes of a chain run in the cluster:

| Code | Meaning |
| --- | --- |
| `0` | The install finished |
| `76` | Launched with `--parallel`, or detached: still running, unwatched |
| `77` | Finished with warnings |
| `78` | Watch lost (no answer, or login expired); the install may still be going |

## If something goes wrong

- **"has no install module"**: that chain or product can't run in the cluster.
  Answer `y`, or add `--local-install-fallback` (or `--run-mode local`) to run it
  on this machine. The config stays as it is.
- **"supports entitled only for now"**: a private or local registry config.
  Run the install from this machine.
- **The internal registry is not Managed**: set `INSTALL_RUNNER_IMAGE_SOURCE`.
- **A same-type install is running**: the message names its slot and the
  watch command. Wait for it to end, collect it, then launch again.
- **"has a failed run"** on a new launch: `resume` it, or set
  `INSTALL_RUNNER_NEW_RUN=true` in the shell to start over.
- **Teardown refuses**: stop the live run first (`x_install_runner.sh stop`),
  or collect it. `teardown --discard` drops uncollected results.
- **Watch stopped with `78`**: run `status`, then `x_watch_install.sh` again.

## See also

- [Running an install in the cluster](../../README.md#running-an-install-in-the-cluster) (all runner settings)
- [One install of each type per cluster](../../README.md#one-install-of-each-type-per-cluster)
- [Control Center in the pod](../../README.md#control-center-in-the-pod)
- [Private registry mirroring](../../README.md#private-registry-mirroring)
- [Local install guide](local-install.md)
- [Multi-cluster install guide](multi-cluster-install.md)
