# Databricks notebook source
# MAGIC %md
# MAGIC # Phase 3 — Gold: Kimball star schema + OPTIMIZE / Z-ORDER
# MAGIC dim_product, dim_store, dim_date, fact_sales (partitioned by date),
# MAGIC fact_clickstream_daily. Then physical optimization and 3 BI queries.

# COMMAND ----------
# Databricks Free Edition uses the workspace catalog.  Set this to your Unity
# Catalog name (for example, "retail") when deploying outside Free Edition.
CATALOG = "workspace"
from pyspark.sql import functions as F, Window

# COMMAND ----------
# ---- dimensions ----
dim_product = (spark.table(f"{CATALOG}.silver.products")
    .withColumn("product_key", F.row_number().over(Window.orderBy("sku")))
    .select("product_key", "sku", "name", "category", "brand", "list_price"))
dim_product.write.mode("overwrite").saveAsTable(f"{CATALOG}.gold.dim_product")

dim_store = (spark.table(f"{CATALOG}.silver.pos_sales").select("store_id").distinct()
    .withColumn("store_key", F.row_number().over(Window.orderBy("store_id")))
    .withColumn("region", F.when(F.col("store_id") <= "S010", "East").otherwise("West"))
    .select("store_key", "store_id", "region"))
dim_store.write.mode("overwrite").saveAsTable(f"{CATALOG}.gold.dim_store")

dim_date = (spark.sql("SELECT explode(sequence(to_date('2026-04-01'), to_date('2026-04-30'))) AS d")
    .select(F.date_format("d", "yyyyMMdd").cast("int").alias("date_key"),
            F.col("d").alias("cal_date"),
            F.dayofweek("d").alias("day_of_week"),
            F.date_format("d", "EEEE").alias("day_name"),
            F.weekofyear("d").alias("week_of_year"),
            F.month("d").alias("month")))
dim_date.write.mode("overwrite").saveAsTable(f"{CATALOG}.gold.dim_date")

# COMMAND ----------
# ---- fact_sales: partitioned by date_key ----
sales = spark.table(f"{CATALOG}.silver.pos_sales")
fact_sales = (sales
    .withColumn("date_key", F.date_format("txn_ts", "yyyyMMdd").cast("int"))
    .join(spark.table(f"{CATALOG}.gold.dim_product").select("product_key", "sku"), "sku")
    .join(spark.table(f"{CATALOG}.gold.dim_store").select("store_key", "store_id"), "store_id")
    .select("date_key", "product_key", "store_key", "txn_id", "line_id",
            "txn_ts", "qty", "unit_price",
            (F.col("qty") * F.col("unit_price")).alias("line_amount"),
            "payment_type", "loyalty_id"))
(fact_sales.write.mode("overwrite")
    .partitionBy("date_key")
    .saveAsTable(f"{CATALOG}.gold.fact_sales"))
print("gold.fact_sales:", spark.table(f"{CATALOG}.gold.fact_sales").count())

# ---- fact_clickstream_daily: pre-aggregated for BI ----
ck = spark.table(f"{CATALOG}.silver.clickstream_events")
fact_ck = (ck.withColumn("date_key", F.date_format("event_ts", "yyyyMMdd").cast("int"))
    .join(spark.table(f"{CATALOG}.gold.dim_product").select("product_key", "sku"), "sku")
    .groupBy("date_key", "product_key", "event_type", "device")
    .agg(F.count("*").alias("events"),
         F.countDistinct("user_id").alias("unique_users"),
         F.countDistinct("session_id").alias("sessions")))
fact_ck.write.mode("overwrite").partitionBy("date_key") \
    .saveAsTable(f"{CATALOG}.gold.fact_clickstream_daily")

# COMMAND ----------
# ---- performance: OPTIMIZE + Z-ORDER on the columns BI filters/joins on ----
spark.sql(f"OPTIMIZE {CATALOG}.gold.fact_sales ZORDER BY (product_key, store_key)")
spark.sql(f"OPTIMIZE {CATALOG}.gold.fact_clickstream_daily ZORDER BY (product_key)")
display(spark.sql(f"DESCRIBE HISTORY {CATALOG}.gold.fact_sales LIMIT 5"))

# COMMAND ----------
# MAGIC %md ### Sample BI queries (time these before/after OPTIMIZE for your notes)

# COMMAND ----------
# Q1: daily revenue by category
display(spark.sql(f"""
SELECT d.cal_date, p.category, ROUND(SUM(f.line_amount),2) AS revenue
FROM {CATALOG}.gold.fact_sales f
JOIN {CATALOG}.gold.dim_product p USING (product_key)
JOIN {CATALOG}.gold.dim_date d    USING (date_key)
GROUP BY 1,2 ORDER BY 1,2"""))

# COMMAND ----------
# Q2: top-10 products by revenue with view->purchase conversion signal
display(spark.sql(f"""
WITH rev AS (
  SELECT product_key, SUM(line_amount) AS revenue
  FROM {CATALOG}.gold.fact_sales GROUP BY 1),
views AS (
  SELECT product_key, SUM(events) AS product_views
  FROM {CATALOG}.gold.fact_clickstream_daily
  WHERE event_type = 'product_view' GROUP BY 1)
SELECT p.name, p.category, ROUND(rev.revenue,2) AS revenue, views.product_views
FROM rev JOIN {CATALOG}.gold.dim_product p USING (product_key)
LEFT JOIN views USING (product_key)
ORDER BY revenue DESC LIMIT 10"""))

# COMMAND ----------
# Q3: weekend vs weekday sales mix by region
display(spark.sql(f"""
SELECT s.region,
       CASE WHEN d.day_of_week IN (1,7) THEN 'weekend' ELSE 'weekday' END AS day_type,
       ROUND(SUM(f.line_amount),2) AS revenue
FROM {CATALOG}.gold.fact_sales f
JOIN {CATALOG}.gold.dim_store s USING (store_key)
JOIN {CATALOG}.gold.dim_date d  USING (date_key)
GROUP BY 1,2 ORDER BY 1,2"""))
