# Iceberg sink configuration for Control Center

[iceberg-avro.example.json](iceberg-avro.example.json) is a flat Kafka Connect configuration for Control Center's **Upload connector config file** action. It targets Apache Iceberg Sink Connector **1.9.2**, an Avro source topic, and a watsonx.data Iceberg REST catalog backed by IBM COS. Supply environment values and credentials in a local copy.

The file includes the connection settings and relevant defaults for a single destination table. Routing, upsert, CDC, custom partitioning, and other optional features are left unset. Environment values and the initial table creation setting are choices for this example, not universal connector defaults.

## Automated setup

[x.6_confluent_setup_iceberg_watsonx.sh](../utility_scripts_confluent_platform/x.6_confluent_setup_iceberg_watsonx.sh) installs the plugin if it is missing, creates or reuses a dedicated Software Hub SID, assigns its lakehouse **Metastore Admin** role, and creates or updates one named connector. It requires a running Confluent deployment and an existing COS-backed Iceberg catalog in watsonx.data.

Copy the [setup example](iceberg-watsonx.example.sh) into the ignored configuration directory:

```sh
cp scripts/install_confluent_platform/connector_configs/iceberg-watsonx.example.sh \
  configs/confluent_platform_config/iceberg_watsonx_setup.sh
chmod 600 configs/confluent_platform_config/iceberg_watsonx_setup.sh
```

Fill its topic, destination table, catalog REST URI, catalog name, and COS HMAC settings. It defaults to an Avro value converter, the SID `svc-iceberg`, and connector name `iceberg-sink`. The file is sourced as shell configuration, so quote its values and use `export` for each setting. Keep this credentials-bearing copy under `configs/`.

To include setup in a full installation:

```sh
DO_ICEBERG_WATSONX_SETUP=true \
  scripts/install_confluent_platform/full_installprocess-confluent_platform.sh
```

The generic configuration generators default the flag to `false`. It can also be enabled in `confluent_vars.sh`. `ICEBERG_WATSONX_CONFIG_FILE` selects another setup configuration path when needed.

To set up the integration after the platforms are already installed:

```sh
scripts/install_confluent_platform/utility_scripts_confluent_platform/x.6_confluent_setup_iceberg_watsonx.sh
```

The same utility supports:

| Option | Behaviour |
|---|---|
| `--config FILE` | Load another shell setup configuration |
| `--service-id USER` | Override the SID name |
| `--dry-run` | Authenticate, inspect prerequisites, validate configuration when the plugin is loaded, and report work without changing resources or writing connector JSON; standard environment loading and login still run |
| `--prepare-only` | Set up identity, role, and plugin, then write and validate JSON for manual upload; leave the connector unchanged |

`ICEBERG_APPLY_CONNECTOR=false` also selects preparation without connector deployment. The generated flat JSON defaults to `configs/confluent_platform_config/iceberg-sink.json`, is checked to be Git-ignored, and is written with mode `0600`. `ICEBERG_OUTPUT_FILE` overrides its location inside the repository.

The utility checks for the existing catalog, Software Hub service instance, and reachable Connect worker before changing resources. It reuses working SID passwords, keeps existing API keys, skips a loaded Iceberg plugin, and leaves an already matching connector configuration alone. Plugin upgrades are explicit operations through the existing installer. Changing a connector's configuration uses its existing name, preserving its identity and consumer group. Existing properties outside the generated profile are retained, and a name already used by another connector type is rejected.

Software Hub administrator credentials are read from the environment or `configs/cp4d_config/cpd_instance_details.sh`; `ICEBERG_CPD_DETAILS_FILE` overrides that file. They are used to assign the service role. The connector receives only the SID's credentials. SID creation uses the existing helper with `ICEBERG_CPD_ENV_TARGET` (default `cpd`) in a temporary kubeconfig, preserving the Confluent cluster context. Keep that CPD configuration paired with the selected Software Hub details file. Its configured htpasswd provider is reused, including a Tech Zone-managed provider when configured there.

For an externally managed, existing SID, set `ICEBERG_SERVICE_PASSWORD` through the environment or private setup configuration. If those credentials fail, setup stops without repairing the account. Otherwise the helper reads its saved password from `configs/openshift_config/service_id_credentials.txt` and creates or repairs the selected htpasswd identity when needed. Account creation can have the IAM side effects described in the identity section below.

Host-side Software Hub and REST catalog calls verify HTTPS certificates by default. `ICEBERG_VERIFY_TLS=false` allows an environment with self-signed routes; it does not configure the Java worker's truststore. Connector configuration validation does not test the COS credentials. Verify task status and a committed table through SQL after setup.

## Fresh-cluster checklist

The automated setup above performs the plugin, identity, role, and connector steps. For manual setup:

1. Deploy Confluent Platform with Kafka Connect and Schema Registry, and configure an external COS-backed Iceberg catalog in watsonx.data. Associate the catalog with a Presto engine for verification.
2. Once Connect is running, install the plugin with the existing helper:

   ```sh
   scripts/install_confluent_platform/utility_scripts_confluent_platform/x.3_confluent_add_connector.sh \
     iceberg/iceberg-kafka-connect:1.9.2 --name iceberg
   ```

