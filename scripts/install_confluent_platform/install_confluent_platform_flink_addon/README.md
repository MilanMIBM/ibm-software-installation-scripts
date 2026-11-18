# Confluent Platform for Apache Flink

Installs [Confluent Platform for Apache Flink](https://docs.confluent.io/cp-flink/current/overview.html)
on OpenShift as an **add-on** to the Confluent Platform installed by the scripts
one directory up - or on its own, with a Kafka cluster attached afterwards.

## What gets installed

Flink is not delivered as `cp-*` Deployments like the rest of this stack. It is
two Helm charts from `https://packages.confluent.io/helm`:

| Component                                    | Chart                                | What it does                                                                                                        |
| -------------------------------------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| **Flink Kubernetes Operator**                | `flink-kubernetes-operator`          | Owns the `FlinkDeployment` CRDs and turns them into JobManager/TaskManager pods.                                    |
| **Confluent Manager for Apache Flink (CMF)** | `confluent-manager-for-apache-flink` | The REST control plane the `confluent flink` CLI talks to. Holds environments, catalogs, compute pools and secrets. |

`cert-manager` is a hard prerequisite - the operator's admission webhook needs
it. `1.0_flink_prep.sh` installs it only if absent, and never removes it.

By default Flink installs into its **own project** (`<confluent project>-flink`)
so it can be added and removed without touching the Kafka cluster.

## Prerequisites

- `helm` 3+ and the `confluent` CLI v4+ on PATH (`brew install helm confluentinc/tap/cli`; `1.0_flink_prep.sh` offers `src/utilities/cli_tool_utils/install_helm.sh` when helm is missing)
- Cluster-admin for the first install (CRDs, cert-manager, SCC binding). `1.0` checks this and says so up front.
- A ReadWriteMany storage class for checkpoints (`STG_CLASS_FILE`), or an S3 bucket

## Quick start

```bash
cd scripts/install_confluent_platform/install_confluent_platform_flink_addon

./0_flink_prepare_template_config.sh --size small   # write config into confluent_vars.sh
./1.0_flink_prep.sh                                 # cert-manager, project, SCC, storage
./1.1_flink_install.sh                              # both charts + environment + compute pool
./utility_scripts_confluent_flink/x.4_flink_connect_kafka.sh --test                 # attach the Kafka cluster and verify
./utility_scripts_confluent_flink/x.3_flink_sample_job.sh --sql                     # run a job end to end
```

Step `0` can be replaced by the `confluent_platform_vars_generation.py` notebook
(repo root) with the Flink add-on enabled. Steps `1.0`-`1.3` can be run in one go
with `./full_installprocess-confluent_flink.sh` - and
`../full_installprocess-confluent_platform.sh` already runs it after the platform
whenever the Flink settings are present in `confluent_vars.sh`.

## Scripts

| Script                                   | Purpose                                                                                                                                                                                                                              |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `0_flink_prepare_template_config.sh`     | Writes the Flink block into `configs/confluent_platform_config/confluent_vars.sh`. `--size xsmall\|small\|medium\|large`, plus per-value overrides. Re-runnable; the managed block is replaced, hand edits outside it are preserved. |
| `1.0_flink_prep.sh`                      | cert-manager, project, service accounts + `anyuid` SCC, checkpoint storage, licence secret, Helm repo. `--skip-cert-manager`, `--dry-run`.                                                                                           |
| `1.1_flink_install.sh`                   | Installs both charts, then creates the CMF environment and default compute pool. `--skip-operator`, `--skip-cmf`, `--skip-resources`, `--dry-run`.                                                                                   |
| `1.2_flink_status.sh`                    | Read-only report: workloads, Helm releases, PVCs, CMF resources, jobs. `--jobs`, `--no-cmf`.                                                                                                                                         |
| `1.3_flink_get_instance_details.sh`      | Writes live endpoints to `configs/confluent_platform_config/confluent_flink_instance_details.sh`.                                                                                                                                    |
| `full_installprocess-confluent_flink.sh` | Runs `1.0` → `1.3` in order (not `0`). Prep/install failures stop the chain; a failing status only warns. Per-step toggles: `DO_FLINK_PREP`, `DO_FLINK_INSTALL`, `DO_FLINK_STATUS`, `DO_FLINK_INSTANCE_DETAILS`.                     |
| `x.0_flink_uninstall.sh`                 | Removes everything, in the order that avoids stuck finalizers. `--keep-data`, `--keep-project`, `--dry-run`.                                                                                                                         |
| `x.2_flink_add_auth_openshift.sh`        | Puts the `cmf` route behind the OpenShift login with an oauth-proxy sidecar, as Control Center is. Browser login or `Authorization: Bearer $(oc whoami -t)`. `--disable`, `--dry-run`.                                               |
| `x.3_flink_sample_job.sh`                | Runs a sample job. `--application` (JAR, no Kafka needed) or `--sql` (needs a catalog). `--delete`, `--logs`, `--dry-run`.                                                                                                           |
| `x.4_flink_connect_kafka.sh`             | **Attaches a Kafka cluster.** Auto-discovers the Confluent install (protocol, mechanism, CA), or `--bootstrap` an external one. `--test`, `--replace`, `--allow-network`, `--dry-run`.                                                                         |
| `flink_cmf_connect.sh`                   | Sourced helper. Resolves `CMF_URL` via the route, or opens a port-forward and tears it down on exit.                                                                                                                                 |

## Attaching Kafka - the add-on path

`1.1` installs Flink knowing nothing about Kafka. `x.4_flink_connect_kafka.sh`
is what wires them together, and it is a **CMF-level** operation, not a Helm
value - which is why it works equally on a fresh install and on a Flink
instance that has been running for months.

It creates four CMF resources:

- a **`Secret`** holding the SASL credentials (so the catalog itself carries no password)
- a **`KafkaCatalog`** - carries the Schema Registry connection
- a **`KafkaDatabase`** - the Kafka cluster, registered under that catalog. Each topic becomes a `TABLE` in it. Created over the REST API, since the CLI has no `flink database` command yet
- an **`EnvironmentSecretMapping`** binding the secret to the environment

The database is registered with `ddlEnvironments` set, which is what lets Flink
SQL create topics. It defaults to empty, and without it a catalog reads fine but
every `CREATE TABLE` is refused.

With no flags it discovers everything from the Confluent installation in
`PROJECT_CONFLUENT_SERVER`: bootstrap address, the security protocol and SASL
mechanism the brokers are running (read from `broker-0`, so it follows
`CONFLUENT_SASL_PROTOCOL` / `CONFLUENT_SASL_MECHANISM`), the CA for `SASL_SSL`,
the admin credential read from the `confluent-sasl` secret, and the Schema
Registry endpoint. A `:443` bootstrap is treated as the EXTERNAL listener:
`SASL_SSL`, the first of `CONFLUENT_EXTERNAL_KAFKA_SASL_MECHANISMS` (PLAIN by
default) and the external CA. The CA travels inline in the `KafkaDatabase`
(`ssl.truststore.certificates`), because the CMF-created Flink pods have nothing
of ours mounted. After it runs:

```sql
SELECT * FROM `cp-kafka`.`cp-cluster`.`my-topic`;
```

For a Kafka cluster this repo did not install:

```bash
./utility_scripts_confluent_flink/x.4_flink_connect_kafka.sh --bootstrap kafka.example.com:9093 \
    --sasl-user app --sasl-password secret \
    --security-protocol SASL_SSL --sasl-mechanism PLAIN --ca-file ./kafka-ca.pem \
    --schema-registry https://sr.example.com
```

`--ca-file` can be left out when the cluster's certificate chains to a public CA.

### If queries hang

Flink runs in a different namespace from Kafka. Ingress NetworkPolicies selecting
the brokers or Schema Registry can block Flink's connections. The script checks
those selectors; `--allow-network` grants Flink access to already restricted pods
without isolating additional pods. Monitoring-only policies require no change.
The grants are removed with their source policies or when Flink is uninstalled.
Verify the whole path with `--test`, which runs
a real `SHOW TABLES` rather than just registering configuration.

**Other in-cluster clients:** existing restrictions, including a namespace-wide
`allow-flink` policy, require separate grants for clients such as StreamSets.
Allow the client namespace to reach the configured Kafka listener (default TCP
29092) and Schema Registry (default TCP 8081), then test from its engine pods.
Blocked schema lookups or Kafka metadata requests can prevent publishers from starting.

## Known constraints

Verified against CMF 2.4.2 and confluent CLI v4.74 on OpenShift. Several of
these differ from the published cp-flink docs.

**Reading Kafka works out of the box. Writing needs one broker setting.**
Flink's exactly-once sink requests a 1-hour Kafka transaction timeout, and
brokers cap it at 15 minutes by default - so every `INSERT INTO` hangs in
`PENDING` while the write task restart-loops. It cannot be fixed from the Flink
side (CMF exposes no such table option, and neither
`properties.transaction.timeout.ms` nor `table.exec.sink.transaction-timeout`
works as a pool config). The broker needs
`KAFKA_TRANSACTION_MAX_TIMEOUT_MS=3600000`, which the current
`1.1_confluent_install.sh` sets - but applying it **restarts the brokers**.
`x.4_flink_connect_kafka.sh` checks the live cluster and warns when it is
missing. Clusters installed before this change need a redeploy:

```bash
../1.1_confluent_install.sh    # restarts the brokers; topic data is preserved
```

**Other behaviour worth knowing:**

- The `confluent` CLI refuses *every* command with `not logged in` when
  `~/.confluent/config.json` holds an expired session - including `--url` CMF
  calls that need no login. `confluent_cli_login.sh` (MDS) leaves exactly such a
  context. These scripts run the CLI under an isolated `HOME` so the two cannot
  interfere.
- `confluent` CLI v4.74 has no `flink database` command, so the `KafkaDatabase`
  resource CMF 2.4 requires is created over the REST API.
- SQL differences from Confluent Cloud: `DISTRIBUTED INTO n BUCKETS` replaces
  `kafka.partitions`; `kafka.replication.factor` is not settable (topics take
  the broker default); the Cloud `datagen()` table function does not exist; and
  only one statement per submission is accepted.

## Configuration

All variables live in `configs/confluent_platform_config/confluent_vars.sh` alongside the Kafka ones,
so a single `ENV_TARGET=confluent` covers both. Notable settings:

| Variable                  | Default                             | Notes                                                                                                                                                                                                                         |
| ------------------------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PROJECT_CONFLUENT_FLINK` | `${PROJECT_CONFLUENT_SERVER}-flink` | Set to the Confluent project to co-locate them.                                                                                                                                                                               |
| `FLINK_STATE_BACKEND`     | `pvc`                               | `pvc` (RWX volume), `s3`, or `none`. Without durable state a job cannot recover from failure.                                                                                                                                 |
| `FLINK_CREATE_ROUTES`     | `true`                              | **The CMF REST API ships with no authentication.** A route exposes full control of Flink to anyone who can reach it - protect it with `x.2_flink_add_auth_openshift.sh`, or set `false` and the scripts port-forward instead. |
| `FLINK_SQL_IMAGE`         | `cp-flink-sql:1.19-cp11`            | Compute pools **must** use a `cp-flink-sql` image - CMF rejects anything else.                                                                                                                                                |
| `FLINK_APPLICATION_IMAGE` | `cp-flink:2.0.2-cp3`                | For JAR applications.                                                                                                                                                                                                         |
| `FLINK_LICENSE_KEY`       | inherits `CONFLUENT_LICENSE_KEY`    | CMF is commercial; empty means a 30-day trial.                                                                                                                                                                                |

Chart versions are pinned exactly (`FLINK_CMF_CHART_VERSION`,
`FLINK_OPERATOR_CHART_VERSION`) rather than with a `~` range, so a re-run never
silently upgrades the control plane.

## Uninstall

```bash
./utility_scripts_confluent_flink/x.0_flink_uninstall.sh              # removes Flink; Kafka untouched
./utility_scripts_confluent_flink/x.0_flink_uninstall.sh --keep-data  # keep CMF metadata and checkpoints
```

The platform's `../utility_scripts_confluent_platform/x.0_confluent_uninstall.sh`
also runs this first whenever the Flink settings are present (and passes
`--keep-data` whenever it keeps the broker data); set `DO_FLINK_UNINSTALL=false`
to remove the platform alone.

Jobs are deleted before the operator - the operator has to be alive to clear
FlinkDeployment finalizers, and removing it first leaves the namespace stuck in
`Terminating`. The Flink CRDs and cert-manager are cluster-scoped and shared, so
they are deliberately left in place; the script prints the commands to remove
them if nothing else depends on them.

## Operator mode (cp-fko through OLM)

With `CONFLUENT_DEPLOY_MODE=operator` (the default for new configs; unset means
operator too) the Flink add-on stops installing the Flink operator with Helm:

| Setting | Values | Default |
| --- | --- | --- |
| `FLINK_OPERATOR_SOURCE` | `helm` (scripts mode), `olm` (cp-fko through OLM), `existing` (a cp-fko that already watches the Flink project; detection only) | follows `CONFLUENT_DEPLOY_MODE`: `olm` in operator mode, `helm` in scripts mode |
| `FLINK_CMF_RESOURCE_MODE` | `cli` (environment through the `confluent` CLI, as today), `cfk` (CFK custom resources `CMFRestClass` + `FlinkEnvironment`, and `FlinkApplication` for `x.3 --application`) | `cfk` when the operator source is not `helm`, else `cli` |

What changes:

- **Operator step first.** `full_installprocess-confluent_flink.sh` runs
  `operator/1.0o_flink_operator_olm.sh` before 1.0: an OwnNamespace OperatorGroup and a
  `cp-fko` Subscription in `PROJECT_CONFLUENT_FLINK` (Manual approval by default; only the
  InstallPlan it asked for is approved), and - for `cfk` resources - Confluent for
  Kubernetes in `FLINK_CFK_NAMESPACE` with `ENABLE_CMF_DAY2_OPS=true` on its Subscription.
  The bundle creates the `flink` / `flink-operator` service accounts; 1.0 never re-creates
  them.
- **No cert-manager, no anyuid.** OLM issues the operator's webhook certificate. CMF 2.5
  runs under `restricted-v2`: 1.1 passes `podSecurity.securityContext.fsGroup=null` and
  `runAsUser=null` (instead of `runAsNonRoot=null`) and keeps `watchNamespaces={<flink ns>}`.
- **CMF stays a Helm release** (there is no OLM package for it). 1.1 writes the marker
  ConfigMap `confluent-ibm-scripts-deploy-mode` before `helm upgrade`, so the scripts-mode
  guard can tell an operator-mode CMF from a scripts-mode one.
- **CMF 2.5.0 pairs with cp-fko `stable-v1.16`** (CMF 2.4.x with `stable-v1.15`). The pair is
  locked: `FLINK_OLM_CHANNEL` must be the line `FLINK_CMF_CHART_VERSION` needs, and 1.1 checks
  the installed cp-fko channel before it installs CMF. CMF does not check the operator version
  itself under namespaced RBAC, so this lock is the only guard. On a cluster that already runs
  cp-fko 1.16 a CMF 2.4.x config is refused (plan C10) - use
  `FLINK_CMF_CHART_VERSION=2.5.0`.
- **One Flink operator per namespace.** A Helm Flink operator (scripts mode) in the namespace,
  the community `flink-kubernetes-operator` package, or a cp-fko of another version on the
  cluster stops the operator step with `[BLOCKED]` (exit 2). A scripts-mode Flink install is
  replaced with `../utility_scripts_confluent_platform/x.8_confluent_wipe_scripts_mode.sh --include-flink`.
- **`--autoselect-latest`** (full installer, operator step; `--persist` saves the choice) picks
  the newest compatible cp-fko line and CMF chart for a new install. The full installer needs
  `--persist` with it: its steps are separate processes, and 1.1 must install the CMF chart
  that pairs with the chosen cp-fko. Once cp-fko is installed it only reports; upgrades go
  through `../utility_scripts_confluent_platform/x.7_confluent_operator_upgrade.sh --flink`.

### CMF resources as CFK custom resources (`FLINK_CMF_RESOURCE_MODE=cfk`)

- 1.1 builds `environment-defaults.json` exactly as before and renders it into
  `FlinkEnvironment.spec.flinkApplicationDefaults` (never `metadata` - CMF rejects labels
  there), next to a `CMFRestClass` pointing at `http://<FLINK_CMF_SERVICE>.<flink ns>.svc.cluster.local:<FLINK_CMF_PORT>`.
  Both go to `flink_vars/rendered/cfk/flink/` and are applied in `FLINK_CFK_NAMESPACE`; 1.1
  waits for `.status.cmfSync.status=Created`, then creates the compute pool through the CLI as
  before (pools, catalogs, databases and statements have no CRD). An environment the CLI made
  earlier is adopted by name.
- `x.3_flink_sample_job.sh --application` renders a `FlinkApplication` CR (cpu as a string,
  `flinkVersion` capped at the CRD enum `v2_2`), applies it and waits for
  `.status.jobStatus.state=RUNNING`; `--delete` deletes the CR. `--sql` is unchanged.
- `x.4_flink_connect_kafka.sh` maps the Kafka secret through `FlinkEnvironment.spec.secrets`
  instead of `confluent flink secret-mapping create` (CFK would revert a CLI mapping), and
  reads the CFK Kafka cluster through its CRs (bootstrap, listener security, CA, the
  `kafka` / `schema-registry` pod labels for the NetworkPolicy, the transaction timeout).

### Uninstall in operator mode

`x.0_flink_uninstall.sh` hands over to `utility_scripts_confluent_flink/operator/x.0_flink_uninstall.sh`
(`--remove-operator`, `--delete-crds` and `--force-finalizers` on top of the usual flags). Order:
FlinkApplication CRs, CLI statements and applications, compute pools / catalog / secret, the
FlinkEnvironment, the CMFRestClass (last of the CFK objects - the environment's finalizer needs
it), remaining FlinkDeployments (cp-fko still running), the CMF release, then the operators
(`--remove-operator`) and the namespace.

**FlinkEnvironment finalizer.** With CFK 3.4.0 a deleted FlinkEnvironment CR can hang on its
finalizer (V34). The uninstall first deletes the environment through CMF REST. CMF 2.5.0
answers HTTP 422 while the default database of the environment's catalog still holds tables
or views - the uninstall then stops, names the catalog and its databases, and asks you to drop
them (`SHOW TABLES` / `DROP TABLE`, `SHOW VIEWS` / `DROP VIEW`). Only when CMF has deleted the
environment (2xx, or 404) and the CR is still there after `FLINK_ENVIRONMENT_DELETE_WAIT`
seconds does it apply Confluent's documented removal - annotate
`platform.confluent.io/block-reconcile=true`, `delete --wait=false`, clear the finalizers - and
logs it as `[WORKAROUND]`. With `--keep-data` it skips the CMF deletes and uses that documented
removal straight away, so the CMF environment (in the kept CMF PVC) survives.

The flink.apache.org CRDs belong to the OLM cp-fko install; the scripts-mode uninstall says so
instead of printing the CRD delete command when it sees `olm.managed=true` on them.
