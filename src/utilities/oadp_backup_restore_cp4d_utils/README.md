# OADP backup and restore for Software Hub / CP4D

Back up a whole Software Hub instance to an S3 bucket outside the cluster with `cpd-cli oadp tenant-backup`, and restore it with `cpd-cli oadp tenant-restore` onto another cluster (or the same one). Every script takes `--help`.

| Script | Run against | What it does |
| --- | --- | --- |
| `1.1_generate_backup_bucket_config.sh` | - | Writes `backup_bucket_configs/<name>_bucket.sh`: S3 URL, bucket, prefix, region, path style, keys |
| `1.2_generate_restore_target_config.sh` | - | Writes `restore_target_configs/<name>_vars.sh`: target cluster login + project names, in `cpd_vars.sh` format |
| `2_install_oadp_br_utilities.sh` | source, then target | OADP operator (OLM), credentials secret, DPA, cpdbr-tenant, br_orchestration (cpd-cli) |
| `3_backup_cp4d_instance.sh` | source | `tenant-backup create` (offline by default) |
| `4_restore_cp4d_instance.sh` | target | `tenant-restore create --from-tenant-backup` |
| `4.1_restore_cp4d_instance_fresh_cluster.sh` | fresh target | The repo's cluster setup steps, then 2 (`--rbac-only`), 4, and 2 (`--full`) plus post-restore fixes, in one run |

If you run a generator with no options, it writes a template straight away, named `bucket-<id>` or `target-<id>`. The connection values are left empty, and each field has a comment explaining what goes there. Fill in the file by hand. The script lists the values that are still empty, and the install, backup and restore scripts refuse a config that hasn't been filled in. Options fill in whatever they name. Pass `--interactive` to be asked for the rest instead.

Both config folders are gitignored and owner-only, because they hold credentials. Their file names don't match the `configs/*/*_vars.sh` glob, so `source_env_setup.sh` never loads them automatically. They're only used when a script is given `--bucket` or `--target`.

## Flow: back up cluster A, restore on cluster B

```bash
cd src/utilities/oadp_backup_restore_cp4d_utils

# 1. Configs (the bucket must already exist)
./1.1_generate_backup_bucket_config.sh --name cos-backups
./1.2_generate_restore_target_config.sh --name cluster-b

# 2. Source cluster (normal env from configs/cp4d_config/cpd_vars.sh)
./2_install_oadp_br_utilities.sh --bucket cos-backups
./3_backup_cp4d_instance.sh --bucket cos-backups          # prints the backup name

# 3. Target cluster: OADP pointed at the SAME bucket, then restore
./2_install_oadp_br_utilities.sh --bucket cos-backups --target cluster-b
./4_restore_cp4d_instance.sh --target cluster-b --list
./4_restore_cp4d_instance.sh --target cluster-b --backup <backup name>

# 4. Once restored, finish cpdbr-tenant/br_orchestration so cluster B can take backups itself
./2_install_oadp_br_utilities.sh --bucket cos-backups --target cluster-b --full
```

`--bucket` can be left out when only one bucket config exists.

## Flow: restore onto a fresh cluster

On a brand-new cluster, `4.1_restore_cp4d_instance_fresh_cluster.sh` replaces step 3 above. It first runs the `install_cloud_pak_for_data` steps that a tenant restore needs but doesn't bring back itself, all against the target config. Then it sets up OADP, restores, and completes the OADP setup:

```bash
./4.1_restore_cp4d_instance_fresh_cluster.sh --target cluster-b --prepare-only   # cluster setup + OADP
./4.1_restore_cp4d_instance_fresh_cluster.sh --target cluster-b --list
./4.1_restore_cp4d_instance_fresh_cluster.sh --target cluster-b --backup <backup name> --from restore
# or all of it in one go:
./4.1_restore_cp4d_instance_fresh_cluster.sh --target cluster-b --backup <backup name>
```

