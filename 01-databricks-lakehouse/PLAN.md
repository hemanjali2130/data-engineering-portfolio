# Implementation Plan — Retail Clickstream Lakehouse (Databricks on AWS)

**Resume claim this proves:** medallion lakehouse on Delta Lake, 3 inconsistent S3 sources,
Auto Loader incremental ingestion (2M+ records), dedup + schema enforcement + quarantine,
gold Kimball star schema, multi-task Databricks Workflow with retries/alerts,
OPTIMIZE / Z-ORDER, Unity Catalog governance.

**Time estimate:** 2 weekends (~12–16 hours). **Cost:** $0 (free tiers).

---

## Architecture

```
                    ┌──────────────────  AWS S3 (landing zone)  ─────────────────┐
   pos_sales/*.csv  │  clickstream/*.jsonl  │  products/*.json                   │
                    └───────────┬───────────────────┬────────────────────────────┘
                                │  Auto Loader (cloudFiles, incremental, schema evolution)
                    ┌───────────▼───────────────────▼───────────┐
                    │  BRONZE  raw Delta tables + ingest metadata │
                    └───────────┬────────────────────────────────┘
                                │  PySpark: cast, dedupe on business keys,
                                │  DQ checks → quarantine table (bad rows)
                    ┌───────────▼────────────────────────────────┐
                    │  SILVER  conformed, validated Delta tables  │
                    └───────────┬────────────────────────────────┘
                                │  joins + surrogate keys
                    ┌───────────▼────────────────────────────────┐
                    │  GOLD  Kimball star schema                  │
                    │  fact_sales, fact_clickstream_daily,        │
                    │  dim_product, dim_store, dim_date           │
                    └─────────────────────────────────────────────┘
   Orchestration: Databricks Workflow (bronze → silver → gold), retries + email alert
   Governance:   Unity Catalog (schemas, GRANTs, lineage)
```

## Prerequisites (Phase 0a)

- [ ] AWS account (free tier) → create S3 bucket, e.g. `hemanjali-retail-lakehouse`
- [ ] Databricks workspace. Two options:
  - **Option A (matches resume exactly):** Databricks 14-day free trial on AWS —
    full workspace, S3 access, job clusters.
  - **Option B ($0 forever):** Databricks Free Edition — use a Unity Catalog **Volume**
    as the landing zone instead of S3 (upload the same files there). Everything else
    is identical. If asked in an interview, you still describe the S3 pattern honestly:
    you built the pipeline; the landing zone is a config path.
- [ ] Python 3 on your laptop (for the data generator)

## Phases

### Phase 0 — Generate & land source data (`00_generate_source_data.py`)
Run locally. Produces **~2.1M records**: 14 daily POS CSV files (~1.4M rows, with
duplicates, null SKUs, and a `loyalty_id` column that appears only from day 8 — this
is what makes schema evolution real), 14 daily clickstream JSONL files (~700K events),
and a products JSON feed (~5K SKUs).

```bash
python3 00_generate_source_data.py            # writes ./landing/
aws s3 cp landing/ s3://<YOUR_BUCKET>/landing/ --recursive
```
**Accept when:** `aws s3 ls` shows the 3 prefixes; file counts match the script output.

### Phase 1 — Bronze with Auto Loader (`01_bronze_autoloader.py`)
Import as a Databricks notebook. Creates `workspace.bronze.*` tables via `cloudFiles`
with checkpoints, `availableNow` trigger, schema evolution + rescued-data column.

**Accept when:** re-running ingests **0 new rows** (proves incremental); dropping one
more day's file into S3 and re-running ingests only that file; bronze row count ≥ 2.1M.

### Phase 2 — Silver: dedupe, enforce, quarantine (`02_silver_transformations.py`)
Window-function dedupe on business keys, explicit casts, null-threshold check,
referential check against products; failures land in `workspace.silver.quarantine_sales`
with a `reject_reason` — the pipeline does not halt.

**Accept when:** quarantine table holds the planted bad rows (~1%); silver has zero
null SKUs and zero duplicate `(store_id, txn_id, line_id)`.

### Phase 3 — Gold star schema + performance (`03_gold_star_schema.py`)
Builds dims + facts (fact partitioned by date), runs `OPTIMIZE ... ZORDER BY`,
and runs 3 sample BI queries. Record before/after query times — that is your
"reduced full-refresh runtime" evidence.

**Accept when:** star schema joins return correct totals vs. a raw-file spot check;
`DESCRIBE HISTORY` shows the OPTIMIZE operation.

### Phase 4 — Workflow + Unity Catalog governance (`04_workflow_and_governance.md`)
Multi-task Job (bronze → silver → gold) with 2 retries and failure email; UC
`GRANT`s for an analyst group; view lineage in Catalog Explorer.

**Accept when:** deliberately break a path → job retries then emails you; lineage
graph shows bronze → silver → gold; a second user/role can SELECT gold but not bronze.

## Verification checklist (run before any interview)
- [ ] Explain why Auto Loader beats `COPY INTO` / plain `spark.read` here
- [ ] Show the rescued-data column catching the `loyalty_id` schema change
- [ ] Walk through the quarantine logic and why you don't fail the whole load
- [ ] Explain Z-ORDER vs partitioning (and why you did both)
- [ ] Push to GitHub with screenshots of the Workflow DAG + lineage graph
