-- =====================================================================
-- Phase 3 — SCD Type 2 dimension upsert + idempotent fact load
-- =====================================================================

-- ---- SCD2 on DIM_MENU_ITEM ----
-- Pattern: MERGE handles (a) brand-new items -> INSERT open version,
-- (b) changed items -> close old version via UPDATE; the OUTPUT clause
-- hands the changed rows to an outer INSERT that opens their new version.
CREATE OR ALTER PROCEDURE etl.sp_upsert_dim_menu_item @business_date DATE
AS
BEGIN
  SET NOCOUNT ON;

  ;WITH src AS (
    SELECT item_id, MAX(item_name) AS item_name, MAX(category) AS category,
           MAX(unit_price) AS unit_price
    FROM slv.SALES
    WHERE business_date = @business_date
    GROUP BY item_id)

  INSERT INTO gld.DIM_MENU_ITEM (item_id, item_name, category, unit_price,
                                 ValidFrom, ValidTo, IsCurrent)
  SELECT item_id, item_name, category, unit_price, @business_date, NULL, 1
  FROM (
    MERGE gld.DIM_MENU_ITEM AS tgt
    USING src
      ON tgt.item_id = src.item_id AND tgt.IsCurrent = 1
    WHEN NOT MATCHED BY TARGET THEN               -- new menu item
      INSERT (item_id, item_name, category, unit_price, ValidFrom, ValidTo, IsCurrent)
      VALUES (src.item_id, src.item_name, src.category, src.unit_price,
              @business_date, NULL, 1)
    WHEN MATCHED AND (tgt.unit_price <> src.unit_price
                      OR ISNULL(tgt.category,'') <> ISNULL(src.category,'')
                      OR ISNULL(tgt.item_name,'') <> ISNULL(src.item_name,''))
      THEN UPDATE SET tgt.ValidTo = DATEADD(DAY, -1, @business_date),
                      tgt.IsCurrent = 0           -- close the old version
    OUTPUT $action AS merge_action, src.item_id, src.item_name,
           src.category, src.unit_price
  ) AS changes
  WHERE merge_action = 'UPDATE';                  -- re-open only the closed ones

  INSERT INTO etl.LOAD_LOG (pipeline_name, business_date, step, rows_affected, status)
  VALUES ('PL_DAILY_MEDALLION', @business_date, 'scd2_dim_menu_item', @@ROWCOUNT, 'SUCCESS');
END;
GO

-- ---- Fact load: delete+insert by date (safe to rerun any day) ----
CREATE OR ALTER PROCEDURE etl.sp_load_fact_daily_sales @business_date DATE
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @datekey INT = CONVERT(INT, FORMAT(@business_date, 'yyyyMMdd'));

  DELETE FROM gld.FACT_DAILY_SALES WHERE DateKey = @datekey;

  INSERT INTO gld.FACT_DAILY_SALES
        (DateKey, StoreKey, MenuItemKey, qty_sold, gross_sales, txn_count,
         waste_qty, waste_cost)
  SELECT @datekey,
         st.StoreKey,
         mi.MenuItemKey,
         s.qty_sold, s.gross_sales, s.txn_count,
         inv.waste_qty,
         CAST(inv.waste_qty * s.unit_price AS DECIMAL(12,2))
  FROM slv.SALES s
  JOIN gld.DIM_STORE st ON st.store_id = s.store_id
  JOIN gld.DIM_MENU_ITEM mi                       -- join to the version valid that day
    ON mi.item_id = s.item_id
   AND s.business_date >= mi.ValidFrom
   AND (mi.ValidTo IS NULL OR s.business_date <= mi.ValidTo)
  LEFT JOIN slv.INVENTORY inv
    ON inv.business_date = s.business_date
   AND inv.store_id = s.store_id AND inv.item_id = s.item_id
  WHERE s.business_date = @business_date;

  INSERT INTO etl.LOAD_LOG (pipeline_name, business_date, step, rows_affected, status)
  VALUES ('PL_DAILY_MEDALLION', @business_date, 'fact_daily_sales', @@ROWCOUNT, 'SUCCESS');
END;
GO

-- =====================================================================
-- VERIFY (matches PLAN.md acceptance) — after loading through day 10:
-- =====================================================================
-- 1. Price-changed items now have 2 versions:
--    SELECT item_id, unit_price, ValidFrom, ValidTo, IsCurrent
--    FROM gld.DIM_MENU_ITEM
--    WHERE item_id IN (SELECT item_id FROM gld.DIM_MENU_ITEM
--                      GROUP BY item_id HAVING COUNT(*) > 1)
--    ORDER BY item_id, ValidFrom;
-- 2. Fact rows join to the historically-correct version (revenue before the
--    price change uses the OLD price):
--    SELECT d.cal_date, mi.unit_price, SUM(f.gross_sales) AS revenue
--    FROM gld.FACT_DAILY_SALES f
--    JOIN gld.DIM_DATE d ON d.DateKey = f.DateKey
--    JOIN gld.DIM_MENU_ITEM mi ON mi.MenuItemKey = f.MenuItemKey
--    WHERE mi.item_id = '<a changed item>' GROUP BY d.cal_date, mi.unit_price;
-- 3. Rerun sp_load_fact_daily_sales for the same date -> row count unchanged.
