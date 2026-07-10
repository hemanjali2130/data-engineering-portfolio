# Phase 4 — Databricks Workflow + Unity Catalog governance

## A. Build the multi-task Workflow (UI, ~20 min)

1. **Workflows → Create Job**, name it `retail_lakehouse_daily`.
2. Add three notebook tasks, chained with **Depends on**:
   - `bronze_ingest`  → notebook `01_bronze_autoloader`
   - `silver_transform` → notebook `02_silver_transformations`, depends on `bronze_ingest`
   - `gold_build` → notebook `03_gold_star_schema`, depends on `silver_transform`
3. Per task: **Retries = 2**, retry interval 1 min (open task → Advanced options).
4. Job level: **Notifications → add your email on Failure**.
5. Compute: job cluster (trial) or serverless (Free Edition) — either is fine.
6. **Schedule**: daily 6:00 AM, or leave manual and trigger by dropping new files.

Equivalent JSON (Job → ⋮ → *Edit as JSON*), useful for your GitHub README:

```json
{
  "name": "retail_lakehouse_daily",
  "email_notifications": { "on_failure": ["hemanjalibreddy@gmail.com"] },
  "tasks": [
    { "task_key": "bronze_ingest",
      "notebook_task": { "notebook_path": "/Repos/.../01_bronze_autoloader" },
      "max_retries": 2, "min_retry_interval_millis": 60000 },
    { "task_key": "silver_transform",
      "depends_on": [ { "task_key": "bronze_ingest" } ],
      "notebook_task": { "notebook_path": "/Repos/.../02_silver_transformations" },
      "max_retries": 2 },
    { "task_key": "gold_build",
      "depends_on": [ { "task_key": "silver_transform" } ],
      "notebook_task": { "notebook_path": "/Repos/.../03_gold_star_schema" },
      "max_retries": 2 }
  ]
}
```

**Prove the failure path:** temporarily change `LANDING` to a bad path, run the job,
watch it retry twice, then check the failure email. Change it back. Screenshot the DAG.

### Free Edition run record (2026-07-09)

The job was created in the Free Edition workspace with the three notebook tasks below,
each using serverless compute and the sequential dependencies shown:

`bronze_ingest` → `silver_transform` → `gold_build`

One full manual run succeeded end to end: bronze **24s**, silver **52s**, and gold
**47s**. The job run showed 5 upstream and 7 downstream tables, which confirms that
Databricks captured the table lineage for the run. Every task is configured with
**2 retries** and a **1-minute retry interval**. Notification delivery, scheduling,
and a deliberate failure test remain optional production hardening steps because
they require choosing an alert destination and operating schedule.

## B. Unity Catalog governance (~15 min)

```sql
-- Principle: analysts read GOLD only; engineers own the pipeline.
CREATE SCHEMA IF NOT EXISTS workspace.gold;

-- On Free Edition create a group or use another workspace user
GRANT USE CATALOG ON CATALOG workspace TO `analysts`;
GRANT USE SCHEMA  ON SCHEMA workspace.gold TO `analysts`;
GRANT SELECT      ON SCHEMA workspace.gold TO `analysts`;
-- deliberately NO grants on bronze/silver: raw + quarantine data stays restricted

-- Verify as the analyst principal:
--   SELECT * FROM workspace.gold.fact_sales LIMIT 5;      -- works
--   SELECT * FROM workspace.silver.quarantine_sales;       -- PERMISSION_DENIED
```

**Lineage:** Catalog Explorer → `workspace.gold.fact_sales` → **Lineage** tab. You'll see
bronze → silver → gold captured automatically. Screenshot this for GitHub — it's the
visual that makes "data governance (permissions, lineage) via Unity Catalog" concrete.

## C. Interview prep — the questions this project will attract

| Likely question | Where your answer lives |
|---|---|
| Why Auto Loader instead of `COPY INTO`? | Checkpointed file discovery, scales to millions of files, schema evolution — notebook 01 |
| What happens when a bad record arrives? | Quarantine table with reject_reason vs. hard assert — notebook 02, two different DQ gate styles |
| Why both partitioning AND Z-ORDER? | Partition prunes on date; Z-ORDER co-locates product/store within partitions — notebook 03 |
| What breaks if a source adds a column? | Day-8 loyalty_id: schemaEvolutionMode adds it, rescued-data catches type surprises |
| How would you productionize further? | DLT expectations, CDC with MERGE, alerts to Slack, CI on notebooks |
