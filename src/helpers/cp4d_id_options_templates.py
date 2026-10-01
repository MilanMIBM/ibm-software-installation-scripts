cp4d_component_id_options = [
    # "ibm-licensing",
    # "cpd_platform",
    # "scheduler",
    # "cpfs",
    "analyticsengine",
    "bigsql",
    "cognos_analytics",
    "dashboard",
    "datagate",
    "datagate_instance",
    "datalineage",
    "dataproduct",
    "datastage_ent",
    "datastage_ent_plus",
    "db2aaservice",
    "db2oltp",
    "db2wh",
    "dmc",
    "dods",
    "dp",
    "dv",
    "edb_cp4d",
    "factsheet",
    "hee",
    "ibm-cert-manager",
    "ibm-databand",
    "ibm-streamsets-sdi",
    "ibm_swhcc",
    "ikc_premium",
    "ikc_standard",
    "informix_cp4d",
    "mantaflow",
    "match360",
    "model_gateway",
    "openpages",
    "openpages_instance",
    "openscale",
    "planning_analytics",
    "productmaster",
    "productmaster_instance",
    "replication",
    "rstudio",
    "spss",
    "streamsets",
    "syntheticdata",
    "udp",
    "voice_gateway",
    "watson_assistant",
    "watson_discovery",
    "watson_speech",
    "watsonx_ai",
    "watsonx_bi_assistant",
    "watsonx_data",
    "watsonx_data_premium",
    "watsonx_dataintegration",
    "watsonx_dataintelligence",
    "watsonx_governance",
    "watsonx_orchestrate",
    "wca",
    "wca_ansible",
    "wca_z",
    "wca_z_agentic",
    "wca_z_ce",
    "wca_z_cg",
    "wca_z_understand",
    "wkc",
    "wml",
    "ws",
    "ws_pipelines",
    "ws_runtimes",
    # Auto-installed dependencies
    "canvasbase",
    # "ccs",
    "data_governor",
    "datarefinery",
    "datastax_mc",
    "db2u",
    "fdb_k8s",
    "ibm-common-service-operator",
    "ibm-iam-operator",
    "ibm-namespace-scope-operator",
    "ibm_events_operator",
    "ibm_neo4j",
    "ibm_redis_cp",
    "ibm_usage_metering",
    "ibm_wxd_opensearch",
    "informix",
    "opencontent_auditwebhook",
    "opencontent_elasticsearch",
    "opencontent_etcd",
    "opencontent_fdb",
    "opencontent_minio",
    "opencontent_opensearch",
    "opencontent_rabbitmq",
    "opencontent_redis",
    "postgresql",
    "semantic_automation",
    "wca_base",
    "watson_gateway",
    "watsonx_ai_ifm",
    "wxd_query_optimizer",
    # "zen",
]

