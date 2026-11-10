# Cognos Analytics with a Db2 content store

Cognos needs a content-store database in addition to its installed Software Hub
service. This guide covers a Db2 instance on the same OpenShift cluster, a
Software Hub platform connection, database preparation, and instance readiness.
The database can also store audit content. Review the supported database and
storage requirements for your Software Hub release before provisioning.

The procedure was exercised with Cognos service version **30.0.4**, Db2
**12.1.5.0-cn2**, and a UTF-8 database with 32K default pages. Compatibility with
other releases must be checked against their IBM documentation.

## Prerequisites

The Db2 and Cognos Analytics services must already be installed through the
repository's Software Hub component-installation workflow. A service marked
Ready to provision can create an instance; it does not mean an instance or its
backend database already exists.

This guide starts with instance provisioning. Reuse an existing database only
if it is dedicated to this purpose and satisfies the content-store requirements.
Database provisioning, SQL preparation, platform-connection creation and Cognos
instance creation are separate steps. The preparation helper handles SQL preparation and checks. The Cognos CLI provisioner
consumes existing tested platform connections; it does not create connections or
run preparation writes.

## 1. Provision the database

Provision an unused, dedicated Db2 database through Services -> Instances, or use
the repository's service-instance tooling after reviewing its generated payload.
Installing the Db2 service alone does not create a database instance.

For a new database, the Db2 provisioner supports an explicit Cognos profile:

```sh
DB2_PROFILE=cognos DB2_INSTANCE_NAME=db2-cognos-new \
DB2_VERSION=12.1.5.0-cn2 \
./scripts/install_cloud_pak_for_data/4.5_service_instance_setups/4.5_provision_db2.sh
```

Choose a Db2 version supported by the installed service. `DB2_VERSION` overrides
this script's existing default (`12.1.3.0-cn3-${IMAGE_ARCH}`); this example version
matches the setup exercised above, not every Software Hub installation.
The script creates a new instance, saves its credentials through the existing
local-file/vault helpers, then waits for Db2 Ready. An existing instance or
payload with the chosen name is rejected. It never resizes existing PVCs.

`DB2_PROFILE=general` (the default) creates 16K default pages. The `cognos`
profile sets `dftPageSize` to **`32768` bytes** and `codeset` to `UTF-8` at
database creation, and adds IBM's recommended `DB2_INLIST_TO_NLJN=YES` registry
setting. It retains the same
resources, authentication and storage layout. UTF-8, initial page sizes and SQL
preparation must still pass the checks below. Creating a 32K buffer pool alone
does not establish a database created with 32K default pages.
IBM's cited checklist specifies 8K/32K pools and temporary tablespaces; the
32K database default is an explicit requirement of this repository's Cognos
profile, not a claim that the checklist mandates it for every Db2 deployment.

The provisioner also sets `DB2_4K_DEVICE_SUPPORT=ON` for both profiles. This is
4K **storage-sector support**, independent of the database's 32K **page size**.
IBM's Db2 storage guidance recommends selecting 4K when the storage supports it,
requires it for Portworx, and supports it with OpenShift Data Foundation. It is
not a separate Cognos-specific page-size requirement and does not reformat the
underlying storage device.

Each volume can be sized separately with positive integer GiB values:

| Environment variable | Volume | Default | Access/class |
| --- | --- | --- | --- |
| `DB2_DATA_STORAGE_GI` | Database data | 30 | RWO/block |
| `DB2_ACTIVELOGS_STORAGE_GI` | Transaction logs | 30 | RWO/block |
| `DB2_TEMPTS_STORAGE_GI` | Temporary tablespaces | 30 | RWO/file |
| `DB2_META_STORAGE_GI` | System metadata | 30 | RWX/file |
| `DB2_BACKUP_STORAGE_GI` | Backups | 30 | RWX/file |
| `DB2_ARCHIVELOGS_STORAGE_GI` | Archive logs | 30 | RWX/file |

