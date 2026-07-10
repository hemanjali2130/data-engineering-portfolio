# Implementation Plan — Azure ETL Pipeline for Sales & Inventory Data

**Resume claim this proves:** bronze–silver–gold medallion pipeline in Azure Data
Factory, daily-scheduled ingestion of CSV sales/inventory into Azure SQL, T-SQL MERGE
for SCD Type 2 on the menu-item dimension, data-quality gates as pipeline activities
that stop bad loads before reporting. (This is the project already on your resume —
this plan rebuilds it cleanly so every bullet has a demo.)

**Time estimate:** 1 weekend (~8–10 hours).
**Cost:** $0 — Azure free account ($200 credit); Azure SQL serverless + ADF cost pennies.

---

## Architecture

```
 Blob Storage (container: landing)          Azure SQL Database (RETAILDW)
   sales_YYYYMMDD.csv     ─┐   ADF Copy      ┌─ brz.SALES_RAW / brz.INVENTORY_RAW
   inventory_YYYYMMDD.csv ─┘  ───────────►   │        │ sp_load_silver (TRY_CAST, dedupe)
                                             │        ▼
        ADF pipeline PL_DAILY_MEDALLION      │  slv.SALES / slv.INVENTORY
        Get Metadata → ForEach → Copy        │        │ DQ GATES (procs THROW on breach)
        → DQ procs → silver → SCD2 → gold    │        ▼
        Trigger: daily 6:00 AM               │  gld.DIM_MENU_ITEM (SCD2), gld.DIM_STORE,
        On-failure: alert email              └─ gld.DIM_DATE, gld.FACT_DAILY_SALES
                                                       ▲  Power BI (optional serving layer)
```

## Prerequisites (Phase 0a)
- [ ] Azure free account → create resource group `rg-retail-etl`
- [ ] Storage account (`stretailetl…`) with container `landing`
- [ ] Azure SQL Database `RETAILDW` (serverless, auto-pause 60 min, ~free at this scale)
- [ ] Data Factory instance `adf-retail-etl`
- [ ] Python 3 locally

## Phases

### Phase 0 — `00_generate_source_data.py`
30 days of `sales_YYYYMMDD.csv` + `inventory_YYYYMMDD.csv` for 5 stores × ~60 menu
items. Includes planted nulls/dupes/orphans for the DQ gates, and **menu price changes
on days 10 and 20** — the SCD2 fuel. Upload to Blob:
`az storage blob upload-batch -s adf_landing -d landing --account-name <ACCOUNT>`

### Phase 1 — `01_create_tables.sql` (run in Azure SQL, e.g. Query Editor in portal)
Schemas `brz/slv/gld/etl`, bronze raw tables (all NVARCHAR + load metadata), typed
silver tables, gold star schema with SCD2 columns on DIM_MENU_ITEM, `etl.DQ_LOG` +
`etl.LOAD_LOG`. **Accept when:** all objects created; `SELECT` works on every table.

### Phase 2 — `02_data_quality_procs.sql`
Three gate procs — `sp_dq_check_nulls`, `sp_dq_check_duplicates`, `sp_dq_check_referential`
— each logs to `etl.DQ_LOG` and `THROW`s on breach (that's what stops the ADF pipeline),
plus `sp_load_silver_sales` / `sp_load_silver_inventory` (TRY_CAST + dedupe).

### Phase 3 — `03_scd2_and_fact_procs.sql`
`sp_upsert_dim_menu_item`: T-SQL **MERGE with OUTPUT** implementing SCD Type 2
(close old version, insert new). `sp_load_fact_daily_sales`: idempotent delete+insert
by load date, joining facts to current dim versions. **Accept when:** loading day 10
gives price-changed items two rows in DIM_MENU_ITEM (old `IsCurrent=0`, new `=1`).

### Phase 4 — `04_adf_pipeline_guide.md`
Build `PL_DAILY_MEDALLION` in ADF Studio: linked services, parameterized datasets,
Get Metadata → ForEach → Copy (bronze), then Stored Procedure activities in sequence:
DQ gates → silver → SCD2 dim → fact. Daily 6 AM trigger + failure alert.
**Accept when:** a clean day runs green end to end; a file with planted breaches
turns the run red at the DQ gate and gold tables stay untouched.

## Verification checklist
- [ ] Explain why DQ gates sit between bronze and silver (fail fast, cheap)
- [ ] Whiteboard the SCD2 MERGE: which rows close, which insert, why OUTPUT is needed
- [ ] Explain idempotent fact loads (rerun a day safely — delete+insert by date)
- [ ] Show `etl.DQ_LOG` after a failed run: which rule fired, row counts
- [ ] Optional: point Power BI at gld.* and reuse your existing dashboard skills