cp4d_component_id_records = [
    # {"component_name": "IBM Licensing Operators", "component_id": "ibm-licensing"},
    # {"component_name": "CPD Scheduler", "component_id": "scheduler"},
    # {
    #     "component_name": "Cloud Pak for Data Control Plane",
    #     "component_id": "cpd_platform",
    # },
    # {"component_name": "Cloud Pak Foundational Services", "component_id": "cpfs"},
    {
        "component_name": "Analytics Engine Powered by Apache Spark",
        "component_id": "analyticsengine",
    },
    {"component_name": "Db2 Big SQL", "component_id": "bigsql"},
    {"component_name": "Cognos Analytics", "component_id": "cognos_analytics"},
    {"component_name": "IBM Cognos Dashboards", "component_id": "dashboard"},
    {"component_name": "Data Gate", "component_id": "datagate"},
    {"component_name": "Data Gate Instance", "component_id": "datagate_instance"},
    {"component_name": "IBM Datalineage", "component_id": "datalineage"},
    {"component_name": "Data Product Hub", "component_id": "dataproduct"},
    {"component_name": "DataStage Enterprise", "component_id": "datastage_ent"},
    {
        "component_name": "DataStage Enterprise Plus",
        "component_id": "datastage_ent_plus",
    },
    {"component_name": "CPD Db2 AAS Component", "component_id": "db2aaservice"},
    {"component_name": "Db2", "component_id": "db2oltp"},
    {"component_name": "Db2 Warehouse", "component_id": "db2wh"},
    {"component_name": "Data Management Console", "component_id": "dmc"},
    {"component_name": "Decision Optimization", "component_id": "dods"},
    {"component_name": "Data Privacy", "component_id": "dp"},
    {"component_name": "Data Virtualization", "component_id": "dv"},
    {"component_name": "EnterpriseDB Postgres", "component_id": "edb_cp4d"},
    {"component_name": "Factsheet", "component_id": "factsheet"},
    {"component_name": "Execution Engine for Apache Hadoop", "component_id": "hee"},
    {"component_name": "IBM Cert Manager Operator", "component_id": "ibm-cert-manager"},
    {"component_name": "Databand", "component_id": "ibm-databand"},
    {
        "component_name": "StreamSets WatsonX Data Integration",
        "component_id": "ibm-streamsets-sdi",
    },
    {"component_name": "IBM Software Hub Control Center", "component_id": "ibm_swhcc"},
    {"component_name": "IBM Knowledge Catalog Premium", "component_id": "ikc_premium"},
    {
        "component_name": "IBM Knowledge Catalog Standard",
        "component_id": "ikc_standard",
    },
    {"component_name": "Informix", "component_id": "informix_cp4d"},
    {"component_name": "MANTA Automated Data Lineage", "component_id": "mantaflow"},
    {"component_name": "Match 360 with Watson", "component_id": "match360"},
    {"component_name": "Model Gateway", "component_id": "model_gateway"},
    {"component_name": "OpenPages", "component_id": "openpages"},
    {"component_name": "OpenPages Instance", "component_id": "openpages_instance"},
    {"component_name": "Watson OpenScale", "component_id": "openscale"},
    {"component_name": "Planning Analytics", "component_id": "planning_analytics"},
    {"component_name": "Product Master", "component_id": "productmaster"},
    {
        "component_name": "Product Master Instance",
        "component_id": "productmaster_instance",
    },
    {"component_name": "Data Replication on Cloud", "component_id": "replication"},
    {"component_name": "RStudio Server", "component_id": "rstudio"},
    {"component_name": "SPSS Modeler", "component_id": "spss"},
    {"component_name": "StreamSets", "component_id": "streamsets"},
    {"component_name": "Synthetic Data Generator", "component_id": "syntheticdata"},
    {
        "component_name": "IBM Data Integration for Unstructured Data",
        "component_id": "udp",
    },
    {"component_name": "Voice Gateway", "component_id": "voice_gateway"},
    {"component_name": "Watson Assistant", "component_id": "watson_assistant"},
    {"component_name": "Watson Discovery", "component_id": "watson_discovery"},
    {
        "component_name": "Watson Speech to Text / Text to Speech",
        "component_id": "watson_speech",
    },
    {"component_name": "IBM watsonx.ai", "component_id": "watsonx_ai"},
    {
        "component_name": "IBM watsonx BI Assistant",
        "component_id": "watsonx_bi_assistant",
    },
    {"component_name": "IBM watsonx.data", "component_id": "watsonx_data"},
    {
        "component_name": "IBM watsonx.data Premium",
        "component_id": "watsonx_data_premium",
    },
    {
        "component_name": "IBM watsonx.data integration",
        "component_id": "watsonx_dataintegration",
    },
    {
        "component_name": "IBM watsonx.data Intelligence",
        "component_id": "watsonx_dataintelligence",
    },
    {"component_name": "IBM watsonx Governance", "component_id": "watsonx_governance"},
    {"component_name": "watsonx Orchestrate", "component_id": "watsonx_orchestrate"},
    {"component_name": "watsonx Code Assistant", "component_id": "wca"},
    {
        "component_name": "watsonx Code Assistant for Ansible",
        "component_id": "wca_ansible",
    },
    {"component_name": "watsonx Code Assistant for Z", "component_id": "wca_z"},
    {
        "component_name": "watsonx Code Assistant for Z Agents",
        "component_id": "wca_z_agentic",
    },
    {
        "component_name": "watsonx Code Assistant for Z Code Explanation",
        "component_id": "wca_z_ce",
    },
    {
        "component_name": "watsonx Code Assistant for Z Code Generation",
        "component_id": "wca_z_cg",
    },
    {
        "component_name": "watsonx Code Assistant for Z Understand",
        "component_id": "wca_z_understand",
    },
    {"component_name": "Watson Knowledge Catalog", "component_id": "wkc"},
    {"component_name": "Watson Machine Learning", "component_id": "wml"},
    {"component_name": "Watson Studio", "component_id": "ws"},
    {
        "component_name": "Orchestration Pipelines (watsonx.ai)",
        "component_id": "ws_pipelines",
    },
    {"component_name": "Watson Studio Runtimes", "component_id": "ws_runtimes"},
    # Auto-installed dependencies
    {"component_name": "Canvas Base", "component_id": "canvasbase"},
    # {"component_name": "Common Core Services", "component_id": "ccs"},
    {
        "component_name": "IBM Cloud Pak for Data Governor",
        "component_id": "data_governor",
    },
    {"component_name": "Data Refinery", "component_id": "datarefinery"},
    {
        "component_name": "DataStax Mission Control (enables wx.data DataStax deployment)",
        "component_id": "datastax_mc",
    },
    {"component_name": "IBM Db2u", "component_id": "db2u"},
    {"component_name": "FoundationDB Kubernetes", "component_id": "fdb_k8s"},
    {
        "component_name": "IBM Common Service Operator",
        "component_id": "ibm-common-service-operator",
    },
    {"component_name": "IBM IAM Operator", "component_id": "ibm-iam-operator"},
    {
        "component_name": "IBM Namespace Scope Operator",
        "component_id": "ibm-namespace-scope-operator",
    },
    {"component_name": "IBM Events Operator", "component_id": "ibm_events_operator"},
    {"component_name": "Neo4j", "component_id": "ibm_neo4j"},
    {"component_name": "IBM Redis CP Operator", "component_id": "ibm_redis_cp"},
    {"component_name": "IBM Usage Metering", "component_id": "ibm_usage_metering"},
    {
        "component_name": "watsonx.data OpenSearch (enables wx.data OpenSearch deployment)",
        "component_id": "ibm_wxd_opensearch",
    },
    {"component_name": "Informix Operator", "component_id": "informix"},
    {
        "component_name": "OpenContent Audit Webhook",
        "component_id": "opencontent_auditwebhook",
    },
    {
        "component_name": "OpenContent Elasticsearch",
        "component_id": "opencontent_elasticsearch",
    },
    {"component_name": "IBM etcd Operator", "component_id": "opencontent_etcd"},
    {
        "component_name": "IBM OpenContent FoundationDB",
        "component_id": "opencontent_fdb",
    },
    {"component_name": "OpenContent MinIO", "component_id": "opencontent_minio"},
    {"component_name": "CloudPak OpenSearch", "component_id": "opencontent_opensearch"},
    {"component_name": "OpenContent RabbitMQ", "component_id": "opencontent_rabbitmq"},
    {"component_name": "OpenContent Redis", "component_id": "opencontent_redis"},
    {"component_name": "Cloud Native PostgreSQL", "component_id": "postgresql"},
    {
        "component_name": "IBM Knowledge Catalog Semantic Automation",
        "component_id": "semantic_automation",
    },
    {"component_name": "IBM Watson Gateway Operator", "component_id": "watson_gateway"},
    {
        "component_name": "IBM watsonx.ai Inference for Foundation Models",
        "component_id": "watsonx_ai_ifm",
    },
    {
        "component_name": "IBM watsonx.data query optimizer",
        "component_id": "wxd_query_optimizer",
    },
    # {"component_name": "Zen Service", "component_id": "zen"},
]