Unset volume settings use `DB2_STORAGE_CLAIM`, which defaults to 30 GiB.
Both profiles therefore request **180 GiB** across these six volumes by default;
this is requested PVC capacity, not measured usage or a production sizing
recommendation. IBM's storage topic specifies the volume roles and access modes
but does not establish smaller supported per-volume minimums. No reduced-size
demo preset is supplied. Budget backup space for the expected database size,
number of retained backups, compression and growth; the 30 GiB fallback does not
prove adequate backup retention. Plan archive-log retention separately.

Select resources and storage sizes for your workload. File volumes need a class
supporting the requested ReadWriteMany access; block volumes using ReadWriteOnce
need a compatible block class. Use the actual PVC requirements and storage-class
capabilities rather than relying on a class's name. System, data, backup, archive,
transaction-log and temporary volumes contribute separately to total capacity.

In the Db2 wizard, **Create new storage -> Use storage template** lets you
choose a storage class and size. **Define storage parameters** configures a
volume manually; it is not needed just to select a class and capacity.

Keep database encryption enabled. Choose the database's authentication mode
deliberately; Cognos provisioning must use the same IAM mode as the content
store. Dedicated-node requirements and resource sizing depend on whether the
deployment is production or a demonstration. Follow the release's Db2 guidance.

## 2. Grant instance access and create the connection

Create or select the database connection account, and grant it access through
the Db2 instance's access-management UI. Being a Software Hub administrator does
not by itself establish access to this database instance. Database SQL privileges
are prepared separately in the next step.

Create a **platform connection** in Software Hub's Connections page. This is
separate from registering a catalog or connector in watsonx.data.

| Field | Guidance |
| --- | --- |
| Type | Db2 |
| Host | The Db2 service's internal DNS name, covered by its server certificate |
| Port | The service's TLS port; do not substitute the external NodePort |
| Database | The provisioned database name |
| Credentials | A connection account authorized on the database instance |
| Username and Password Security Mechanism | **Clear text**, as required by the Cognos content-store instructions, with TLS enabled |
| SSL | Enable it and supply the server/CA certificate from the Db2 instance |
| Skip certificate hostname validation | Leave off; correct the hostname or trust configuration if validation fails |
| Optional JDBC/client properties | Leave at defaults unless required by your connection or schema configuration |

Test and save the connection. Internal service DNS avoids binding Cognos to a
particular worker node. Use the service and certificate information published
by the actual instance rather than assuming port numbers or service names.

The database connection account and the account submitting the Cognos wizard
are independent. The provisioning workaround below does not require using
`cpadmin` as the database connection account.

## 3. Prepare the content store

The prep script sources `env_bootstrap.sh` to load the shared configuration,
then runs `OC_LOGIN`, which reuses a valid session for the configured cluster
or logs in when needed. The helper uses local Db2 administrator access inside
the selected pod and reads no database passwords or Kubernetes Secrets. Pass
the namespace explicitly, or use `PROJECT_CPD_INST_OPERANDS` from the loaded
configuration.

```sh
./scripts/install_cloud_pak_for_data/5_component_specific_scripts/cp4d_databases/5_prep_cognos_content_store.sh \
  --check --namespace database-ns --instance db2-deployment \
  --database BLUDB --user cognos_svc --require-32k
```

`--instance` is the Db2 deployment/formation name used as the pod's `app` label,
not the database's display name. If it selects several ready Db2 pods, add
`--pod <name>`. The pod must expose a ready container named `db2u` and permit
switching to the local Db2 administrator (`db2inst1` by default, configurable
with `--db2-os-user`). Other deployment layouts need manual adaptation.

The default mode is `--check`. It queries catalog/configuration metadata and
prints the changes needed. It verifies:

- UTF-8/code page 1208, application heap and lock timeout, including deferred
  values that will take effect after database reactivation.
- The 8K/32K Cognos buffer pools, their sizes, and the expected temporary and
  regular tablespaces with matching page sizes and buffer-pool bindings.