| Step | Runs | Note |
| --- | --- | --- |
| `certmanager` | 1.0 | Red Hat cert-manager |
| `pull-secret` | 1.1 | Global pull secret |
| `projects` | 2.0.1 with `SETUP_INSTANCE_PROJECTS=false` | Shared projects only. The restore creates the instance projects, and refuses to run if they already exist |
| `cluster-resources` | 2.0.2 | CASE download, then `cluster_scoped_resources.yaml` for `COMPLETE_COMPONENT_LIST` |
| `cluster-components` | 2.1 with `AUTHORIZE_INSTANCE_TOPOLOGY=false` | License Service and scheduler. The instance-topology RBAC is in the backup |
| `prereq-operators` | 2.2 with `MCG_SETUP_INSTANCE_SECRETS=false` | Same operators as a normal install. MCG secrets are created after the restore |
| `oadp` | `2_install_oadp_br_utilities.sh --rbac-only` | |
| `restore` | `4_restore_cp4d_instance.sh` | |
| `oadp-full` | `2_install_oadp_br_utilities.sh --full` | So the restored instance can be backed up from this cluster |
| `pull-secret-relink` | 1.1 again | Copies this cluster's pull secret into the restored projects |
| `mcg-secrets` | 2.2.4 | The restored NooBaa secrets still have the source cluster's credentials. Only for MCG-dependent services |
| `admission-controller` | 3.3.2 | The webhook configuration is cluster-scoped |

- **Checks before it changes anything.** The script stops if the instance projects already exist, or if `STG_CLASS_BLOCK`/`STG_CLASS_FILE` are missing on the target. It warns if Software Hub already runs elsewhere on the cluster. It shows the step plan and asks before starting (`--yes` skips the question).
- **Resuming after a failure.** If a step up to and including `restore` fails, the script stops. Fix the cause and re-run with `--from <step>`. After a failed restore, also add `--force`, because the instance projects may exist by then. If a step after the restore fails, it's reported and the remaining steps still run. Use `--skip a,b` to leave steps out.
- **Separate oc session.** oc uses `restore_target_configs/<name>.kubeconfig`, a copy of your current kubeconfig made on first use. That way your usual oc context, for example a backup running against the source cluster, isn't switched to the target. `--shared-kubeconfig` turns this off. The cpd-cli olm-utils container has only one login, and the setup steps move it to the target.
- **Not covered.** Node settings (CRI-O, kernel parameters, db2u kubelet), image mirrors for a private registry, and any storage class the backed-up PVCs use besides `STG_CLASS_BLOCK`/`STG_CLASS_FILE`.
- **Target config.** It needs the settings `1.2_generate_restore_target_config.sh` copies from the source config, such as `VERSION`, `SOFTWARE_HUB`, `COMPLETE_COMPONENT_LIST`, `IMAGE_PULL_*` and the entitlement key. So don't generate it with `--no-copy-source`.

## Offline, online and downtime

| | Offline (default) | Online | Online + data mover |
| --- | --- | --- | --- |
| Instance scaled down | Yes, for the whole backup | No | No |
| Storage it works on | Any storage | Every instance volume must be on a CSI driver with a VolumeSnapshotClass | Same as online |
| Where volume data ends up | Bucket (copied file by file with kopia) | CSI snapshots on the source cluster | Bucket (snapshot contents uploaded with kopia) |
| Restore on another cluster | Yes. IBM documents this for the OADP utility | No | Not documented by IBM for the OADP utility. Test it with a real restore before relying on it |

- **Offline backups put the instance back afterwards.** `tenant-backup` scales the instance back up at the end, and its rollback does the same when a backup fails. After every backup, the script also checks every Deployment, StatefulSet and EDB cluster in the instance projects. Each one must be back to the replica count recorded just before the backup, and ready. If the backup was cut off partway, for example the laptop slept or the network dropped, `./3_backup_cp4d_instance.sh --recover` runs the backup post-hooks and checks again. Add `--scale-always` to force a scale-up. If the post-hooks don't bring everything back, it prints the `oc scale` and un-hibernate commands to do it by hand.
- **Online backups depend on storage support.** `./3_backup_cp4d_instance.sh --mode online` first lists the CSI driver behind every instance volume, and whether Velero has a snapshot class for it. It refuses to start if any volume can't be snapshotted, for example NFS, or a CSI driver with no VolumeSnapshotClass. The reason: copying a running database file by file doesn't give a consistent backup, so offline is the only complete option on that storage.
- **Getting online volume data into the bucket.** Run `./2_install_oadp_br_utilities.sh --snapshot-move-data`, or set `OADP_SNAPSHOT_MOVE_DATA=true` in the config. It turns on Velero's data mover (`defaultSnapshotMoveData` on the DPA), and labels one VolumeSnapshotClass per CSI driver the instance uses with `velero.io/csi-volumesnapshot-class=true`. It also prints which volumes can be snapshotted at all. The backup script then checks the DataUploads, and the restore script reports the DataDownloads. Offline backups take no snapshots, so this setting doesn't affect them.
- **IBM's supported no-downtime options.** For an online backup that can be restored on a different cluster, IBM documents IBM Fusion, NetApp Trident protect and Portworx.

