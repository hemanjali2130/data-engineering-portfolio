-- =====================================================================
-- Phase 1 — RETAILDW schema: bronze / silver / gold / etl
-- Run once in Azure SQL (portal Query Editor or Azure Data Studio).
-- =====================================================================

CREATE SCHEMA brz;  -- raw landing, all NVARCHAR
GO
CREATE SCHEMA slv;  -- typed + validated
GO
CREATE SCHEMA gld;  -- star schema
GO
CREATE SCHEMA etl;  -- logging + control
GO

-- ---------------- bronze ----------------
CREATE TABLE brz.SALES_RAW (
  business_date NVARCHAR(50), store_id NVARCHAR(50), item_id NVARCHAR(50),
  item_name NVARCHAR(200), category NVARCHAR(50), unit_price NVARCHAR(50),
  qty_sold NVARCHAR(50), gross_sales NVARCHAR(50), txn_count NVARCHAR(50),
  _source_file NVARCHAR(400), _loaded_at DATETIME2 DEFAULT SYSUTCDATETIME()
);
CREATE TABLE brz.INVENTORY_RAW (
  business_date NVARCHAR(50), store_id NVARCHAR(50), item_id NVARCHAR(50),
  begin_qty NVARCHAR(50), received_qty NVARCHAR(50), sold_qty NVARCHAR(50),
  waste_qty NVARCHAR(50), end_qty NVARCHAR(50),
  _source_file NVARCHAR(400), _loaded_at DATETIME2 DEFAULT SYSUTCDATETIME()
);

-- ---------------- silver ----------------
CREATE TABLE slv.SALES (
  business_date DATE NOT NULL, store_id VARCHAR(10) NOT NULL,
  item_id VARCHAR(10) NOT NULL, item_name NVARCHAR(200),
  category VARCHAR(50), unit_price DECIMAL(8,2), qty_sold INT,
  gross_sales DECIMAL(12,2), txn_count INT,
  CONSTRAINT PK_slv_SALES PRIMARY KEY (business_date, store_id, item_id)
);
CREATE TABLE slv.INVENTORY (
  business_date DATE NOT NULL, store_id VARCHAR(10) NOT NULL,
  item_id VARCHAR(10) NOT NULL, begin_qty INT, received_qty INT,
  sold_qty INT, waste_qty INT, end_qty INT,
  CONSTRAINT PK_slv_INVENTORY PRIMARY KEY (business_date, store_id, item_id)
);

-- ---------------- gold: star schema ----------------
CREATE TABLE gld.DIM_MENU_ITEM (           -- SCD Type 2
  MenuItemKey INT IDENTITY(1,1) PRIMARY KEY,
  item_id     VARCHAR(10) NOT NULL,        -- business key
  item_name   NVARCHAR(200),
  category    VARCHAR(50),
  unit_price  DECIMAL(8,2),
  ValidFrom   DATE NOT NULL,
  ValidTo     DATE NULL,                   -- NULL = open version
  IsCurrent   BIT  NOT NULL DEFAULT 1
);
CREATE INDEX IX_DIM_MENU_ITEM_BK ON gld.DIM_MENU_ITEM (item_id, IsCurrent);

CREATE TABLE gld.DIM_STORE (
  StoreKey INT IDENTITY(1,1) PRIMARY KEY,
  store_id VARCHAR(10) NOT NULL UNIQUE,
  region   VARCHAR(20)
);

CREATE TABLE gld.DIM_DATE (
  DateKey INT PRIMARY KEY,                 -- yyyymmdd
  cal_date DATE NOT NULL UNIQUE,
  day_name VARCHAR(10), week_of_year INT, [month] INT, is_weekend BIT
);

CREATE TABLE gld.FACT_DAILY_SALES (
  DateKey INT NOT NULL REFERENCES gld.DIM_DATE(DateKey),
  StoreKey INT NOT NULL REFERENCES gld.DIM_STORE(StoreKey),
  MenuItemKey INT NOT NULL REFERENCES gld.DIM_MENU_ITEM(MenuItemKey),
  qty_sold INT, gross_sales DECIMAL(12,2), txn_count INT,
  waste_qty INT, waste_cost DECIMAL(12,2),
  CONSTRAINT PK_FACT_DAILY_SALES PRIMARY KEY (DateKey, StoreKey, MenuItemKey)
);

-- ---------------- etl: control & logging ----------------
CREATE TABLE etl.LOAD_LOG (
  LoadId INT IDENTITY(1,1) PRIMARY KEY,
  pipeline_name NVARCHAR(100), business_date DATE, step NVARCHAR(50),
  rows_affected INT, status NVARCHAR(20), message NVARCHAR(2000),
  logged_at DATETIME2 DEFAULT SYSUTCDATETIME()
);
CREATE TABLE etl.DQ_LOG (
  DqId INT IDENTITY(1,1) PRIMARY KEY,
  business_date DATE, rule_name NVARCHAR(100), table_name NVARCHAR(100),
  failed_rows INT, threshold NVARCHAR(50), passed BIT,
  logged_at DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- ---------------- seed DIM_DATE + DIM_STORE ----------------
;WITH d AS (
  SELECT CAST('2026-05-01' AS DATE) AS cal_date
  UNION ALL SELECT DATEADD(DAY, 1, cal_date) FROM d WHERE cal_date < '2026-06-30'
)
INSERT INTO gld.DIM_DATE (DateKey, cal_date, day_name, week_of_year, [month], is_weekend)
SELECT CONVERT(INT, FORMAT(cal_date, 'yyyyMMdd')), cal_date,
       DATENAME(WEEKDAY, cal_date), DATEPART(ISO_WEEK, cal_date),
       MONTH(cal_date),
       CASE WHEN DATENAME(WEEKDAY, cal_date) IN ('Saturday','Sunday') THEN 1 ELSE 0 END
FROM d OPTION (MAXRECURSION 100);

INSERT INTO gld.DIM_STORE (store_id, region) VALUES
 ('GMU01','Campus'), ('GMU02','Campus'), ('FFX01','Fairfax'),
 ('ARL01','Arlington'), ('DCA01','DC');
GO
