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
instance creation are separate steps. The preparation helper automates only the
SQL preparation and its checks.

## 1. Provision the database

Provision an unused, dedicated Db2 database through Services -> Instances, or use
the repository's service-instance tooling after reviewing its generated payload.
Installing the Db2 service alone does not create a database instance.

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

The helper uses your current `oc` login and local Db2 administrator access inside
the selected pod. It reads no passwords or Kubernetes Secrets. It does not load
`env_bootstrap.sh`, run login commands from config files, or start Podman. Pass
the namespace explicitly, or export `PROJECT_CPD_INST_OPERANDS` beforehand.

```sh
./scripts/install_cloud_pak_for_data/5_component_specific_scripts/cp4d_databases/5_prep_cognos_content_store.sh \
  --check --namespace database-ns --instance db2-deployment \
  --database BLUDB --user cognos_svc
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
