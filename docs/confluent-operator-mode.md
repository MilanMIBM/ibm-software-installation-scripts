# Confluent operator mode

How the Confluent Platform scripts under `scripts/install_confluent_platform/` run the platform through
**Confluent for Kubernetes (CFK)** and Flink through **cp-fko**, both installed by OLM. The other mode,
**scripts mode**, is the original one: the repo renders and applies raw manifests (StatefulSet `broker`,
Deployments, ...). Both modes use the same scripts, the same config file and the same names for the things
other tools read.

Versions in this page are the defaults of 2026-11 (CFK 3.4.0, cp-fko 1.16.1-cp1, CMF 2.5.0). The design and
its open checks are in `.claude/plans/confluent-operator-install-mode/`.

## The toggle and its default

`CONFLUENT_DEPLOY_MODE` in `configs/confluent_platform_config/confluent_vars.sh`:

| Value | Meaning |
| --- | --- |
| `scripts` | Scripts mode. Every script behaves exactly as before operator mode existed. |
| `operator` | Operator mode. CFK and cp-fko run the platform. |
| unset, empty, anything else | **Operator mode.** An invalid value also prints `[WARN] CONFLUENT_DEPLOY_MODE='<v>' is not scripts\|operator - using operator`. |

The value is case-insensitive, and surrounding blanks are ignored.

- **New configs** get the line written explicitly. Both the notebook (`confluent_platform_vars_generation.py`,
  *Deploy mode* in "Components & Security") and `0_confluent_prepare_template_config.sh` default to `operator`.
  Pass `--deploy-mode scripts` to the script for a scripts-mode file.
