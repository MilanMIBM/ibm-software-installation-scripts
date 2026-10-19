# OADP backup and restore for Software Hub / CP4D

Back up a whole Software Hub instance to an S3 bucket outside the cluster with `cpd-cli oadp tenant-backup`, and restore it with `cpd-cli oadp tenant-restore` onto another cluster (or the same one). Every script takes `--help`.

| Script | Run against | What it does |
| --- | --- | --- |
| `1.1_generate_backup_bucket_config.sh` | - | Writes `backup_bucket_configs/<name>_bucket.sh`: S3 URL, bucket, prefix, region, path style, keys |
| `1.2_generate_restore_target_config.sh` | - | Writes `restore_target_configs/<name>_vars.sh`: target cluster login + project names, in `cpd_vars.sh` format |
| `2_install_oadp_br_utilities.sh` | source, then target | OADP operator (OLM), credentials secret, DPA, cpdbr-tenant, br_orchestration (cpd-cli) |
| `3_backup_cp4d_instance.sh` | source | `tenant-backup create` (offline by default) |
| `4_restore_cp4d_instance.sh` | target | `tenant-restore create --from-tenant-backup` |

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
- **Namespaces.** A restore goes into the same project names the backup came from. The restore script stops if those projects already exist, unless you pass `--force`.
- **Settings you can override.** `OADP_PROJECT` (default `oadp-operator`), `OADP_DPA_NAME` (`cpd-dpa`), `OADP_OPERATOR_CHANNEL` (defaults to the channel the cluster's Red Hat catalog marks as default, e.g. `stable` → OADP 1.5 on OCP 4.21), `OADP_NODE_AGENT_TIMEOUT` (`72h`) and `OADP_IMAGE_PREFIX` can go in `cpd_vars.sh` or the target config. If `PRIVATE_REGISTRY_LOCATION` is set, every cpd-cli oadp call gets `--private-registry-location`.
- **Logs.** cpd-cli output is also written to `cpd-cli-workspace/oadp/` at the repo root. You can also run `cpd-cli oadp tenant-backup log <name>` or `cpd-cli oadp tenant-restore log <name>`.
- **Extra flags.** Anything after `--` is passed straight to `tenant-backup create` or `tenant-restore create`, for example `-- --precheck-exclude-checks=EdbClustersInSync`.