cp4d_license_entitlement_id_options = [
    "cpd-enterprise",
    "cognos-analytics",
    "data-integration-unstructured-data",
    "data-lineage",
    "data-lineage-reserved",
    "data-product-hub",
    "datastage",
    "datastage-plus",
    "ikc-premium",
    "ikc-standard",
    "openpages",
    "planning-analytics",
    "product-master",
    "speech-to-text",
    "text-to-speech",
    "watson-assistant",
    "watson-discovery",
    "watsonx-ai",
    "watsonx-bi-premium",
    "watsonx-bi-premium-ca",
    "watsonx-bi-premium-ca-vpc",
    "watsonx-bi-premium-vpc",
    "watsonx-code-assistant",
    "watsonx-code-assistant-ansible",
    "watsonx-code-assistant-z",
    "watsonx-data",
    "watsonx-data-premium",
    "watsonx-data-premium-reserved",
    "watsonx-data-reserved",
    "watsonx-dataintegration",
    "watsonx-dataintegration-reserved",
    "watsonx-dataintelligence",
    "watsonx-dataintelligence-reserved",
    "watsonx-dataintelligence-reserved-vpc",
    "watsonx-dataintelligence-transition",
    "watsonx-dataintelligence-transition-reserved",
    "watsonx-dataintelligence-transition-reserved-vpc",
    "watsonx-dataintelligence-transition-vpc",
    "watsonx-dataintelligence-vpc",
    "watsonx-gov-mm",
    "watsonx-gov-rc",
    "watsonx-orchestrate",
    "watsonx-orchestrate-with-assistant",
]

