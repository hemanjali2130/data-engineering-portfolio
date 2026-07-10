# Databricks notebook source
# MAGIC %md
# MAGIC # Phase 1 — Bronze ingestion with Auto Loader
# MAGIC Three sources → three bronze Delta tables. Incremental (checkpointed),
# MAGIC schema-evolving, with a rescued-data column for anything unexpected.
# MAGIC
# MAGIC **Edit the CONFIG cell, then Run All.** Re-running ingests only NEW files.

# COMMAND ----------
# CONFIG — Databricks Free Edition (Unity Catalog managed Volumes)
# Free Edition workspace catalog confirmed during initial setup.
CATALOG = "workspace"
VOLUME_SCHEMA = "default"
LANDING = f"/Volumes/{CATALOG}/{VOLUME_SCHEMA}/retail_landing"
CHECKPOINTS = f"/Volumes/{CATALOG}/{VOLUME_SCHEMA}/retail_checkpoints"

# Keep source files and Auto Loader state in separate volumes. Otherwise the loader
# could discover checkpoint files as input data.
spark.sql(f"CREATE VOLUME IF NOT EXISTS {CATALOG}.{VOLUME_SCHEMA}.retail_landing")
spark.sql(f"CREATE VOLUME IF NOT EXISTS {CATALOG}.{VOLUME_SCHEMA}.retail_checkpoints")
spark.sql(f"CREATE SCHEMA IF NOT EXISTS {CATALOG}.bronze")
spark.sql(f"CREATE SCHEMA IF NOT EXISTS {CATALOG}.silver")
spark.sql(f"CREATE SCHEMA IF NOT EXISTS {CATALOG}.gold")

# COMMAND ----------
from pyspark.sql import functions as F

def ingest(src_path, fmt, table, options=None):
    """Generic Auto Loader stream: incremental, schema evolution, audit columns."""
    reader = (spark.readStream.format("cloudFiles")
              .option("cloudFiles.format", fmt)
              .option("cloudFiles.schemaLocation", f"{CHECKPOINTS}/{table}/schema")
              .option("cloudFiles.schemaEvolutionMode", "addNewColumns")
              .option("rescuedDataColumn", "_rescued_data"))
    for k, v in (options or {}).items():
        reader = reader.option(k, v)
    df = (reader.load(src_path)
          .withColumn("_ingest_ts", F.current_timestamp())
          .withColumn("_source_file", F.col("_metadata.file_path")))
    q = (df.writeStream
         .option("checkpointLocation", f"{CHECKPOINTS}/{table}/chk")
         .option("mergeSchema", "true")
         .trigger(availableNow=True)                 # batch-style: drain new files, stop
         .toTable(f"{CATALOG}.bronze.{table}"))
    q.awaitTermination()
    n = spark.table(f"{CATALOG}.bronze.{table}").count()
    print(f"bronze.{table}: {n:,} rows total")

# COMMAND ----------
# 1) POS sales — CSV with header; loyalty_id appears on day 8 (schema evolution)
ingest(f"{LANDING}/pos_sales/", "csv", "pos_sales",
       {"header": "true", "cloudFiles.inferColumnTypes": "false"})  # keep raw as string

# COMMAND ----------
# 2) Clickstream — JSON lines
ingest(f"{LANDING}/clickstream/", "json", "clickstream_events")

# COMMAND ----------
# 3) Product feed — JSON array (multiline)
ingest(f"{LANDING}/products/", "json", "products_feed", {"multiLine": "true"})

# COMMAND ----------
# MAGIC %md
# MAGIC ### Verify (matches PLAN.md acceptance criteria)
# MAGIC 1. Run this notebook twice — second run should add **0 rows**.
# MAGIC 2. `SELECT DISTINCT _source_file FROM retail.bronze.pos_sales` — one entry per landed file.
# MAGIC 3. `SELECT COUNT(*) FROM retail.bronze.pos_sales WHERE loyalty_id IS NOT NULL`
# MAGIC    — non-zero, proving the evolved column arrived without breaking the stream.