3. Create or reuse a dedicated Software Hub identity and assign its lakehouse **Metastore Admin** role as described below. This profile uses its password; generating an API key is unnecessary.
4. Prepare an ignored local copy of the JSON with the current endpoints, catalog, topic, table, SID credentials, and COS HMAC credentials.
5. Upload and launch the connector, then verify committed data through watsonx.data's SQL workspace.

External COS preserves the table files independently of the cluster. Catalog definitions, table registrations, and Kafka connector progress also need to be preserved or restored when rebuilding around existing tables. A fresh ingestion with no saved progress can replay retained Kafka records into a table that already contains them.

## Prepare a local copy

From the repository root:

```sh
cp scripts/install_confluent_platform/connector_configs/iceberg-avro.example.json \
  configs/confluent_platform_config/iceberg-sink.json
```

The destination is already ignored by Git. Edit that copy and replace every placeholder:

| Placeholder | Value to supply |
|---|---|
| `<KAFKA_TOPIC>` | Avro source topic |
| `<WATSONX_DATA_MDS_REST_HOST>` | Hostname from the catalog's Metastore REST endpoint; include a port if required |
| `<WATSONX_DATA_CATALOG>` | Existing watsonx.data Iceberg catalog name |
| `<WATSONX_DATA_USERNAME>` | Dedicated Software Hub user with access to the lakehouse metastore |
| `<WATSONX_DATA_PASSWORD>` | That user's Software Hub password |
| `<COS_REGION>` | IBM COS bucket region; replace both occurrences |
| `<COS_HMAC_ACCESS_KEY_ID>` | HMAC access key for the external COS bucket |
| `<COS_HMAC_SECRET_ACCESS_KEY>` | Corresponding HMAC secret key |
| `<SCHEMA>` | Destination schema/namespace |
| `<TABLE>` | Destination table name |

Review the connection values before uploading, especially after replacing a cluster:

| Property | Example value and meaning |
|---|---|
| `name` | `iceberg-sink`: choose a unique connector instance name |
| `topics` | Avro source topic |
| `value.converter.schema.registry.url` | `http://schema-registry:8081`: reachable from the Connect pod |
| `iceberg.catalog.uri` | MDS REST endpoint plus `/api/v1/iceberg`; confirm the path supported by the installed watsonx.data version |
| `iceberg.catalog.warehouse` | Existing watsonx.data catalog name |
| `iceberg.catalog` | `iceberg`: default local client label; the warehouse property selects the remote catalog |
| `iceberg.catalog.s3.endpoint` | IBM COS regional endpoint; use the endpoint for the bucket's location |
| `iceberg.catalog.client.region` | COS bucket region |
| `iceberg.catalog.s3.path-style-access` | `false`: default virtual-host addressing; use `true` if the object store requires path-style addressing |
| `iceberg.tables` | Destination in `schema.table` form |

The warehouse property selects the watsonx.data catalog. The bucket and storage prefix come from catalog/schema/table locations; they are not separate bucket-name properties in this configuration.

## Software Hub identity and permissions

Use a dedicated account. IBM documents **Metastore Admin** as the service role for direct access to the Metadata Service (MDS). This is a lakehouse service role; the connector account can retain the Software Hub platform **User** role and does not need OpenShift administrator privileges. Metastore Admin grants broad metastore access across the lakehouse.

An administrator assigns the service role in **Software Hub > Instances > lakehouse > Manage access**:

1. If the account already appears in the **Users** table, find its row and change **Service role** to **Metastore Admin**.
2. If the account is missing from that table, open **Add users**, select it, choose **Metastore Admin**, and click **Add**.

The **Add users** dialog disables accounts that already have access to the instance. A locked **User** dropdown there means the existing assignment must be edited in the main **Users** table; it does not mean an htpasswd account is ineligible for the role.

The repository's [set_service_id_user_proxies.sh](../../../src/utilities/redhat_openshift_utils/set_service_id_user_proxies.sh) creates htpasswd-backed OpenShift identities and registers them as external Software Hub users with the platform **User** role. Those accounts are suitable for the connector, but the helper does not assign lakehouse service roles. Reuse an existing dedicated identity by granting its service role above and filling the username/password placeholders. Its saved password is in the ignored `configs/openshift_config/service_id_credentials.txt` file.

For a new identity, run the helper with an explicit username, then assign the lakehouse service role:

```sh
src/utilities/redhat_openshift_utils/set_service_id_user_proxies.sh svc-iceberg
```

The helper's first-time setup can restart IAM to enable username/password API authentication; read its header before running it on a new cluster. Existing accounts do not need to be recreated to change a lakehouse role. [generate_service_id_cpd_apikeys.sh](../../../src/utilities/redhat_openshift_utils/generate_service_id_cpd_apikeys.sh) generates replacement API keys and revokes existing ones; it is unnecessary for this password-based profile. Use a separate identity for each integration to keep credentials and permissions independent.

Catalog User and SQL `SELECT`/`INSERT` policies describe access through query engines and do not establish write access to the direct MDS interface. A Metastore Viewer is read-only. The sink does not need access to a Presto engine to ingest; the person querying the result needs the appropriate Presto/catalog/data permissions separately.