cp4d_license_entitlement_id_records = [
    {
        "license_name": "IBM Cloud Pak for Data Enterprise Edition",
        "license_id": "cpd-enterprise",
    },
    {"license_name": "IBM Cognos Analytics", "license_id": "cognos-analytics"},
    {
        "license_name": "IBM Data Integration for Unstructured Data",
        "license_id": "data-integration-unstructured-data",
    },
    {"license_name": "IBM Manta Data Lineage Cartridge", "license_id": "data-lineage"},
    {
        "license_name": "IBM Manta Data Lineage Software Reserved",
        "license_id": "data-lineage-reserved",
    },
    {
        "license_name": "IBM Data Product Hub Cartridge",
        "license_id": "data-product-hub",
    },
    {"license_name": "IBM DataStage Enterprise Cartridge", "license_id": "datastage"},
    {
        "license_name": "IBM DataStage Enterprise Plus Cartridge",
        "license_id": "datastage-plus",
    },
    {
        "license_name": "IBM Knowledge Catalog Premium Cartridge",
        "license_id": "ikc-premium",
    },
    {
        "license_name": "IBM Knowledge Catalog Standard Cartridge",
        "license_id": "ikc-standard",
    },
    {"license_name": "IBM OpenPages Cartridge", "license_id": "openpages"},
    {
        "license_name": "IBM Planning Analytics Cartridge",
        "license_id": "planning-analytics",
    },
    {"license_name": "IBM Product Master Cartridge", "license_id": "product-master"},
    {
        "license_name": "IBM Watson Speech to Text Cartridge",
        "license_id": "speech-to-text",
    },
    {
        "license_name": "IBM Watson Text to Speech Cartridge",
        "license_id": "text-to-speech",
    },
    {
        "license_name": "IBM watsonx Assistant Cartridge",
        "license_id": "watson-assistant",
    },
    {
        "license_name": "IBM Watson Discovery Cartridge",
        "license_id": "watson-discovery",
    },
    {"license_name": "IBM watsonx.ai", "license_id": "watsonx-ai"},
    {"license_name": "IBM watsonx BI Premium", "license_id": "watsonx-bi-premium"},
    {
        "license_name": "IBM watsonx BI Premium CA",
        "license_id": "watsonx-bi-premium-ca",
    },
    {
        "license_name": "IBM watsonx BI Premium CA VPC",
        "license_id": "watsonx-bi-premium-ca-vpc",
    },
    {
        "license_name": "IBM watsonx BI Premium VPC",
        "license_id": "watsonx-bi-premium-vpc",
    },
    {
        "license_name": "IBM watsonx Code Assistant",
        "license_id": "watsonx-code-assistant",
    },
    {
        "license_name": "IBM watsonx Code Assistant for Ansible",
        "license_id": "watsonx-code-assistant-ansible",
    },
    {
        "license_name": "IBM watsonx Code Assistant for Z",
        "license_id": "watsonx-code-assistant-z",
    },
    {"license_name": "IBM watsonx.data", "license_id": "watsonx-data"},
    {
        "license_name": "IBM watsonx.data Premium Edition",
        "license_id": "watsonx-data-premium",
    },
    {
        "license_name": "IBM watsonx.data Premium Edition Reserved",
        "license_id": "watsonx-data-premium-reserved",
    },
    {
        "license_name": "IBM watsonx.data Reserved",
        "license_id": "watsonx-data-reserved",
    },
    {
        "license_name": "IBM watsonx.data integration",
        "license_id": "watsonx-dataintegration",
    },
    {
        "license_name": "IBM watsonx.data integration Reserved",
        "license_id": "watsonx-dataintegration-reserved",
    },
    {
        "license_name": "IBM watsonx.data intelligence",
        "license_id": "watsonx-dataintelligence",
    },
    {
        "license_name": "IBM watsonx.data intelligence Reserved",
        "license_id": "watsonx-dataintelligence-reserved",
    },
    {
        "license_name": "IBM watsonx.data intelligence Reserved VPC",
        "license_id": "watsonx-dataintelligence-reserved-vpc",
    },
    {
        "license_name": "IBM watsonx.data intelligence Transition",
        "license_id": "watsonx-dataintelligence-transition",
    },
    {
        "license_name": "IBM watsonx.data intelligence Transition Reserved",
        "license_id": "watsonx-dataintelligence-transition-reserved",
    },
    {
        "license_name": "IBM watsonx.data intelligence Transition Reserved VPC",
        "license_id": "watsonx-dataintelligence-transition-reserved-vpc",
    },
    {
        "license_name": "IBM watsonx.data intelligence Transition VPC",
        "license_id": "watsonx-dataintelligence-transition-vpc",
    },
    {
        "license_name": "IBM watsonx.data intelligence VPC",
        "license_id": "watsonx-dataintelligence-vpc",
    },
    {
        "license_name": "IBM watsonx.governance Model Management",
        "license_id": "watsonx-gov-mm",
    },
    {
        "license_name": "IBM watsonx.governance Risk and Compliance Foundation",
        "license_id": "watsonx-gov-rc",
    },
    {
        "license_name": "IBM watsonx Orchestrate On-Prem",
        "license_id": "watsonx-orchestrate",
    },
    {
        "license_name": "IBM watsonx Orchestrate On-Prem for Voice Interaction",
        "license_id": "watsonx-orchestrate-with-assistant",
    },
]

cpd_enterprise_supported_components = [
    # AI services
    {"component_name": "Factsheet", "component_id": "factsheet"},
    {"component_name": "Match 360 with Watson", "component_id": "match360"},
    {"component_name": "Watson Machine Learning", "component_id": "wml"},
    {"component_name": "Watson OpenScale", "component_id": "openscale"},
    {"component_name": "Watson Studio Pipelines", "component_id": "ws_pipelines"},
    {"component_name": "Watson Studio", "component_id": "ws"},
    # Analytics services
    {
        "component_name": "Analytics Engine Powered by Apache Spark",
        "component_id": "analyticsengine",
    },
    {"component_name": "IBM Cognos Dashboards", "component_id": "dashboard"},
    {"component_name": "Data Refinery", "component_id": "datarefinery"},
    {"component_name": "Db2 Big SQL", "component_id": "bigsql"},
    {"component_name": "Decision Optimization", "component_id": "dods"},
    {"component_name": "Execution Engine for Apache Hadoop", "component_id": "hee"},
    {"component_name": "SPSS Modeler", "component_id": "spss"},
    # Data governance services
    {"component_name": "Data Privacy", "component_id": "dp"},
    {"component_name": "Watson Knowledge Catalog", "component_id": "wkc"},
    {"component_name": "MANTA Automated Data Lineage", "component_id": "mantaflow"},
    # Data source services
    {"component_name": "Data Gate", "component_id": "datagate"},
    {"component_name": "Data Virtualization", "component_id": "dv"},
    {"component_name": "Db2 Warehouse", "component_id": "db2wh"},
    # Developer tool services
    {"component_name": "RStudio Server", "component_id": "rstudio"},
    {"component_name": "Watson Studio Runtimes", "component_id": "ws_runtimes"},
]