## Things to know

- **What the install script does on each cluster.** If the cluster already has Software Hub (an `ibmcpd-cr` in the operands project), the script installs cpdbr-tenant fully, upgrading it if it's already there, and installs br_orchestration. On an empty restore target it installs only the cpdbr-tenant cluster roles (`--rbac-only`). Pass `--full` or `--rbac-only` to choose the mode yourself.
- **Prepare the target cluster first.** A tenant restore recreates the instance's namespaces, but not cluster-wide prerequisites like the global pull secret, cert-manager, License Service, the scheduler, storage classes with the same names, or node settings. The target config uses the `cpd_vars.sh` format, so the repo's step 1/2 scripts can set those up:
  `ENV_TARGET=$PWD/restore_target_configs/cluster-b_vars.sh ../../../scripts/install_cloud_pak_for_data/1_global_pull_secret_and_certmanager/1.1_set_up_global_pull_credential.sh`
  On a fresh cluster, `4.1_restore_cp4d_instance_fresh_cluster.sh` runs these for you (see above).
- **Namespaces.** A restore goes into the same project names the backup came from. The restore script stops if those projects already exist, unless you pass `--force`.
- **Settings you can override.** `OADP_PROJECT` (default `oadp-operator`), `OADP_DPA_NAME` (`cpd-dpa`), `OADP_OPERATOR_CHANNEL` (defaults to the channel the cluster's Red Hat catalog marks as default, e.g. `stable` → OADP 1.5 on OCP 4.21), `OADP_NODE_AGENT_TIMEOUT` (`72h`), `OADP_IMAGE_PREFIX`, `OADP_IMAGE_PREPULL_MINUTES` (`30`), `OADP_PLUGIN_IMAGE_FALLBACK` (`true`: a plugin image whose tag the registry lacks is swapped for the newest earlier tag in the same release line, e.g. `db2u-velero-plugin:5.4.0.7` → `5.4.0.6`; `--no-plugin-image-fallback` turns it off for one run) and the velero plugin images (`OADP_CPDBR_VELERO_PLUGIN_IMAGE`, `OADP_SWHUB_VELERO_PLUGIN_IMAGE`, `OADP_CPFS_OADP_PLUGIN_IMAGE`, `OADP_DB2U_VELERO_PLUGIN_IMAGE`) can go in `cpd_vars.sh` or the target config. If `PRIVATE_REGISTRY_LOCATION` is set, every cpd-cli oadp call gets `--private-registry-location`.
- **OADP resource presets.** `2_install_oadp_br_utilities.sh --resources minimal|small|medium`, or `OADP_RESOURCE_PRESET` in the config, sets the CPU/memory requests for Velero, the node agents and the OADP operator. `4.1_…` takes it as `--oadp-resources`. Limits stay at the defaults (Velero 1 CPU / 4Gi, node agent 1 / 32Gi, operator 1 / 512Mi). With low requests, a backup or restore only slows down when the nodes are busy.

  | Preset | Velero | Node agent (per node) | Operator | Requested on 2 workers |
  | --- | --- | --- | --- | --- |
  | `minimal` | 100m / 154Mi | 50m / 154Mi | 50m / 77Mi | ~0.3 CPU |
  | `small` (default) | 600m / 154Mi | 300m / 154Mi | 300m / 77Mi | ~1.5 CPU |
  | `medium` | 1 / 256Mi | 500m / 256Mi | 500m / 128Mi | ~2.5 CPU |

  A new DPA or subscription always gets the preset. An existing one is only changed when the preset is given explicitly. The script then skips the DPA while a Velero backup or restore is running, because the change restarts Velero.
- **Logs.** cpd-cli output is also written to `cpd-cli-workspace/oadp/` at the repo root. You can also run `cpd-cli oadp tenant-backup log <name>` or `cpd-cli oadp tenant-restore log <name>`.
- **Extra flags.** Anything after `--` is passed straight to `tenant-backup create` or `tenant-restore create`, for example `-- --precheck-exclude-checks=EdbClustersInSync`.
