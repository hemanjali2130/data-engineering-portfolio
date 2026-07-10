-- =====================================================================
-- Phase 5 — Performance & cost: clustering, pruning evidence, sizing,
--           resource monitor. This is your "cut query scan volume and
--           compute-credit burn" resume bullet, with receipts.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE RETAIL_DW;
USE WAREHOUSE BI_WH;

-- ---- 1. Baseline: run a date-filtered BI query and note the stats ----
SELECT ORDER_DATE, CHANNEL, COUNT(*) ORDERS, SUM(ORDER_TOTAL) REVENUE
FROM ANALYTICS.FACT_ORDERS
WHERE ORDER_DATE BETWEEN '2026-03-01' AND '2026-03-07'
GROUP BY 1, 2 ORDER BY 1, 2;
-- Open Query Profile -> note "Partitions scanned / total". Screenshot = BEFORE.

-- ---- 2. Clustering key on the natural filter column ----
ALTER TABLE ANALYTICS.FACT_ORDERS CLUSTER BY (ORDER_DATE);

-- Clustering health (depth should trend down once reclustering completes):
SELECT SYSTEM$CLUSTERING_INFORMATION('ANALYTICS.FACT_ORDERS', '(ORDER_DATE)');

-- Re-run the query in step 1 after a while -> Query Profile again = AFTER.
-- (On a 500K-row table the effect is modest; the METHOD is what interviews test.)

-- ---- 3. Warehouse right-sizing experiment ----
-- Run the same aggregation on XSMALL vs SMALL and compare elapsed vs credits:
ALTER WAREHOUSE BI_WH SET WAREHOUSE_SIZE = 'SMALL';
-- rerun query, note time
ALTER WAREHOUSE BI_WH SET WAREHOUSE_SIZE = 'XSMALL';
-- rerun query, note time
-- Takeaway to be able to say: "2x size ≈ 2x credits/hour; only worth it when the
-- query is compute-bound. For this workload XSMALL + 60s auto-suspend was optimal."

-- ---- 4. Where did my credits go? ----
SELECT WAREHOUSE_NAME,
       SUM(CREDITS_USED)          AS CREDITS,
       COUNT(DISTINCT DATE_TRUNC('hour', START_TIME)) AS ACTIVE_HOURS
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1 ORDER BY CREDITS DESC;

-- Slowest queries this week + how much they scanned:
SELECT QUERY_TEXT, WAREHOUSE_NAME, TOTAL_ELAPSED_TIME/1000 AS SECS,
       BYTES_SCANNED/1e6 AS MB_SCANNED, PARTITIONS_SCANNED, PARTITIONS_TOTAL
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND WAREHOUSE_NAME IS NOT NULL
ORDER BY TOTAL_ELAPSED_TIME DESC LIMIT 10;

-- ---- 5. Guardrail: resource monitor so the trial never burns out ----
CREATE OR REPLACE RESOURCE MONITOR RM_RETAIL WITH
  CREDIT_QUOTA = 10 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 80 PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND;
ALTER WAREHOUSE LOAD_WH      SET RESOURCE_MONITOR = RM_RETAIL;
ALTER WAREHOUSE TRANSFORM_WH SET RESOURCE_MONITOR = RM_RETAIL;
ALTER WAREHOUSE BI_WH        SET RESOURCE_MONITOR = RM_RETAIL;