image_group_ids = [
    # IBM Knowledge Catalog
    # "ibmwxGranite38BInstruct",  # listed under watsonx.ai Foundation Models
    # Orchestration Pipelines
    "ibmwsprbsnossh",
    # Watson Machine Learning
    "ibmwmlRuntimes251",
    # Watson Speech to Text
    # "ibmwxMistralSmall3124BInstruct2503",  # listed under watsonx.ai Foundation Models
    "ibmwatsonspeech-stt-nl",
    "ibmwatsonspeech-stt-en",
    "ibmwatsonspeech-stt-fr",
    "ibmwatsonspeech-stt-de",
    "ibmwatsonspeech-stt-it",
    "ibmwatsonspeech-stt-ja",
    "ibmwatsonspeech-stt-ko",
    "ibmwatsonspeech-stt-pt",
    "ibmwatsonspeech-stt-es",
    "ibmwatsonspeech-stt-misc",
    # Watson Text to Speech
    "ibmwatsonspeech-tts-en",
    "ibmwatsonspeech-tts-fr",
    "ibmwatsonspeech-tts-de",
    "ibmwatsonspeech-tts-es",
    "ibmwatsonspeech-tts-misc",
    # watsonx.ai Foundation Models
    "ibmwxAllam113bInstruct",
    "ibmwxCodestral2501",
    "ibmwxCodestral2508",
    "ibmwxCodestral22B",
    "ibmwxDevstralMedium2507",
    "ibmwxDevstralMedium2512",
    "ibmwxDevstralSmall2512",
    "ibmwxGoogleFlanT5xl",
    "ibmwxGptOss20B",
    "ibmwxGptOss120B",
    "ibmwxGranite4HMicro",
    "ibmwxGranite4HSmall",
    "ibmwxGranite4HTiny",
    "ibmwxGranite13bInstructv2",
    "ibmwxGranite338BInstruct",
    "ibmwxGranite328BInstruct",
    "ibmwxGranite32BInstruct",
    "ibmwxGranite38BInstruct",
    "ibmwxGraniteDocling258M",
    "ibmwxGraniteGuardian32b",
    "ibmwxGraniteGuardian38b",
    "ibmwxGraniteGuardian325b",
    "ibmwxGranite3bCodeInstruct",
    "ibmwxGranite8bCodeInstruct",
    "ibmwxGranite20bCodeInstruct",
    "ibmwxGranite20bCodeBaseSchemaLinking",
    "ibmwxGranite20bCodeBaseSqlGen",
    "ibmwxGranite34bCodeInstruct",
    "ibmwxGraniteVision322B",
    "ibmwxDefensemodel",
    "ibmwxIbmDefense40Small",
    "ibmwxCore42Jais13bChat",
    "ibmwxLlama4Maverick17B128EInstructFp8",
    "ibmwxLlama4Maverick17B128EInstructInt4",
    "ibmwxLlama4Scout17B16EInstruct",
    "ibmwxLlama4Scout17b16eInstructInt4",
    "ibmwxLlama3370BInstruct",
    "ibmwxLlama321bInstruct",
    "ibmwxLlama323bInstruct",
    "ibmwxLlama3211bVisionInstruct",
    "ibmwxLlama3290bVisionInstruct",
    "ibmwxLlamaGuard311bVision",
    "ibmwxLlama318bInstruct",
    "ibmwxLlama3170bInstruct",
    "ibmwxLlama3405bInstruct",
    "ibmwxMetaLlamaLlama213bChat",
    "ibmwxMinistral8BInstruct",
    "ibmwxMinistral14BInstruct2512",
    "ibmwxMistralMedium2505",
    "ibmwxMistralSmall3124BInstruct2503",
    "ibmwxMistralSmall3224BInstruct2506",
    "ibmwxMistralSmall24BInstruct2501",
    "ibmwxMistralSmallInstruct",
    "ibmwxMistralLargeInstruct2411",
    "ibmwxMistralLarge2512",
    "ibmwxMistralLarge",
    "ibmwxMistralaiMixtral8x7bInstructv01",
    "ibmwxPixtralLargeInstruct",
    "ibmwxPixtral12b",
    "ibmwxVoxtralSmall24B2507",
    # Embedding Models
    "ibmwxAllMinilmL6V2",
    "ibmwxAllMinilmL12V2",
    "ibmwxGranite107MMultilingualRtrvr",
    "ibmwxGranite278MMultilingualRtrvr",
    "ibmwxGraniteEmbeddingEnglishRerankerR2",
    "ibmwxMultilingualE5Large",
    "ibmwxSlate30mEnglishRtrvr",
    "ibmwxSlate125mEnglishRtrvr",
    # Reranker Models
    "ibmwxMsMarcoMinilmL12V2",
    # Time Series Models
    "ibmwxGraniteTimeseriesTtmV1",
    # Foundation Models for Tuning
    "ibmwxGranite318BBase",
    # "ibmwxLlama318bInstruct",  # listed under watsonx.ai Foundation Models
    # "ibmwxLlama3170bInstruct",  # listed under watsonx.ai Foundation Models
    "ibmwxLlama3170BGptq",
    # watsonx Code Assistant for Z Understand
    "ibmwxMistralMedium2508",
]