- Ownership of the connection schema and direct database/tablespace grants to
  the selected user. Inherited privileges are not expanded by this check.

`--require-32k` additionally checks that `IBMDEFAULTBP` and the initial
`SYSCATSPACE`, `USERSPACE1` and `TEMPSPACE1` all use 32768-byte pages. These are
runtime checks of the new profile's initial objects, not a query of an editable
database default-page-size setting. An incompatible/missing object stops apply;
the helper cannot convert an existing database's default page size. The flag is
optional for standalone preparation and mandatory in the Cognos CLI provisioner.

SQL identifiers are restricted to ordinary letters, digits and underscores and
are folded to uppercase. Connection usernames containing punctuation need a
separately reviewed manual SQL procedure. `--schema` defaults to that uppercase
authorization ID. If you choose another schema, configure the Cognos connection
to use it; creating a schema does not change the connection's default schema.

Review the printed SQL, then use the same arguments with **`--apply`** before
starting Cognos. The helper creates missing objects, grows undersized fixed
buffer pools and grants only the listed preparation privileges. Matching
objects are kept. A conflicting page size, tablespace binding, schema owner,
automatic buffer-pool size, or unsupported database encoding stops the apply.
If any non-system tables/views exist, an apply that would change the database
is refused; a fully matching database can still be checked or reapplied as a
no-op after Cognos starts.

The default preparation values follow IBM's Software Hub procedure:
APPLHEAPSZ at least 1024, LOCKTIMEOUT 240, two 1000-page Cognos buffer pools and
IBMDEFAULTBP at least 49800 pages. Larger fixed pools/heaps are preserved.
`--bufferpool-pages` and `--default-bufferpool-pages` can increase those pool
targets. Size in bytes depends on each pool's page size; 49800 pages at 32K is
about 1.52 GiB. Review this database-wide allocation before applying it.

The helper checks existing definitions before writing and verifies them again
afterward. CLP stops at the first failed statement. DDL/configuration changes are
not one atomic transaction; following an interruption or error, run `--check`
again to inspect the actual state before retrying.

| Exit | Meaning |
| --- | --- |
| 0 | Catalog/configuration and direct grants match the preparation requirements |
| 1 | Command failure, unsafe target or incompatible/unverifiable configuration |
| 2 | Preparation changes or database reactivation are still needed |

Configuration changes use **DEFERRED**. The helper never forces connections,
deactivates/reactivates a database, or restarts pods. If it reports a pending
value, separately schedule database reactivation with the database administrator
before starting Cognos, then rerun `--check`. A successful check proves declared
configuration/grants; also test the connection with its real account.

## 4. Create Cognos and verify readiness

In the Cognos instance wizard, choose the target namespace, compatible block and
file storage classes, plan size and crypto setting. Choose the tested platform
connection for content storage and the chosen audit database connection. IBM
allows the content-store database to store audit content as well. Leave additional
JDBC properties blank unless your setup needs them. Retest the connection after
database preparation before submitting Create.

Wait for **all three** readiness layers: the Cognos operator's successful custom
resource status, ready application pods, and the platform instance's PROVISIONED
status. Then open the UI and verify provisioner access. Operator Completed/100%
can precede application startup and final initialization.

Use the existing instance manager for status inspection. For CLI troubleshooting,
discover the custom resource and use its instance prefix when selecting pods;
their names can start with `ca` immediately followed by the numeric instance ID.
Inspect status fields and redact credentials when collecting diagnostic logs.

### CLI provisioning

IBM's [Software Hub 5.4 CLI procedure](https://www.ibm.com/docs/en/software-hub/5.4.x?topic=csi-creating-service-instance-cpd-cli-service-instance-create-6)
defines the payload's `cs`/`audit` platform connection names, `csProperty`/
`auditProperty` JDBC properties, `fileStorageClass`, `blockStorageClass`, `fips`
and `planSize`. The provisioner follows its non-SMTP payload. Email/SMTP
configuration is outside this provisioner's scope.

Prerequisites for `--apply`:

