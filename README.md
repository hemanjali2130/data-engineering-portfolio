# Data Engineering Portfolio — Hemanjali Buchireddy

Three end-to-end data engineering projects covering the same core patterns across
Databricks, Snowflake, and Azure: incremental ingestion, layered transformations,
quality controls, dimensional modelling, orchestration, and governance.

| # | Project | Stack | Status |
|---|---|---|---|
| 01 | Retail Clickstream Lakehouse | Databricks, PySpark, Delta Lake, Auto Loader, Unity Catalog | **Built and verified on Databricks Free Edition** |
| 02 | Governed Snowflake Warehouse | Snowflake, AWS S3, Snowpipe, Streams & Tasks, RBAC, masking | **Built and verified on Snowflake Trial + AWS** |
| 03 | Azure ETL Pipeline | ADF, Azure SQL, T-SQL MERGE SCD2, DQ gates | Implementation kit ready; requires Azure subscription |

## Verified Databricks delivery

The retail lakehouse is running in the Databricks `workspace` catalog on serverless
compute. Its job runs `bronze_ingest` → `silver_transform` → `gold_build`, with two
retries at one-minute intervals per task. A complete verification run succeeded:

| Layer | Result |
|---|---:|
| Source data | 1,417,495 POS rows, 702,124 clickstream events, 5,000 products |
| Silver sales | 1,389,049 valid rows; 17,073 quarantined rows |
| Gold sales fact | 1,389,049 rows |
| Workflow | bronze 24s; silver 52s; gold 47s |

See [the verified run record](01-databricks-lakehouse/RUN_STATUS.md) and
[workflow/governance notes](01-databricks-lakehouse/04_workflow_and_governance.md).

## Verified Snowflake delivery

The governed warehouse is running with AWS S3 event-driven Snowpipe ingestion,
append-only raw landing tables, Streams & Tasks, an SCD Type 2 customer dimension,
and idempotent order upserts. A controlled incremental test completed successfully:

| Check | Result |
|---|---:|
| Synthetic customers ingested | 50,002 |
| Synthetic orders ingested | 500,110 |
| Analytics fact rows | 500,110 |
| Task chain | Dimension and fact tasks succeeded |
| SCD Type 2 evidence | `C000001`: Denver version closed; Seattle version current |
| Governance validation | Analyst role returned masked email and phone values |

See [the verified Snowflake run record](02-snowflake-elt/RUN_STATUS.md) and the
[implementation plan](02-snowflake-elt/PLAN.md).

## Repository hygiene

Generated landing data, credentials, local environments, and Databricks checkpoints
are excluded from Git. Run each project's `00_generate_source_data.py` to recreate
the sample data locally.

## Interview thread that ties all three together
"Same architecture, three platforms": medallion layering, incremental ingestion,
MERGE-based upserts, SCD Type 2 history, quality gates that fail fast, and
governance (Unity Catalog / RBAC + masking / permission-scoped reporting). Being
able to compare how each platform expresses the same concept is a stronger
new-grad signal than any single project.