image_group_id_records = [
    # Orchestration Pipelines
    {"image_group_name": "run-bash-script", "image_group_id": "ibmwsprbsnossh"},
    # Watson Machine Learning
    {"image_group_name": "wml‑dep‑rt‑251‑py", "image_group_id": "ibmwmlRuntimes251"},
    # Watson Speech to Text
    {
        "image_group_name": "Watson STT - Dutch (nl)",
        "image_group_id": "ibmwatsonspeech-stt-nl",
    },
    {
        "image_group_name": "Watson STT - English (en)",
        "image_group_id": "ibmwatsonspeech-stt-en",
    },
    {
        "image_group_name": "Watson STT - French (fr)",
        "image_group_id": "ibmwatsonspeech-stt-fr",
    },
    {
        "image_group_name": "Watson STT - German (de)",
        "image_group_id": "ibmwatsonspeech-stt-de",
    },
    {
        "image_group_name": "Watson STT - Italian (it)",
        "image_group_id": "ibmwatsonspeech-stt-it",
    },
    {
        "image_group_name": "Watson STT - Japanese (ja)",
        "image_group_id": "ibmwatsonspeech-stt-ja",
    },
    {
        "image_group_name": "Watson STT - Korean (ko)",
        "image_group_id": "ibmwatsonspeech-stt-ko",
    },
    {
        "image_group_name": "Watson STT - Portuguese (pt)",
        "image_group_id": "ibmwatsonspeech-stt-pt",
    },
    {
        "image_group_name": "Watson STT - Spanish (es)",
        "image_group_id": "ibmwatsonspeech-stt-es",
    },
    {
        "image_group_name": "Watson STT - Other languages",
        "image_group_id": "ibmwatsonspeech-stt-misc",
    },
    # Watson Text to Speech
    {
        "image_group_name": "Watson TTS - English (en)",
        "image_group_id": "ibmwatsonspeech-tts-en",
    },
    {
        "image_group_name": "Watson TTS - French (fr)",
        "image_group_id": "ibmwatsonspeech-tts-fr",
    },
    {
        "image_group_name": "Watson TTS - German (de)",
        "image_group_id": "ibmwatsonspeech-tts-de",
    },
    {
        "image_group_name": "Watson TTS - Spanish (es)",
        "image_group_id": "ibmwatsonspeech-tts-es",
    },
    {
        "image_group_name": "Watson TTS - Other languages",
        "image_group_id": "ibmwatsonspeech-tts-misc",
    },
    # watsonx.ai Foundation Models
    {
        "image_group_name": "allam-1-13b-instruct",
        "image_group_id": "ibmwxAllam113bInstruct",
    },
    {"image_group_name": "codestral-2501", "image_group_id": "ibmwxCodestral2501"},
    {"image_group_name": "codestral-2508", "image_group_id": "ibmwxCodestral2508"},
    {"image_group_name": "codestral-22b", "image_group_id": "ibmwxCodestral22B"},
    {
        "image_group_name": "devstral-medium-2507",
        "image_group_id": "ibmwxDevstralMedium2507",
    },
    {
        "image_group_name": "devstral-medium-2512",
        "image_group_id": "ibmwxDevstralMedium2512",
    },
    {
        "image_group_name": "devstral-small-2512",
        "image_group_id": "ibmwxDevstralSmall2512",
    },
    {"image_group_name": "flan-t5-xl-3b", "image_group_id": "ibmwxGoogleFlanT5xl"},
    {"image_group_name": "gpt-oss-20b", "image_group_id": "ibmwxGptOss20B"},
    {"image_group_name": "gpt-oss-120b", "image_group_id": "ibmwxGptOss120B"},
    {"image_group_name": "granite-4-h-micro", "image_group_id": "ibmwxGranite4HMicro"},
    {"image_group_name": "granite-4-h-small", "image_group_id": "ibmwxGranite4HSmall"},
    {"image_group_name": "granite-4-h-tiny", "image_group_id": "ibmwxGranite4HTiny"},
    {
        "image_group_name": "granite-13b-instruct-v2",
        "image_group_id": "ibmwxGranite13bInstructv2",
    },
    {
        "image_group_name": "granite-3-3-8b-instruct",
        "image_group_id": "ibmwxGranite338BInstruct",
    },
    {
        "image_group_name": "granite-3-2-8b-instruct",
        "image_group_id": "ibmwxGranite328BInstruct",
    },
    {
        "image_group_name": "granite-3-2b-instruct",
        "image_group_id": "ibmwxGranite32BInstruct",
    },
    {
        "image_group_name": "granite-3-8b-instruct",
        "image_group_id": "ibmwxGranite38BInstruct",
    },
    {
        "image_group_name": "granite-docling-258M",
        "image_group_id": "ibmwxGraniteDocling258M",
    },
    {
        "image_group_name": "granite-guardian-3-2b",
        "image_group_id": "ibmwxGraniteGuardian32b",
    },
    {
        "image_group_name": "granite-guardian-3-8b",
        "image_group_id": "ibmwxGraniteGuardian38b",
    },
    {
        "image_group_name": "granite-guardian-3-2-5b",
        "image_group_id": "ibmwxGraniteGuardian325b",
    },
    {
        "image_group_name": "granite-3b-code-instruct",
        "image_group_id": "ibmwxGranite3bCodeInstruct",
    },
    {
        "image_group_name": "granite-8b-code-instruct",
        "image_group_id": "ibmwxGranite8bCodeInstruct",
    },
    {
        "image_group_name": "granite-20b-code-instruct",
        "image_group_id": "ibmwxGranite20bCodeInstruct",
    },
    {
        "image_group_name": "granite-20b-code-base-schema-linking",
        "image_group_id": "ibmwxGranite20bCodeBaseSchemaLinking",
    },
    {
        "image_group_name": "granite-20b-code-base-sql-gen",
        "image_group_id": "ibmwxGranite20bCodeBaseSqlGen",
    },
    {
        "image_group_name": "granite-34b-code-instruct",
        "image_group_id": "ibmwxGranite34bCodeInstruct",
    },
    {
        "image_group_name": "granite-vision-3-2-2b",
        "image_group_id": "ibmwxGraniteVision322B",
    },
    {
        "image_group_name": "ibm-defense-3-3-8b-instruct",
        "image_group_id": "ibmwxDefensemodel",
    },
    {
        "image_group_name": "ibm-defense-4-0-small",
        "image_group_id": "ibmwxIbmDefense40Small",
    },
    {"image_group_name": "jais-13b-chat", "image_group_id": "ibmwxCore42Jais13bChat"},
    {
        "image_group_name": "llama-4-maverick-17b-128e-instruct-fp8",
        "image_group_id": "ibmwxLlama4Maverick17B128EInstructFp8",
    },
    {
        "image_group_name": "llama-4-maverick-17b-128e-instruct-int4",
        "image_group_id": "ibmwxLlama4Maverick17B128EInstructInt4",
    },
    {
        "image_group_name": "llama-4-scout-17b-16e-instruct",
        "image_group_id": "ibmwxLlama4Scout17B16EInstruct",
    },
    {
        "image_group_name": "llama-4-scout-17b-16e-instruct-int4",
        "image_group_id": "ibmwxLlama4Scout17b16eInstructInt4",
    },
    {
        "image_group_name": "llama-3-3-70b-instruct",
        "image_group_id": "ibmwxLlama3370BInstruct",
    },
    {
        "image_group_name": "llama-3-2-1b-instruct",
        "image_group_id": "ibmwxLlama321bInstruct",
    },
    {
        "image_group_name": "llama-3-2-3b-instruct",
        "image_group_id": "ibmwxLlama323bInstruct",
    },
    {
        "image_group_name": "llama-3-2-11b-vision-instruct",
        "image_group_id": "ibmwxLlama3211bVisionInstruct",
    },
    {
        "image_group_name": "llama-3-2-90b-vision-instruct",
        "image_group_id": "ibmwxLlama3290bVisionInstruct",
    },
    {
        "image_group_name": "llama-guard-3-11b-vision",
        "image_group_id": "ibmwxLlamaGuard311bVision",
    },
    {
        "image_group_name": "llama-3-1-8b-instruct",
        "image_group_id": "ibmwxLlama318bInstruct",
    },
    {
        "image_group_name": "llama-3-1-70b-instruct",
        "image_group_id": "ibmwxLlama3170bInstruct",
    },
    {
        "image_group_name": "llama-3-405b-instruct",
        "image_group_id": "ibmwxLlama3405bInstruct",
    },
    {
        "image_group_name": "llama-2-13b-chat",
        "image_group_id": "ibmwxMetaLlamaLlama213bChat",
    },
    {
        "image_group_name": "ministral-8b-instruct",
        "image_group_id": "ibmwxMinistral8BInstruct",
    },
    {
        "image_group_name": "ministral-14b-instruct-2512",
        "image_group_id": "ibmwxMinistral14BInstruct2512",
    },
    {
        "image_group_name": "mistral-medium-2505",
        "image_group_id": "ibmwxMistralMedium2505",
    },
    {
        "image_group_name": "mistral-small-3-1-24b-instruct-2503",
        "image_group_id": "ibmwxMistralSmall3124BInstruct2503",
    },
    {
        "image_group_name": "mistral-small-3-2-24b-instruct-2506",
        "image_group_id": "ibmwxMistralSmall3224BInstruct2506",
    },
    {
        "image_group_name": "mistral-small-24b-instruct-2501",
        "image_group_id": "ibmwxMistralSmall24BInstruct2501",
    },
    {
        "image_group_name": "mistral-small-instruct",
        "image_group_id": "ibmwxMistralSmallInstruct",
    },
    {
        "image_group_name": "mistral-large-instruct-2411",
        "image_group_id": "ibmwxMistralLargeInstruct2411",
    },
    {
        "image_group_name": "mistral-large-2512",
        "image_group_id": "ibmwxMistralLarge2512",
    },
    {"image_group_name": "mistral-large", "image_group_id": "ibmwxMistralLarge"},
    {
        "image_group_name": "mixtral-8x7b-instruct-v01",
        "image_group_id": "ibmwxMistralaiMixtral8x7bInstructv01",
    },
    {
        "image_group_name": "pixtral-large-instruct-2411",
        "image_group_id": "ibmwxPixtralLargeInstruct",
    },
    {"image_group_name": "pixtral-12b", "image_group_id": "ibmwxPixtral12b"},
    {
        "image_group_name": "voxtral-small-24b-2507",
        "image_group_id": "ibmwxVoxtralSmall24B2507",
    },
    # Embedding Models
    {"image_group_name": "all-minilm-l6-v2", "image_group_id": "ibmwxAllMinilmL6V2"},
    {"image_group_name": "all-minilm-l12-v2", "image_group_id": "ibmwxAllMinilmL12V2"},
    {
        "image_group_name": "granite-embedding-107m-multilingual",
        "image_group_id": "ibmwxGranite107MMultilingualRtrvr",
    },
    {
        "image_group_name": "granite-embedding-278m-multilingual",
        "image_group_id": "ibmwxGranite278MMultilingualRtrvr",
    },
    {
        "image_group_name": "granite-embedding-english-reranker-r2",
        "image_group_id": "ibmwxGraniteEmbeddingEnglishRerankerR2",
    },
    {
        "image_group_name": "multilingual-e5-large",
        "image_group_id": "ibmwxMultilingualE5Large",
    },
    {
        "image_group_name": "slate-30m-english-rtrvr",
        "image_group_id": "ibmwxSlate30mEnglishRtrvr",
    },
    {
        "image_group_name": "slate-125m-english-rtrvr",
        "image_group_id": "ibmwxSlate125mEnglishRtrvr",
    },
    # Reranker Models
    {
        "image_group_name": "ms-marco-MiniLM-L-12-v2",
        "image_group_id": "ibmwxMsMarcoMinilmL12V2",
    },
    # Time Series Models
    {
        "image_group_name": "granite-ttm-512-96-r2",
        "image_group_id": "ibmwxGraniteTimeseriesTtmV1",
    },
    # Foundation Models for Tuning
    {
        "image_group_name": "granite-3-1-8b-base",
        "image_group_id": "ibmwxGranite318BBase",
    },
    # "ibmwxLlama318bInstruct" - listed under watsonx.ai Foundation Models
    # "ibmwxLlama3170bInstruct" - listed under watsonx.ai Foundation Models
    {"image_group_name": "llama-3-1-70b-gptq", "image_group_id": "ibmwxLlama3170BGptq"},
    # watsonx Code Assistant for Z Understand
    {
        "image_group_name": "mistral-medium-2508",
        "image_group_id": "ibmwxMistralMedium2508",
    },
]

