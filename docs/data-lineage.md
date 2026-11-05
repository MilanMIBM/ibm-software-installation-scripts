# Data lineage

Software Hub 5.4 / watsonx.data intelligence 2.4.

## IBM products and where they run

| Product | Deployment and prerequisites | Integration coverage | Repository support |
| --- | --- | --- | --- |
| **IBM Manta Data Lineage** (`datalineage`), including the lineage capability used through watsonx.data intelligence | Software Hub service on OpenShift. | Database, ETL and BI integrations listed in the release-specific lineage-import matrix; OpenLineage ingestion for metadata supplied by compatible producers. | Component selection and shared Software Hub installer. Source-specific capture still needs configuration. |
| **MANTA Automated Data Lineage for IBM Cloud Pak for Data** (`mantaflow`) | Separate Software Hub/OpenShift service requiring Knowledge Catalog and the appropriate entitlement. | Its own Knowledge Catalog lineage-import connector list. Scanner coverage differs between products. | Component selection and shared Software Hub installer, including handling of Manta credential/key prerequisites. |
| **IBM Automatic Data Lineage**, standalone distribution | Separate host/VM installation. Published requirements exclude deploying this standalone distribution as containers on OpenShift. | Its own scanner documentation, with technology, version and operation restrictions. | No standalone installation track. |

Sources: [`datalineage` connectors][current-connectors], [`mantaflow` connectors][mantaflow-connectors], [`mantaflow` installation][mantaflow-install], [standalone requirements][standalone-requirements].

## Repository support

The component definitions in [cp4d_id_options_templates.py](../src/helpers/cp4d_id_options_templates.py) include both `datalineage` and `mantaflow`.

[4.1_install_components.sh](../scripts/install_cloud_pak_for_data/4_install_components/4.1_install_components.sh) calls IBM's `cpd-cli manage install-components`. It supports `--components=<comma-separated list>` to limit an invocation to selected components. For `mantaflow`, it checks for `manta-credentials` and `manta-keys`, and defers that component while other selected services install if those secrets are absent. A deferred installation can be skipped or fail with a warning.

IBM's documented `mantaflow` installation requires Knowledge Catalog, release alignment, suitable storage and entitlement. Installation and post-install enablement do not establish scanner coverage. See [installation][mantaflow-install] and [metadata-import requirements][mantaflow-import].

## Settings and imports

| Setting or action | Meaning and limit |
| --- | --- |
| Data source definition (DSD) | A stable identity for a source and its endpoints. Matching connections can be associated automatically. Association does not run a lineage scanner. |
| Platform assets catalog in lineage setup | DSDs are stored in this shared catalog by default. Its presence does not restrict the graph to business assets published in that catalog. |
| **Import asset metadata** | Creates/updates catalog or project assets. Success does not mean lineage was imported. |
| **Import lineage metadata** | Populates the lineage repository using a supported scanner or supplied lineage inputs. A connection and DSD alone are insufficient for sources without a configured capture mechanism. |
| **Lineage for unstructured data** | Applies to Unstructured Data Integration/Curation flows. It does not enable capture for other ingestion flows. |
| watsonx.data **Configurations -> IBM Manta Data Lineage** | Connects watsonx.data's lineage producer to the receiving service. The documented integration covers new Spark/Presto jobs after enablement, with CTAS and INSERT INTO SELECT operations. |
| **Native / external endpoint** | The receiving lineage service. Native uses the co-deployed service; external specifies another endpoint. |

Sources: [DSD identity][dsd-overview], [DSD storage][dsd-create], [asset versus lineage metadata][metadata-import], [unstructured lineage][unstructured-lineage], [watsonx.data integration][watsonx-integration].

## OpenLineage integration

OpenLineage is a metadata interchange specification. A producer supplies jobs and their inputs/outputs, with mappings to the corresponding assets.

