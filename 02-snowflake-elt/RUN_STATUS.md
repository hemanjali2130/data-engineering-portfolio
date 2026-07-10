# Verified Run — Governed Snowflake Warehouse

## Delivery status

Fully built and verified on Snowflake Trial with AWS S3. The repository contains
only synthetic data generators and reusable SQL; no cloud identifiers, credentials,
or account details are tracked.

## What ran successfully

| Capability | Evidence |
|---|---|
| Event-driven ingestion | AWS S3 object-created events triggered Snowpipe auto-ingestion. |
| Raw layer | 50,002 customer records and 500,110 order records loaded. |
| Incremental ELT | Streams fed a two-task chain; dimension and fact tasks succeeded. |
| Dimensional model | `FACT_ORDERS` reached 500,110 rows after incremental upserts. |
| SCD Type 2 | `C000001` has a closed Denver version and a current Seattle version. |
| Governance | `DE_ANALYST` returned masked `EMAIL` and `PHONE` values. |
| Performance | `FACT_ORDERS` is clustered by `ORDER_DATE`. |

## Architecture exercised

```text
AWS S3 -> Snowpipe -> RAW tables -> Streams -> Tasks -> SCD2 dimension + fact MERGE
                                                   -> RBAC, dynamic masking, clustered analytics table
```

## Re-run notes

Use `00_generate_source_data.py` for synthetic data and run the SQL files in
numeric order. `06_trial_execution.sql` is a self-contained, smaller offline
exercise for a Snowflake-only demonstration; the verified delivery used the
AWS S3 and Snowpipe implementation in scripts 01–05.