prerequisite_operators = {
    "redhat_openshift_ai_operator": {
        "name": "rhods-operator",
        "namespace": "redhat-ods-operator",
        "channel_version": "stable-2.25.1",
        "required_by": [
            "ikc_premium",
            "ikc_standard",
            "watson_speech",
            "watson_assistant",
            "watsonx_ai",
            "watsonx_bi_assistant",
            "watsonx_data_premium",
            "watsonx_dataintelligence",
            "watsonx_orchestrate",
            "wca",
            "wca_ansible",
            "wca_z",
            "wca_z_agentic",
            "wca_z_ce",
            "wca_z_cg",
        ],
    },
    "node_feature_discovery_operator": {
        "name": "openshift-nfd",
        "namespace": "openshift-nfd",
        "channel_version": "stable-2.25.1",
        "required_by": [
            "ikc_premium",
            "ikc_standard",
            "wml",
            "watson_speech",
            "watson_assistant",
            "watsonx_ai",
            "watsonx_bi_assistant",
            "watsonx_data",
            "watsonx_data_premium",
            "watsonx_dataintelligence",
            "watsonx_orchestrate",
            "wca",
            "wca_ansible",
            "wca_z",
            "wca_z_agentic",
            "wca_z_ce",
            "wca_z_cg",
            "ws_runtimes",
        ],
    },
    "multicloud_object_gateway_operator": {
        "name": "",
        "namespace": "",
        "channel_version": "stable-2.25.1",
        "required_by": [
            "watson_discovery",
            "watson_speech",
            "watson_assistant",
            "watsonx_orchestrate",
        ],
    },
    "nvidia_gpu_operator": {
        "name": "",
        "namespace": "",
        "channel_version": "stable-2.25.1",
        "required_by": [
            "ikc_premium",
            "ikc_standard",
            "wml",
            "watson_speech",
            "watson_assistant",
            "watsonx_ai",
            "watsonx_bi_assistant",
            "watsonx_data",
            "watsonx_data_premium",
            "watsonx_dataintelligence",
            "watsonx_orchestrate",
            "wca",
            "wca_ansible",
            "wca_z",
            "wca_z_agentic",
            "wca_z_ce",
            "wca_z_cg",
            "ws_runtimes",
        ],
    },
}

