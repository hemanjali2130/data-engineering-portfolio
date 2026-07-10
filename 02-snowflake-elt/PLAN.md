# Implementation Plan — Governed Snowflake Warehouse with Automated ELT

**Resume claim this proves:** Snowpipe auto-ingestion from S3 external stages,
Streams & Tasks driving scheduled MERGE upserts into an SCD Type 2 model, three-tier
RBAC, dynamic data masking on PII, Time Travel + zero-copy clones, warehouse tuning.

**Time estimate:** 1–2 weekends (~10–12 hours).
**Cost:** $0 — Snowflake 30-day trial ($400 credits; this project uses < $5) + AWS free tier.

---

## Architecture

```
 AWS S3  s3://<bucket>/snowflake/orders/     s3://<bucket>/snowflake/customers/
    │  S3 event notification → SQS
    ▼
 SNOWPIPE (auto_ingest)                      ← "files appear, rows appear"
    ▼
 RAW.ORDERS_RAW / RAW.CUSTOMERS_RAW          ← append-only landing tables
    │  STREAM captures new rows (CDC-style)
    ▼
 TASK tree (CRON + WHEN stream_has_data)
    ├─ SP_MERGE_DIM_CUSTOMER  → STAGING.DIM_CUSTOMER  (SCD Type 2)
    └─ SP_MERGE_FACT_ORDERS   → ANALYTICS.FACT_ORDERS (incremental MERGE)
                                    ▲
 GOVERNANCE: 3-tier RBAC (ENGINEER > ANALYST > VIEWER), masking on email/phone,
 Time Travel, zero-copy CLONE for dev. BI: Power BI on ANALYTICS via BI_WH.
```

## Prerequisites (Phase 0a)
- [ ] Snowflake 30-day trial (choose AWS as cloud, any US region)
- [ ] AWS S3 bucket + an IAM role for the storage integration (script 01 has the steps)
- [ ] Python 3 locally for the generator

## Phases — run the SQL files in order in a Snowflake worksheet

### Phase 0 — `00_generate_source_data.py`
Creates `snowflake_landing/`: customers (50K rows **with PII**: email, phone) and an
initial 500K-row orders file, **plus 3 incremental batches** containing new orders and
changed customer addresses — the SCD2 fuel. Upload batch 0 now; hold batches 1–3 back.

### Phase 1 — `01_setup_database_stages.sql`
Database RETAIL_DW, schemas RAW/STAGING/ANALYTICS, three warehouses
(LOAD_WH, TRANSFORM_WH, BI_WH — all XS, auto-suspend 60s), file format, storage
integration + external stage. **Accept when:** `LIST @RAW.S3_LANDING` shows your files.

### Phase 2 — `02_snowpipe_ingestion.sql`
Landing tables + 2 pipes with `AUTO_INGEST = TRUE`; wire the S3 event notification
to the pipe's SQS ARN. **Accept when:** you drop incremental batch 1 into S3 and rows
appear in RAW within ~1 minute, no command run. Check `SYSTEM$PIPE_STATUS` + `COPY_HISTORY`.

### Phase 3 — `03_streams_tasks_merge.sql`
Streams on both RAW tables; stored procedures implementing **SCD Type 2 MERGE**
(close old row, insert new version) and incremental fact MERGE; a two-task tree
(dims first, then facts) on a 5-minute CRON gated by `SYSTEM$STREAM_HAS_DATA`.
**Accept when:** dropping batch 2 → a customer's old address row shows
`is_current = FALSE` with `valid_to` stamped, new row `is_current = TRUE`;
task history shows SKIPPED runs when no data (that's the cost win — talk about it).

### Phase 4 — `04_governance_rbac_masking.sql`
Role hierarchy DE_ENGINEER → DE_ANALYST → DE_VIEWER, grants + future grants,
masking policies on email/phone, Time Travel demo, zero-copy clone of the whole DB.
**Accept when:** same query as ANALYST shows `ka****@masked.com`, as ENGINEER shows
the real value; `UNDROP TABLE` works; the clone is instant and free until modified.

### Phase 5 — `05_performance_tuning.sql`
Clustering key on FACT_ORDERS, pruning evidence via QUERY_HISTORY, warehouse
right-sizing experiment, resource monitor capped at 10 credits.
**Accept when:** you can show partitions-scanned dropping for a date-filtered query.

## Verification checklist
- [ ] Explain Snowpipe vs scheduled COPY (event-driven, per-file billing, serverless)
- [ ] Explain why Streams + MERGE instead of reprocessing full tables
- [ ] Walk the SCD2 state machine: what fires on INSERT vs UPDATE of a customer
- [ ] Show masking working per role, live
- [ ] GitHub: SQL files + screenshots (pipe status, task DAG, masked vs unmasked query)
