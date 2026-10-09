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

- `helm` 3+ and the `confluent` CLI v4+ on PATH (`brew install helm confluentinc/tap/cli`)
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

Flink runs in a different namespace from Kafka. If the Confluent project has
NetworkPolicies, Flink's connections are silently dropped and every query times
out. The script detects this and warns; `--allow-network` adds a policy
permitting the Flink namespace. Verify the whole path with `--test`, which runs
a real `SHOW TABLES` rather than just registering configuration.

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