default_project_naming_conventions = [
    {"key": "PROJECT_CPD_INST_OPERATORS", "value": "cpd-operators"},
    {"key": "PROJECT_CPD_INST_OPERANDS", "value": "cpd-operands"},
    {"key": "PROJECT_LICENSE_SERVICE", "value": "ibm-licensing"},
    {"key": "PROJECT_SCHEDULING_SERVICE", "value": "ibm-scheduler"},
    {"key": "PROJECT_IBM_EVENTS", "value": "ibm-knative-events"},
    {"key": "PROJECT_PRIVILEGED_MONITORING_SERVICE", "value": "ibm-cpd-privileged"},
]

default_private_registry_setup = [
    {"key": "PRIVATE_REGISTRY_LOCATION", "value": "private.icr.io/<namespace>"},
    {"key": "PRIVATE_REGISTRY_PUSH_USER", "value": "iamapikey"},
    {"key": "PRIVATE_REGISTRY_PUSH_PASSWORD", "value": "<insert_password/apikey>"},
    {
        "key": "PRIVATE_REGISTRY_PULL_USER",
        "value": "${PRIVATE_REGISTRY_PUSH_USER}",
    },
    {
        "key": "PRIVATE_REGISTRY_PULL_PASSWORD",
        "value": "${PRIVATE_REGISTRY_PUSH_PASSWORD}",
    },
]

ibm_container_registry_domains = [
    "icr.io/<namespace>",  # global with user's endspace
    "icr.io",  # global
    "au.icr.io",
    "br.icr.io",
    "ca2.icr.io",
    "ca.icr.io",
    "de.icr.io",  # frankfurt
    "es.icr.io",
    "uk.icr.io",
    "in.icr.io",
    "jp2.icr.io",
    "jp.icr.io",
    "us.icr.io",
]

ibm_container_registry_private_domains = [
    "private.icr.io/<namespace>",  # global with user's endspace
    "private.icr.io",  # global
    "private.au.icr.io",
    "private.br.icr.io",
    "private.ca2.icr.io",
    "private.ca.icr.io",
    "private.de.icr.io",  # frankfurt
    "private.es.icr.io",
    "private.uk.icr.io",
    "private.in.icr.io",
    "private.jp2.icr.io",
    "private.jp.icr.io",
    "private.us.icr.io",
]
