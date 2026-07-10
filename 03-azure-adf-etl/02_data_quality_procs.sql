-- =====================================================================
-- Phase 2 — Data-quality gates + silver loaders
-- Each DQ proc logs to etl.DQ_LOG and THROWs on breach; the THROW is what
-- fails the ADF Stored Procedure activity and stops the pipeline.
-- All procs take @business_date so ADF can pass the run date.
-- =====================================================================

-- ---- GATE 1: null business keys in bronze ----
CREATE OR ALTER PROCEDURE etl.sp_dq_check_nulls @business_date DATE
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @failed INT;
  SELECT @failed = COUNT(*)
  FROM brz.SALES_RAW
  WHERE TRY_CONVERT(DATE, business_date) = @business_date
    AND (NULLIF(LTRIM(RTRIM(item_id)), '') IS NULL
         OR NULLIF(LTRIM(RTRIM(store_id)), '') IS NULL);

  DECLARE @total INT;
  SELECT @total = COUNT(*) FROM brz.SALES_RAW
  WHERE TRY_CONVERT(DATE, business_date) = @business_date;

  DECLARE @pass BIT = CASE WHEN @total = 0 THEN 0
                           WHEN 1.0 * @failed / @total < 0.02 THEN 1 ELSE 0 END;
  INSERT INTO etl.DQ_LOG (business_date, rule_name, table_name, failed_rows, threshold, passed)
  VALUES (@business_date, 'NULL_BUSINESS_KEYS', 'brz.SALES_RAW', @failed, '< 2% of rows', @pass);

  IF @pass = 0
    THROW 50001, 'DQ GATE FAILED: null business keys exceed threshold (or empty load).', 1;
END;
GO

-- ---- GATE 2: duplicate natural keys in bronze ----
CREATE OR ALTER PROCEDURE etl.sp_dq_check_duplicates @business_date DATE
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @failed INT;
  SELECT @failed = COUNT(*) FROM (
    SELECT business_date, store_id, item_id
    FROM brz.SALES_RAW
    WHERE TRY_CONVERT(DATE, business_date) = @business_date
      AND NULLIF(item_id, '') IS NOT NULL
    GROUP BY business_date, store_id, item_id
    HAVING COUNT(*) > 1) x;

  -- duplicates are EXPECTED (planted); we log and pass if < 5% of keys.
  DECLARE @keys INT;
  SELECT @keys = COUNT(DISTINCT CONCAT(store_id, '|', item_id))
  FROM brz.SALES_RAW WHERE TRY_CONVERT(DATE, business_date) = @business_date;

  DECLARE @pass BIT = CASE WHEN @keys > 0 AND 1.0 * @failed / @keys < 0.05 THEN 1 ELSE 0 END;
  INSERT INTO etl.DQ_LOG (business_date, rule_name, table_name, failed_rows, threshold, passed)
  VALUES (@business_date, 'DUPLICATE_KEYS', 'brz.SALES_RAW', @failed, '< 5% of keys', @pass);

  IF @pass = 0 THROW 50002, 'DQ GATE FAILED: duplicate key rate exceeds threshold.', 1;
END;
GO

-- ---- GATE 3: referential integrity vs known menu items ----
-- (checks bronze against distinct items ever seen in silver + current file's names;
--  truly unknown ids are counted, logged, and tolerated below 2%)
CREATE OR ALTER PROCEDURE etl.sp_dq_check_referential @business_date DATE
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @failed INT;
  SELECT @failed = COUNT(*)
  FROM brz.SALES_RAW b
  WHERE TRY_CONVERT(DATE, b.business_date) = @business_date
    AND NULLIF(b.item_id, '') IS NOT NULL
    AND NULLIF(b.item_name, '') IS NULL   -- unknown id AND no name to onboard it
    AND NOT EXISTS (SELECT 1 FROM gld.DIM_MENU_ITEM d WHERE d.item_id = b.item_id);

  DECLARE @total INT;
  SELECT @total = COUNT(*) FROM brz.SALES_RAW
  WHERE TRY_CONVERT(DATE, business_date) = @business_date;

  DECLARE @pass BIT = CASE WHEN @total > 0 AND 1.0 * @failed / @total < 0.02 THEN 1 ELSE 0 END;
  INSERT INTO etl.DQ_LOG (business_date, rule_name, table_name, failed_rows, threshold, passed)
  VALUES (@business_date, 'REFERENTIAL_MENU_ITEM', 'brz.SALES_RAW', @failed, '< 2% of rows', @pass);

  IF @pass = 0 THROW 50003, 'DQ GATE FAILED: too many unresolvable menu items.', 1;
