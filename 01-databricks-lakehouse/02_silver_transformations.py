# Databricks notebook source
# MAGIC %md
# MAGIC # Phase 2 — Silver: cast, dedupe, quarantine
# MAGIC Business rules:
# MAGIC * explicit schema (no silent string columns survive)
# MAGIC * dedupe on business keys, keeping the latest `_ingest_ts`
# MAGIC * DQ gate 1: null-SKU rate must be < 2% (else fail loudly)
# MAGIC * DQ gate 2: SKUs must exist in the product feed — violations are **quarantined
# MAGIC   with a reject_reason, not dropped and not fatal**

# COMMAND ----------
# Databricks Free Edition uses the workspace catalog.  Set this to your Unity
# Catalog name (for example, "retail") when deploying outside Free Edition.
CATALOG = "workspace"
from pyspark.sql import functions as F, Window

# COMMAND ----------
# ---- products (small dim source, dedupe on sku keeping latest update) ----
prod = (spark.table(f"{CATALOG}.bronze.products_feed")
        .withColumn("rn", F.row_number().over(
            Window.partitionBy("sku").orderBy(F.col("updated_at").desc())))
        .filter("rn = 1").drop("rn", "_rescued_data"))
prod.write.mode("overwrite").saveAsTable(f"{CATALOG}.silver.products")
print("silver.products:", prod.count())

# COMMAND ----------
# ---- POS sales: cast -> dedupe -> DQ gates -> quarantine/clean split ----
raw = spark.table(f"{CATALOG}.bronze.pos_sales")

typed = raw.select(
    F.col("store_id").cast("string"),
    F.col("txn_id").cast("string"),
    F.col("line_id").cast("int"),
    F.to_timestamp("txn_ts").alias("txn_ts"),
    F.upper(F.trim(F.col("sku"))).alias("sku"),
    F.col("qty").cast("int"),
    F.col("unit_price").cast("decimal(10,2)"),
    F.col("payment_type").cast("string"),
    F.col("loyalty_id").cast("string"),
    "_ingest_ts", "_source_file",
).withColumn("sku", F.when(F.col("sku") == "", None).otherwise(F.col("sku")))

# dedupe on business key (store_id, txn_id, line_id), keep latest ingest
key = Window.partitionBy("store_id", "txn_id", "line_id").orderBy(F.col("_ingest_ts").desc())
deduped = typed.withColumn("rn", F.row_number().over(key)).filter("rn = 1").drop("rn")
print(f"dedupe removed {typed.count() - deduped.count():,} duplicate lines")

# COMMAND ----------
# DQ gate 1 — null-SKU threshold (fail the run if data is catastrophically broken)
null_rate = deduped.filter("sku IS NULL").count() / deduped.count()
print(f"null SKU rate: {null_rate:.3%}")
assert null_rate < 0.02, f"HALT: null-SKU rate {null_rate:.2%} breaches 2% threshold"

# DQ gate 2 — referential integrity: quarantine, don't halt
valid_skus = spark.table(f"{CATALOG}.silver.products").select("sku")
flagged = (deduped
           .withColumn("reject_reason",
               F.when(F.col("sku").isNull(), "NULL_SKU")
                .when(F.col("qty").isNull() | (F.col("qty") <= 0), "BAD_QTY"))
           .join(valid_skus.withColumn("_known", F.lit(1)), "sku", "left")
           .withColumn("reject_reason",
               F.coalesce("reject_reason",
                          F.when(F.col("_known").isNull(), "UNKNOWN_SKU")))
           .drop("_known"))

quarantine = flagged.filter("reject_reason IS NOT NULL")
clean = flagged.filter("reject_reason IS NULL").drop("reject_reason")

quarantine.write.mode("overwrite").saveAsTable(f"{CATALOG}.silver.quarantine_sales")
clean.write.mode("overwrite").saveAsTable(f"{CATALOG}.silver.pos_sales")
print(f"silver.pos_sales: {clean.count():,}   quarantine: {quarantine.count():,}")

# COMMAND ----------
# ---- clickstream: cast + dedupe on event_id ----
ck = (spark.table(f"{CATALOG}.bronze.clickstream_events")
      .select("event_id", "user_id", "session_id", "event_type",
              F.upper("sku").alias("sku"),
              F.to_timestamp("event_ts").alias("event_ts"),
              "device", "_ingest_ts")
      .withColumn("rn", F.row_number().over(
          Window.partitionBy("event_id").orderBy(F.col("_ingest_ts").desc())))
      .filter("rn = 1").drop("rn"))
ck.write.mode("overwrite").saveAsTable(f"{CATALOG}.silver.clickstream_events")
print("silver.clickstream_events:", ck.count())

# COMMAND ----------
# MAGIC %md
# MAGIC ### Verify
# MAGIC ```sql
# MAGIC SELECT reject_reason, COUNT(*) FROM retail.silver.quarantine_sales GROUP BY 1;
# MAGIC -- expect NULL_SKU and UNKNOWN_SKU rows (~1% of volume), pipeline still succeeded
# MAGIC SELECT COUNT(*) FROM retail.silver.pos_sales WHERE sku IS NULL;   -- must be 0
# MAGIC ```