File import uses **Import lineage metadata**, an **OpenLineage** data source definition and a ZIP containing OpenLineage JSON events. The predefined generic definition is available from 2.4 Patch 4; earlier patches require creating one. Runtime events can also be submitted through an authenticated API. A ZIP supplies a snapshot; ongoing tracking needs recurring collection or event emission. See [OpenLineage integration][openlineage] and [identity mapping][openlineage-tutorial].

## StreamSets, Kafka and Iceberg

The following limits apply to an HTTP Client origin in StreamSets Data Collector 7.7.0, Kafka Producer destination and Apache Iceberg Kafka Connect sink.

The `datalineage` [2.4 lineage-import matrix][current-connectors] does not list dedicated Kafka, StreamSets or Iceberg scanners. The `mantaflow` [Knowledge Catalog import list][mantaflow-connectors] also omits Kafka and StreamSets. Whether the latter exposes additional scanners through another supported interface remains unresolved.

The standalone [Kafka scanner][kafka-scanner] extracts topic/schema metadata from Confluent Schema Registry and documents integration with its StreamSets scanner. Schema discovery does not by itself establish the Kafka Connect sink's destination relationship or prove data delivery.

The standalone [StreamSets requirements][streamsets-requirements] document:

- Testing against Data Collector **3.10.1**; other versions greater than 3.0.0 are described as untested, including **7.7.0**.
- **Kafka Producer** as a supported destination, alongside processors such as Expression Evaluator, Field Remover, Stream Selector and Field Pivoter.
- **HTTP Client as a destination**, not as a listed source. Unlisted stages receive default visualization without data-flow analysis.

Native analysis of the **Apache Iceberg Kafka Connect sink** relationship is unconfirmed for these IBM products. The repository's ingestion scripts do not configure end-to-end lineage capture.

[DataHub's Kafka Connect connector](https://docs.datahub.com/docs/generated/ingestion/sources/kafka-connect) explicitly lists `org.apache.iceberg.connect.IcebergSinkConnector` for topic-to-table lineage. Its reviewed source list has no native StreamSets connector. DataHub is not installed or validated on OpenShift by this repository.

[current-connectors]: https://www.ibm.com/docs/en/SSRNZNM_2.4.x/wsj/lineage/connections-lineage.html
[mantaflow-connectors]: https://www.ibm.com/docs/en/SSQNUZ_5.4.x/wsj/governance/connections-manta-automated-data-lineage.html
[mantaflow-install]: https://www.ibm.com/docs/en/SSNFH6_5.4.x/svc-manta/manta-install.html
[mantaflow-import]: https://www.ibm.com/docs/en/SSQNUZ_5.4.x/wsj/manage-data/mdi-manta-automated-data-lineage.html
[standalone-requirements]: https://www.ibm.com/docs/en/SSFQYQB/topics/manta-technical-requirements.html
[dsd-overview]: https://www.ibm.com/docs/en/SSRNZNM_2.4.x/wsj/manage-data/dsd-overview.html
[dsd-create]: https://www.ibm.com/docs/en/SSRNZNM_2.4.x/wsj/manage-data/dsd-wizard.html
[metadata-import]: https://www.ibm.com/docs/en/SSRNZNM_2.4.x/wsj/manage-data/metadata-import.html
[unstructured-lineage]: https://www.ibm.com/docs/en/SSRNZNM_2.4.x/wsj/lineage/ud-lineage.html
[watsonx-integration]: https://www.ibm.com/docs/en/SSK0MP_2.4.x/lh-console/topics/integrate_manta.html
[openlineage]: https://www.ibm.com/docs/en/SSRNZNM_2.4.x/wsj/lineage/openlineage-integration.html
[openlineage-tutorial]: https://www.ibm.com/docs/en/SSRNZNM_2.4.x/wsj/lineage/openlineage-tutorial.html
[kafka-scanner]: https://www.ibm.com/docs/en/SSFQYQB/topics/apache-kafka.html
[streamsets-requirements]: https://www.ibm.com/docs/en/SSFQYQB/topics/streamsets-integration-requirements.html