- Installed Cognos and Db2 services, a working `cpd-cli` profile with
  `can_provision`, and sufficient resources for the explicitly selected plan.
- An empty target namespace for Cognos: IBM permits only one Cognos instance per
  namespace. Use the operands namespace or an already tethered namespace.
- A dedicated, prepared UTF-8/32K Db2 store and tested content/audit **platform**
  connections. Set the same IAM mode as the content store. Verify the connection
  names refer to the database/account passed for validation; the SQL check does
  not resolve or test platform connection credentials.
- Read access to the installed add-on registry, CRDs, target namespace's Cognos
  CRs and workloads, storage classes and platform service-instance inventory;
  plus Db2 pod exec access for the read-only preparation checks.

Choose the installed Cognos service version explicitly. IBM maps Software Hub
5.4.0 patches 4–6 to `30.0.4`, patches 1–3 to `30.0.1`, and base 5.4.0 to
`30.0.0`. Apply verifies that the installed service advertises the requested
version. Do not pass `5.4.0` as the Cognos service version.

Render a new private payload for local review. Without `--apply` or
`--wait-only` the wrapper loads repository configuration but does not log in,
and the Python helper makes no cluster calls:

```sh
./scripts/install_cloud_pak_for_data/4.5_service_instance_setups/4.5_provision_cognos.sh \
  --name cognos-new --version 30.0.4 --namespace cognos-new-ns \
  --file-class file-storage --block-class block-storage --size small \
  --content-connection cognos-new-store --audit-connection cognos-new-store \
  --output cognos-new-review.json
```

The wrapper writes a bare `--output` file name (or a path starting with
`service_instances/`) into the service-instance folder: `service_instances/`
with multi-cluster management off, or `configs/clusters/<cluster>/service_instances/`
for a cluster with its own folder (see README "Managing several clusters").
Absolute and other relative paths are used as given. This wrapper and
`5_prep_cognos_content_store.sh` both accept `--target-cluster NAME`; with
several target clusters, a bare file name gives each cluster its own payload.

Create with the same reviewed inputs and a **new** output path. This wrapper
loads repository configuration and runs the established `OC_LOGIN` flow. It
uses native `cpd-cli service-instance`, without restarting the management
container:

```sh
./scripts/install_cloud_pak_for_data/4.5_service_instance_setups/4.5_provision_cognos.sh \
  --apply --name cognos-new --version 30.0.4 --namespace cognos-new-ns \
  --size small --content-connection cognos-new-store --audit-connection cognos-new-store \
  --db2-namespace database-ns --db2-instance db2-cognos-new --db2-user cognos_svc \
  --output cognos-new-submitted.json
```

File/block classes default to `STG_CLASS_FILE`/`STG_CLASS_BLOCK`. For tethered
targets, the registry is read from `PROJECT_CPD_INST_OPERANDS`; override it with
`--platform-namespace`. `--db2-namespace` defaults to the Cognos target namespace;
supply the actual Db2 namespace when different. Optional `--db2-pod`,
`--db2-schema` and `--db2-os-user` select the preparation target. The provisioner
only checks preparation: run the separate prep helper with `--apply
--require-32k` first if changes are needed, and schedule any reactivation
separately.

Allowed plans are `small_mincpureq`, `fixedminimum`, `xsmall`, `small`, `medium`
and `large`. These allocate substantial resources; consult IBM's plan table.
Use `--fips` only on a FIPS-enabled cluster. Extra JDBC properties are read from
`COGNOS_CONTENT_CONNECTION_PROPS` and `COGNOS_AUDIT_CONNECTION_PROPS` in the
environment/configuration, not command-line password arguments. Payloads are
created exclusively with mode 0600 and never printed or overwritten. Keep them
in the gitignored service-instance folder (`service_instances/`, or
`configs/clusters/<cluster>/service_instances/` with multi-cluster management
on). Do not commit credentials or payloads containing sensitive JDBC properties.