COS authorization is independent: the HMAC identity must have permission to read, list, write, and perform the object operations needed by Iceberg in the target bucket/prefix. Software Hub roles do not grant permissions in the external IBM Cloud account.

See IBM's [MDS access instructions](https://www.ibm.com/docs/en/software-hub/5.4.x?topic=administering-managing-access-metadata-service-mds), [watsonx.data roles](https://www.ibm.com/docs/en/watsonxdata/premium/2.4.x?topic=access-predefined-roles-permissions-in-watsonxdata), and [Iceberg connector configuration](https://www.ibm.com/docs/en/watsonxdata/premium/2.4.x?topic=connector-configuring-iceberg-sink-in-confluent-cloud).

## Destination and defaults

The destination is queried in Presto as `<CATALOG>.<SCHEMA>.<TABLE>`. The sink can create a missing namespace/table when the catalog permits it. For an explicit storage location, create the schema first in watsonx.data's Query workspace, replacing the placeholders:

```sql
CREATE SCHEMA IF NOT EXISTS <CATALOG>.<SCHEMA>
WITH (location = 's3a://<COS_BUCKET_NAME>/<WAREHOUSE_PREFIX>/<SCHEMA>');
```

If the schema already exists, confirm its location points to the intended external bucket and prefix.

| Setting | Value | Meaning |
|---|---|---|
| `tasks.max` | `1` | One task for the initial setup |
| `iceberg.tables.auto-create-enabled` | `true` | Creates the destination table from the incoming record schema; overrides the connector default of `false` |
| `iceberg.tables.evolve-schema-enabled` | `false` | Connector default; enable explicitly to add new columns automatically |
| `iceberg.tables.dynamic-enabled` | `false` | All records go to the named table |
| `iceberg.tables.schema-force-optional` | `false` | Preserves required/optional fields from the Avro schema |
| `iceberg.tables.schema-case-insensitive` | `false` | Case-sensitive field matching |
| `iceberg.tables.auto-create-props.write.format.default` | `parquet` | Default file format for new tables |
| `iceberg.control.topic` | `control-iceberg` | Default commit coordination topic; if broker auto-creation is disabled, create it with one partition |
| `iceberg.control.group-id-prefix` | `cg-control-` | Default prefix for the connector's control consumer groups |
| `iceberg.control.commit.interval-ms` | `300000` | Default five-minute commit interval; lower it, for example to `60000`, for a quicker demo |
| `iceberg.control.commit.timeout-ms` | `30000` | Default 30-second commit timeout |

New records become visible to Presto after a successful Iceberg commit. Kafka bootstrap/security settings for the control topic are inherited from the worker when available. This deployment already configures the worker; do not copy Confluent Cloud API keys into this on-cluster profile.

The connector consumes continuously; the five-minute interval controls commits. Kafka offsets track progress across normal restarts. A new connector with no saved offsets defaults to the earliest retained records, subject to worker or connector consumer overrides. This profile appends incoming records: publishing the same record twice produces two rows, and records are not deduplicated by their contents or a business key. See the [Kafka Connect consumer defaults](https://github.com/apache/kafka/blob/4.0.0/connect/runtime/src/main/java/org/apache/kafka/connect/runtime/Worker.java#L893-L909) and [Apache Iceberg connector documentation](https://iceberg.apache.org/docs/1.9.2/kafka-connect/).

## Upload and verify

1. Replace every placeholder and review the environment values in the local copy.
2. In Control Center, open **Kafka cluster > Connect > connect-default > Upload connector config file**.
3. Choose the edited local JSON. If the upload action is on the connector browser, open **Add connector** first.
4. Review the populated configuration and launch the connector.
5. Check that both the connector and its task are running. After the first commit, open **watsonx.data > SQL > Query workspace**, select the associated Presto engine, and run:

   ```sql
   SELECT * FROM <CATALOG>.<SCHEMA>.<TABLE> LIMIT 10;
   ```

COS contains the underlying Parquet and metadata files; the SQL workspace reads the committed Iceberg table. See IBM's [SQL query instructions](https://www.ibm.com/docs/en/watsonxdata/premium/2.4.x?topic=data-running-sql-queries).

This flat JSON is the Control Center upload format. The Kafka Connect `POST /connectors` REST API uses a different envelope: `{"name": "...", "config": {...}}`. See [Control Center upload instructions](https://docs.confluent.io/control-center/current/connect.html#upload-a-connector-configuration-file-to-add-a-connector).

For a plain JSON comparison topic, copy the profile and change `name`, `topics`, and `iceberg.tables` to distinct values. Set `value.converter` to `org.apache.kafka.connect.json.JsonConverter`, add `value.converter.schemas.enable` with value `false`, and remove `value.converter.schema.registry.url`. This JSON setting assumes raw JSON objects without the Kafka Connect `schema`/`payload` envelope. Keep the destination separate so the same source data is not ingested twice into the Avro table. See [Apache Iceberg connector documentation](https://iceberg.apache.org/docs/1.9.2/kafka-connect/).