- **Existing configs** keep their value. A file without the line gets a warning and nothing about the mode is
  written. Switching a file needs `--switch-deploy-mode`. Switching is a fresh install, see
  [Changing modes](#changing-modes).
- `utility_scripts_confluent_platform/x.9_confluent_set_deploy_mode.sh` reports the file, the resolved mode and
  whether the namespace holds a scripts-mode install. `--set scripts|operator` writes the line (`--yes`,
  `--dry-run`).
- The Flink add-on follows the platform unless `FLINK_OPERATOR_SOURCE` says otherwise: `helm` (the Helm operator
  chart, the scripts-mode way), `olm` (cp-fko through OLM) or `existing` (a cp-fko already on the cluster). Unset
  means `olm` in operator mode and `helm` in scripts mode.

### The scripts-mode guard

Before any write, every operator-mode entry point checks the namespace. This covers the full installers, the
`1.x` steps, the Flink steps and the `x.*` utilities. If the namespace holds a scripts-mode install
(`statefulset/broker`, or one of the scripts-mode Deployments), the script stops with exit code 2:

```
[BLOCKED] Namespace <ns> holds a scripts-mode Confluent install.
          CONFLUENT_DEPLOY_MODE is <unset|invalid|operator>, which means operator mode.
          Choose one:
            1. Keep it: set CONFLUENT_DEPLOY_MODE="scripts" in <config file>
            2. Replace it: run .../utility_scripts_confluent_platform/x.8_confluent_wipe_scripts_mode.sh
               (add --keep-data to keep the PVCs), then re-run this script.
```

The check only reads. No flag or variable skips it. The Flink variant looks for a Helm
`flink-kubernetes-operator-*` release, or a CMF release without the operator-mode marker ConfigMap
`confluent-ibm-scripts-deploy-mode`.

### Changing modes

Changing modes means removing one install and making a new one. There is no migration: CFK cannot adopt the
scripts-mode combined KRaft data.

- **Scripts to operator:** run `x.8_confluent_wipe_scripts_mode.sh`. It accepts `--keep-data`,
  `--include-flink`, `--dry-run`, `--yes` and `--confirm-delete-data <namespace>`. It removes only the
  scripts-mode objects and refuses to run while a CFK `Kafka` CR is in the namespace. With `--keep-data` it
  labels the PVCs `confluent.ibm-scripts/wiped-from=scripts-mode` and keeps them. They are a backup only;
  move data with ClusterLink or by producing it again. Then set the mode to `operator` and re-run the full
  installer.
- **Operator to scripts:** run `x.0_confluent_uninstall.sh` while the file is still in operator mode
  (`--delete-data --remove-operator` for a clean namespace), then switch the file.

## What runs in operator mode

`full_installprocess-confluent_platform.sh` adds one step, `operators`, and runs it **first**
(`operator/1.0o_confluent_operators.sh`). Then it runs `1.0` prep, `1.1` install, `1.2` status and `1.3`
instance details, as in scripts mode. The Flink full installer likewise starts with `operator`
(`install_confluent_platform_flink_addon/operator/1.0o_flink_operator_olm.sh`).

- **One OLM install per namespace.** Each install has an OwnNamespace OperatorGroup. The default targets are
  `PROJECT_CONFLUENT_SERVER` and, when the Flink add-on is configured, `PROJECT_CONFLUENT_FLINK`.
  `CONFLUENT_OPERATOR_EXTRA_NAMESPACES` adds namespaces, and `CONFLUENT_OPERATOR_PACKAGES_PER_NS`
  (`ns=pkg[,pkg] ...`) overrides the package set of a namespace.
- **Reuse before install.** An operator that already watches the namespace is reused. A conflict stops the step
  with a `[BLOCKED]` banner and never edits the foreign object. Conflicts are an OperatorGroup with another
  scope, two operators watching one namespace, a Helm Flink operator on the namespace, or the community
  `flink-kubernetes-operator` package.
- **One version per package on the cluster.** CFK and cp-fko share cluster-wide CRDs. OLM installs an older
  bundle without complaint and silently downgrades those CRDs. So any CSV of another version anywhere on the
  cluster blocks the install.
- **Ownership.** Our Subscriptions, OperatorGroups, created namespaces, CRs and repo objects carry
  `confluent.ibm-scripts/installed-by=<cluster>.<namespace>`. Uninstall touches only what carries our label.
- **Operator settings** are written once to a section of the config file and then preserved
  (`CONFLUENT_OPERATOR_*`, timeouts, connect-plugin PVC). KRaft controller sizing (`CONFLUENT_KRAFT_*`, ksqlDB,
  C3 and Prometheus storage) is in its own managed block. That block follows `--size` like the sizing block.
- **Pod security.** Every CFK CR gets `podSecurityContext: {}`, so the pods run under OpenShift's
  `restricted-v2` without SCC grants.

## Versions, approval and upgrades

| Item | Default | Variable |
| --- | --- | --- |
| CFK | channel `3.4`, CSV `confluent-for-kubernetes.v3.4.0` | `CONFLUENT_OPERATOR_CHANNEL`, `CONFLUENT_OPERATOR_STARTING_CSV` |
| cp-fko | channel `stable-v1.16`, CSV `cp-fko.v1.16.1-cp1` | `FLINK_OLM_CHANNEL`, `FLINK_OLM_STARTING_CSV` |
| CMF chart (operator mode) | `2.5.0` | `FLINK_CMF_CHART_VERSION` |
| Confluent Platform / C3 | as in scripts mode; CFK 3.4 runs CP 7.6.0 to 8.4.x and C3 2.4 to 2.7 | `CONFLUENT_VERSION`, `CONFLUENT_C3_VERSION` |

- The CMF version determines the cp-fko channel (CMF 2.5 needs cp-fko 1.16, CMF 2.4 needs 1.15).
  A `FLINK_OLM_CHANNEL` that does not match is an error. The pairs live in
  `src/helpers/version_catalog.json` (`confluent/operator`).
- `--autoselect-latest` (full installers, operator steps, Flink 1.1) reads the newest compatible set from the
  live catalog and the Confluent Helm index. It prints that set next to the pinned one and uses it for **new**
  installs only. `--persist` writes the set to the config. An operator that is already installed is never
  upgraded this way: the step only reports the newer set.
- **Approval.** `CONFLUENT_OPERATOR_INSTALL_PLAN_APPROVAL` and `FLINK_OLM_INSTALL_PLAN_APPROVAL` default to
  `Manual`. The install step then approves only the InstallPlan whose CSVs it asked for. `Automatic` lets OLM
  apply minor bumps, which roll the cluster without the upgrade safeguards; the checks warn about it.
- **Upgrades** go through `utility_scripts_confluent_platform/x.7_confluent_operator_upgrade.sh`. `--check` (the
  default) lists installed versus available versions, and `--set-approval Manual|Automatic` patches our
  Subscriptions. `--channel CH` and `--approve` run the upgrade: they set
  `platform.confluent.io/block-reconcile=true` on our CRs, move the Subscription, wait for the CSV, update
  `spec.image.init`, then release the CRs and wait for the rolls.
- **OLM approves per namespace.** OLM puts every Subscription of a namespace into one InstallPlan. Approving a
  CFK upgrade in a namespace that also holds cp-fko therefore upgrades cp-fko too. x.7 warns, and asks unless
  `--yes`.

## Operator sources and air-gapped clusters

`CONFLUENT_OPERATOR_SOURCE=olm` (the default) installs from the cluster's OperatorHub catalog
(`CONFLUENT_OPERATOR_CATALOG_SOURCE`, default `certified-operators` in `openshift-marketplace`). With
`existing`, the scripts only detect and reuse an operator that is already there. `helm` is reserved for a
later Kubernetes variant.

If the catalog does not carry the package or channel, for example on an air-gapped cluster with the default
sources disabled, the operators step stops with:

```
[BLOCKED] confluent-for-kubernetes channel 3.4 is not in CatalogSource certified-operators - mirror it: private_registry_mirroring 1.0 -> 2.2 -> 3.4 with MIRROR_CONFLUENT_CONTENT including "operators"
```

Mirroring, with `scripts/private_registry_mirroring/`:

- **Components and content.** `0.0_generate_mirror_config.sh --prefill-from-installs` sets them from the
  config. In operator mode it adds component `cfk-operator` and content kind `operators`. With the cp-fko
  source it lists `flink-operator-olm` instead of the Helm chart component `flink-operator`. By hand:
  `MIRROR_CONFLUENT_COMPONENTS=...,cfk-operator[,flink-operator-olm]` and
  `MIRROR_CONFLUENT_CONTENT=images,...,operators`.
- **1.0 (map)** emits the OLM packages `confluent-for-kubernetes` (`CONFLUENT_OPERATOR_CHANNEL`) and `cp-fko`
  (`FLINK_OLM_CHANNEL`, else the channel the CMF version needs) to the shared operators track. With `images`, it
  also emits the CFK init container (`CONFLUENT_OPERATOR_INIT_IMAGE`).
- **The operator image.** The CSV runs `docker.io/confluentinc/confluent-operator` by digest. Whether oc-mirror
  carries that image through the bundle's `relatedImages` is unverified. To mirror it explicitly, set
  `MIRROR_CONFLUENT_OPERATOR_DIGEST` in the mirror config. The digest cannot be derived offline; read it on a
  connected cluster:

  ```bash
  oc get csv confluent-for-kubernetes.v3.4.0 -n <namespace> \
    -o jsonpath='{.spec.install.spec.deployments[0].spec.template.spec.containers[0].image}'
  ```

- **2.2 and 3.4** are the shared operators track: one oc-mirror run for every operator, with no
  Confluent-specific code. 3.4 renames the mirrored catalogs back to `certified-operators`, so the
  Subscriptions resolve unchanged. The generated IDMS/ITMS redirect the digests.
- **3.5 (tap)** writes `CONFLUENT_OPERATOR_INIT_IMAGE` next to the other image overrides when the init image was
  mapped. The CR images (`CONFLUENT_OPERATOR_IMAGE_SOURCE=tags`, the default) follow `CONFLUENT_REGISTRY` and the
  image variables as in scripts mode. With `csv`, they are the CSV's digests, which the operators IDMS covers.
- **verify-cluster** skips images that an OLM CSV in the namespace names, because the operators IDMS redirects
  them.
- **Connector plugins.** Operator-mode Connect downloads Hub and URL plugins from inside the pod. In an air gap,
  install the mirrored ZIPs as local sources (the `connect-plugins` PVC, below).

## Kafka security

### SASL

`CONFLUENT_SASL_MECHANISM` must be `PLAIN` in operator mode. CFK's components authenticate to Kafka only
through its native SASL/PLAIN. The generators set it, and the checks refuse anything else.
`CONFLUENT_OPERATOR_SASL_IMPL` chooses what the listeners offer:

| Value | Implementation | Support |
| --- | --- | --- |
| `plain` (default) | Native CFK SASL/PLAIN on the internal and external listeners. The CFK-format secrets `confluent-sasl-cfk-server` / `-client` are derived from `CONFLUENT_SASL_SECRET`. | Supported by CFK and Confluent Support |
| `scram` | Confluent's documented route: `Kafka.spec.configOverrides.server` adds SCRAM-SHA-512/256 per listener next to PLAIN. Users are registered with `kafka-configs` inside `kafka-0`. Each change rolls the brokers one at a time. | Documented by Confluent, **outside Confluent Support**; warned on every run |

With `plain`, a SCRAM entry in `CONFLUENT_INTERNAL_KAFKA_SASL_MECHANISMS` or
`CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS` is refused with
`[ERROR] SCRAM needs CONFLUENT_OPERATOR_SASL_IMPL=scram (configOverrides; outside Confluent Support) or use PLAIN`.

Confluent's statements on SCRAM in CFK:

- <https://docs.confluent.io/operator/current/co-authenticate-overview.html>
- <https://docs.confluent.io/operator/current/co-configure-misc.html#co-config-overrides>
- <https://docs.confluent.io/operator/current/co-authenticate-kafka.html>
- <https://docs.confluent.io/platform/current/security/authentication/sasl/scram/overview.html>

### TLS sources

`CONFLUENT_OPERATOR_TLS_SOURCE` (or `--tls-source` on `1.1` and the full installer, which wins):

- `repo` (default): the repo makes the in-cluster certificates, as in scripts mode. They are stored in
  `CONFLUENT_INTERNAL_TLS_SECRET` with the keys `ca.crt`, `fullchain.pem`, `privkey.pem` and `cacerts.pem`.
- `cfk`: CFK generates them (`tls.autoGeneratedCerts`) from the CA in `ca-pair-sslcerts` (`tls.crt` /
  `tls.key`). `1.3` and `x.5_confluent_add_cert_to_vault.sh` publish `tls.crt` of that secret as the internal
  CA.
- **Route SANs.** CFK's generated certificates carry in-cluster names only, with no route hosts. External
  clients with default hostname verification would fail. So with the external listener on, the external
  listener always uses a repo-made certificate (`CONFLUENT_EXTERNAL_TLS_SECRET`) whose SANs are the bootstrap
  and broker route hosts, even with the `cfk` source. The script prints this note.

## License

Every CR references the secret `confluent-license` (key `license.txt`), which is built from
`CONFLUENT_LICENSE_KEY`. Without a key, Confluent Platform runs on its 30-day trial license. The generators
and `1.1` warn once: `[WARN] No CONFLUENT_LICENSE_KEY - Confluent Platform runs on the 30-day trial license.`

## Data and deletion

**Deleting a CFK CR deletes its data.** When a `Kafka`, `KRaftController`, `KsqlDB` or `ControlCenter` CR is
deleted, CFK deletes its PVCs (`data0-*`, `data-*`, `prometheus-data-*`). With a StorageClass reclaim policy of
`Delete`, the volumes go too. The only Confluent-documented way to keep the data is the PV reclaim policy
`Retain`, so in operator mode:

- `x.0_confluent_uninstall.sh` keeps the data by default (`KEEP_DATA`). Before it deletes the stateful CRs, it
  patches the PV behind each data PVC to `persistentVolumeReclaimPolicy: Retain`. It labels each PV
  `confluent.ibm-scripts/retained-from=<namespace>.<cr>`, and an annotation of the same key holds
  `<namespace>/<cr>`. After the deletes, it lists the retained PVs. If the patch fails, nothing is deleted.
- **Recovery is manual.** Re-attaching a retained PV to a new CR is not documented by Confluent, so the
  retained PVs are a backup. Remove them with
  `oc delete pv -l confluent.ibm-scripts/retained-from` once they are no longer needed.
- `--delete-data` skips the Retain patch, so the PVs follow the StorageClass policy. Leftover PVCs are
  deleted only with this flag.
- `x.1_confluent_reinstall.sh` keeps the `Kafka`, `KRaftController`, `KsqlDB` and `ControlCenter` CRs by
  default, re-runs `1.1` and lets CFK reconcile them in place, so the data stays. With `--delete-data`, it runs
  the full uninstall first.
- `--remove-operator` also removes the operators that this install created. Only then is the namespace
  deleted, and only if nothing foreign is left in it. `--delete-crds` is a flag only (no variable, not implied
  by `--yes`). It is refused while any CSV or CR of those CRDs exists anywhere, and each CRD group asks its own
  `y/N` question on the terminal. The platform `x.0` offers the `platform.confluent.io` CRDs and, when the Flink
  add-on is configured, the `flink.apache.org` CRDs; answering no to one still offers the other.

## Flink add-on

- **cp-fko through OLM** (`FLINK_OPERATOR_SOURCE=olm`) in `PROJECT_CONFLUENT_FLINK`, paired with CMF 2.5.0.
  CMF runs under `restricted-v2`, with no `anyuid` grant.
- **CMF resources** (`FLINK_CMF_RESOURCE_MODE`): `cli` creates the environment through the CMF CLI and REST,
  as in scripts mode. `cfk` (the default when the source is not `helm`) uses CFK CRs `CMFRestClass`,
  `FlinkEnvironment` and `FlinkApplication` in `FLINK_CFK_NAMESPACE`, which defaults to the Flink namespace.
  The CFK Subscription there gets `ENABLE_CMF_DAY2_OPS=true`.
- **Removing a FlinkEnvironment** follows Confluent's documented route, in this order:
  1. Delete the FlinkApplications.
  2. Delete the CLI-made statements, pools and catalogs.
  3. Delete the environment through CMF REST. CMF 2.5.0 answers 422 while the catalog's `default` database
     still holds tables or views. The uninstall then stops, keeps the CR, and names the catalog, its databases
     and the `DROP TABLE` / `DROP VIEW` to run.
  4. Delete the `FlinkEnvironment` CR.
  5. If the CR is still there after `FLINK_ENVIRONMENT_DELETE_WAIT` seconds (default 60) and CMF reports the
     environment gone, the script applies the documented removal and logs a `[WORKAROUND]` line: annotate
     `platform.confluent.io/block-reconcile=true`, `delete --wait=false`, clear the finalizers.

  The `CMFRestClass` is deleted last.
- The Flink operator CRDs (`flink.apache.org`) are OLM-managed and shared with other cp-fko installs. The
  uninstallers never suggest deleting them.

## Endpoints and names that change

Everything other tools read keeps its name. That covers `confluent_instance_details.sh` keys, the secret
names, the route names `schema-registry`, `connect`, `ksqldb-server`, `rest-proxy`, `control-center`, `mds`,
`keycloak` and `cmf`, the service account `confluent` and the label `app.kubernetes.io/part-of=confluent`.
Read endpoints from the instance details, never from pod names. These change:

| What | Scripts mode | Operator mode |
| --- | --- | --- |
| Kafka pods | `broker-N` (combined KRaft) | `kafka-N` (container `kafka`) and `kraftcontroller-N` |
| Internal bootstrap | `broker.<ns>.svc.cluster.local:29092` | `kafka.<ns>.svc.cluster.local:9071` (from `Kafka.status.listeners`) |
| External access | routes `broker-N-kafka` | passthrough routes `kafka-bootstrap` (`CONFLUENT_EXTERNAL_KAFKA_BOOTSTRAP_PREFIX.<domain>:443`) and `kafka-N` (`CONFLUENT_EXTERNAL_KAFKA_BROKER_PREFIX<N>.<domain>`); details list the bootstrap only |
| Component Services | repo Services | CFK headless Services named after the CR (`schema-registry`, `connect`, `ksqldb-server`, `rest-proxy`, `control-center`); fixed CFK ports (SR 8081, Connect 8083, ksqlDB 8088, REST 8082, C3 9021) |
| C3 behind auth | nginx gateway Deployment | front proxy `control-center-auth` (its own Service; the route `control-center` points at it) |
| Instance details | | adds `CONFLUENT_DEPLOY_MODE_DEPLOYED="operator"`, `CONFLUENT_OPERATOR_DEPLOYED_CSV`, `CONFLUENT_OPERATOR_DEPLOYED_NAMESPACE` (Flink: `FLINK_OPERATOR_DEPLOYED_*`, `FLINK_CMF_RESTCLASS_DEPLOYED`) |

`confluent_cli_login.sh` reads the instance details only. In operator mode its hints name `kafka-0` and port
`9071`.

## Connect plugins and connectors

- `x.3_confluent_add_connector.sh` keeps its CLI. Confluent Hub coordinates and URLs become
  `Connect.spec.build.onDemand.plugins`, with the sha512 computed by the script. Local ZIP, JAR or directory
  sources are copied into the PVC `connect-plugins` (`CONFLUENT_CONNECT_PLUGINS_PVC*`). A short-lived loader
  pod (`CONFLUENT_CONNECT_PLUGINS_LOADER_IMAGE`, default `registry.access.redhat.com/ubi9/ubi:latest`, which has
  `tar`) receives the copy, and Connect mounts the PVC at `/mnt/local-plugins`. CFK rolls Connect itself.
- `CONFLUENT_CONNECTOR_MANAGEMENT=rest` (default) manages connectors through the Connect REST API, as in scripts
  mode. `cr` uses `Connector` CRs. Their credentials are in a mounted secret, referenced through the file config
  provider, never in the CR.

## Watching the CRs

`scripts/install_confluent_platform/x_confluent_cr_dashboard.sh` is a read-only terminal dashboard. It shows
`Kafka`, `KRaftController`, `SchemaRegistry`, `Connect`, `KsqlDB`, `KafkaRestProxy` and `ControlCenter`, plus
`FlinkEnvironment` and `FlinkApplication` when the CMF resources are CFK CRs. Without a terminal it prints the
state once. `--once` and `--exit-when-settled` work as in the CP4D dashboard. Status overrides are in
`confluent_cr_dashboard_profile.yaml`.

## Not in v1

- **Plain Kubernetes.** Operator mode with `CONFLUENT_CLUSTER_PLATFORM=kubernetes` stops with
  `[ERROR] operator mode is OpenShift-only in v1`. The places a Helm-installed CFK would plug in are marked
  `K8S-EXTENSION(K<n>)` in the code.
- **Live checks still open:**
  - MDS/RBAC in operator mode (phase 5).
  - Mixed Hub and URL Connect plugins.
  - The exact `FLINK_SQL_IMAGE` tag for CMF 2.5.
  - HTTP routes to CFK's headless Services.
  - Whether oc-mirror carries the operator image.
  - The PV names behind `alertmanager-data-*`.
  - The exact CMF 422 body.

  Each is recorded in the plan.