Apply checks the installed registry, target CR and platform inventories, and
storage-class existence before submitting once. Class capabilities, database
connection tests and IAM compatibility remain operator prerequisites. It refuses
an existing instance rather than replacing it. A timeout or failed submission
never retries create automatically, deletes resources or reruns SQL preparation.
The private payload remains for diagnosis. Inspect the instance and resume
observation by replacing `--apply` with `--wait-only` in the same command;
`--output` and Db2 arguments can be omitted for observation.

A successful wait requires the Cognos CR to be Completed, application replicas
to be healthy, and platform `provision_status` to be PROVISIONED. Waiting is
bounded by `--timeout` (2700 seconds by default). Failure or timeout exits
nonzero; the instance may still finish afterward. It does not establish that
users can log in or execute reports: perform the UI/connection checks above.

### How Db2 settings reach Cognos

This is an explicit dependency workflow. `DB2_PROFILE=cognos` configures the
new database at creation. The Db2 script saves credentials through the existing
instance-details/vault helpers. Grant the connection account access, create/test
the platform connection, and prepare the store separately. Pass that connection's
display name to Cognos with `--content-connection` and `--audit-connection`, and
pass the corresponding Db2 instance/account for read-only validation. Extra JDBC
properties use the two exported `COGNOS_*_CONNECTION_PROPS` variables above.

The scripts share namespace, storage-class and CLI-profile configuration through
the repository bootstrap. They do not automatically discover a new Db2 endpoint,
create a platform connection, or transfer its credentials into Cognos. Cognos
receives platform connection names; the platform supplies their stored connection
properties. A single command that creates and connects the whole dependency
chain is outside this workflow.

### Validation limits

Local tests use mocked cluster and platform operations. They cover payload
fields, profile defaults/overrides, credential file permissions, 32K catalog
checks, existing-instance refusal, submission failures and readiness decisions.
They do not establish a successful live end-to-end creation on every supported
release. Validate a new deployment on deliberately isolated resources before
production use; this workflow does not migrate or change existing instances.

## Cognos 30.0.4 provisioning compatibility

On the tested Cognos 30.0.4 release, submitting provisioning as an externally
authenticated administrator triggered HTTP 500 at `/v1/certificates/inline`.
The artifacts-service stack trace pointed to `authorizeCognosUser`, which parsed
a raw JWT as JSON. Provisioning as built-in `cpadmin` succeeded. Treat this as
an observed release-specific workaround and check for vendor fixes. The
workaround concerns the provisioning identity, not the database connection
account or dashboard viewers' permissions.

If certificate setup fails, inspect the actual HTTP error and artifacts-service
stack trace; the provider's message that the artifacts service is not up can
hide a request-processing failure. Preserve database state during recovery.
Deleting a Cognos instance does not establish that an external content store is
empty. Do not rerun one-time CREATE statements blindly or mark platform status
PROVISIONED manually.

## IBM references

- [Cognos content-store preparation and connections](https://www.ibm.com/docs/en/SSNFH6_5.4.x/svc-cognos/ca-content-store.html)
- [Db2 content-store guidelines](https://www.ibm.com/docs/en/SSEP7J_12.1.0/com.ibm.swg.ba.cognos.inst_cr_winux.doc/c_guidelines_db2_lux_content_store.html)
- [Db2 instance access](https://www.ibm.com/docs/en/SSNFH6_5.4.x/svc-db2/db2-platform-cred.html)
- [Provisioning Cognos](https://www.ibm.com/docs/en/SSNFH6_5.4.x/svc-cognos/ca-instance.html)
- [Db2 storage](https://www.ibm.com/docs/en/SSNFH6_5.4.x/svc-db2/database-storage-aese.html)
- [Db2 12.1 custom resource database settings](https://www.ibm.com/docs/en/db2/12.1.x?topic=warehouse-deploying-db2-using-custom-resource)
- [Software Hub 5.4 Db2 CLI layout](https://www.ibm.com/docs/en/software-hub/5.4.x?topic=instance-creating-service-db2-openshift-command-line)