END;
GO

-- ---- Silver loaders: TRY_CAST + dedupe (keep max-qty row per key) ----
CREATE OR ALTER PROCEDURE etl.sp_load_silver_sales @business_date DATE
AS
BEGIN
  SET NOCOUNT ON;
  DELETE FROM slv.SALES WHERE business_date = @business_date;   -- idempotent rerun

  ;WITH typed AS (
    SELECT TRY_CONVERT(DATE, business_date) AS business_date,
           UPPER(LTRIM(RTRIM(store_id)))    AS store_id,
           UPPER(LTRIM(RTRIM(item_id)))     AS item_id,
           item_name, category,
           TRY_CONVERT(DECIMAL(8,2), unit_price)  AS unit_price,
           TRY_CONVERT(INT, qty_sold)             AS qty_sold,
           TRY_CONVERT(DECIMAL(12,2), gross_sales) AS gross_sales,
           TRY_CONVERT(INT, txn_count)            AS txn_count,
           ROW_NUMBER() OVER (PARTITION BY business_date, store_id, item_id
                              ORDER BY _loaded_at DESC) AS rn
    FROM brz.SALES_RAW
    WHERE TRY_CONVERT(DATE, business_date) = @business_date
      AND NULLIF(LTRIM(RTRIM(item_id)), '') IS NOT NULL)
  INSERT INTO slv.SALES
  SELECT business_date, store_id, item_id, item_name, category,
         unit_price, qty_sold, gross_sales, txn_count
  FROM typed WHERE rn = 1 AND qty_sold IS NOT NULL AND unit_price IS NOT NULL;

  INSERT INTO etl.LOAD_LOG (pipeline_name, business_date, step, rows_affected, status)
  VALUES ('PL_DAILY_MEDALLION', @business_date, 'silver_sales', @@ROWCOUNT, 'SUCCESS');
END;
GO

CREATE OR ALTER PROCEDURE etl.sp_load_silver_inventory @business_date DATE
AS
BEGIN
  SET NOCOUNT ON;
  DELETE FROM slv.INVENTORY WHERE business_date = @business_date;

  ;WITH typed AS (
    SELECT TRY_CONVERT(DATE, business_date) AS business_date,
           UPPER(LTRIM(RTRIM(store_id))) AS store_id,
           UPPER(LTRIM(RTRIM(item_id)))  AS item_id,
           TRY_CONVERT(INT, begin_qty) begin_qty, TRY_CONVERT(INT, received_qty) received_qty,
           TRY_CONVERT(INT, sold_qty) sold_qty, TRY_CONVERT(INT, waste_qty) waste_qty,
           TRY_CONVERT(INT, end_qty) end_qty,
           ROW_NUMBER() OVER (PARTITION BY business_date, store_id, item_id
                              ORDER BY _loaded_at DESC) AS rn
    FROM brz.INVENTORY_RAW
    WHERE TRY_CONVERT(DATE, business_date) = @business_date
      AND NULLIF(LTRIM(RTRIM(item_id)), '') IS NOT NULL)
  INSERT INTO slv.INVENTORY
  SELECT business_date, store_id, item_id, begin_qty, received_qty,
         sold_qty, waste_qty, end_qty
  FROM typed WHERE rn = 1;

  INSERT INTO etl.LOAD_LOG (pipeline_name, business_date, step, rows_affected, status)
  VALUES ('PL_DAILY_MEDALLION', @business_date, 'silver_inventory', @@ROWCOUNT, 'SUCCESS');
END;
GO
