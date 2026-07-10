-- =====================================================================
-- Phase 2 — Landing tables + Snowpipe auto-ingestion
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE RETAIL_DW;
USE WAREHOUSE LOAD_WH;

-- ---- 1. Append-only landing tables (raw strings + load metadata) ----
CREATE OR REPLACE TABLE RAW.ORDERS_RAW (
  ORDER_ID      STRING,
  CUSTOMER_ID   STRING,
  ORDER_TS      STRING,
  STATUS        STRING,
  CHANNEL       STRING,
  ITEMS         STRING,
  ORDER_TOTAL   STRING,
  _SOURCE_FILE  STRING,
  _LOADED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE RAW.CUSTOMERS_RAW (
  CUSTOMER_ID   STRING,
  FULL_NAME     STRING,
  EMAIL         STRING,        -- PII: masked in Phase 4
  PHONE         STRING,        -- PII: masked in Phase 4
  CITY          STRING,
  STATE         STRING,
  SIGNUP_DATE   STRING,
  UPDATED_AT    STRING,
  _SOURCE_FILE  STRING,
  _LOADED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---- 2. Initial load of batch 0 (one-time COPY, so you have data now) ----
COPY INTO RAW.ORDERS_RAW (ORDER_ID, CUSTOMER_ID, ORDER_TS, STATUS, CHANNEL,
                          ITEMS, ORDER_TOTAL, _SOURCE_FILE)
  FROM (SELECT $1,$2,$3,$4,$5,$6,$7, METADATA$FILENAME FROM @RAW.S3_ORDERS)
  PATTERN = '.*batch0.*';
COPY INTO RAW.CUSTOMERS_RAW (CUSTOMER_ID, FULL_NAME, EMAIL, PHONE, CITY, STATE,
                             SIGNUP_DATE, UPDATED_AT, _SOURCE_FILE)
  FROM (SELECT $1,$2,$3,$4,$5,$6,$7,$8, METADATA$FILENAME FROM @RAW.S3_CUSTOMERS)
  PATTERN = '.*batch0.*';

SELECT COUNT(*) FROM RAW.ORDERS_RAW;      -- expect 500,000
SELECT COUNT(*) FROM RAW.CUSTOMERS_RAW;   -- expect  50,000

-- ---- 3. Pipes: from now on, files landing in S3 load themselves ----
CREATE OR REPLACE PIPE RAW.PIPE_ORDERS AUTO_INGEST = TRUE AS
  COPY INTO RAW.ORDERS_RAW (ORDER_ID, CUSTOMER_ID, ORDER_TS, STATUS, CHANNEL,
                            ITEMS, ORDER_TOTAL, _SOURCE_FILE)
  FROM (SELECT $1,$2,$3,$4,$5,$6,$7, METADATA$FILENAME FROM @RAW.S3_ORDERS);

CREATE OR REPLACE PIPE RAW.PIPE_CUSTOMERS AUTO_INGEST = TRUE AS
  COPY INTO RAW.CUSTOMERS_RAW (CUSTOMER_ID, FULL_NAME, EMAIL, PHONE, CITY, STATE,
                               SIGNUP_DATE, UPDATED_AT, _SOURCE_FILE)
  FROM (SELECT $1,$2,$3,$4,$5,$6,$7,$8, METADATA$FILENAME FROM @RAW.S3_CUSTOMERS);

-- ---- 4. Wire S3 -> Snowpipe ----
-- Copy the notification_channel (SQS ARN) from:
SHOW PIPES IN SCHEMA RAW;
-- AWS Console -> S3 bucket -> Properties -> Event notifications -> Create:
--   prefix snowflake/orders/    events: all object create  -> SQS ARN of PIPE_ORDERS
--   prefix snowflake/customers/ events: all object create  -> SQS ARN of PIPE_CUSTOMERS

-- ---- VERIFY (PLAN.md acceptance) ----
-- Drop an incremental orders file into s3://<BUCKET>/snowflake/orders/, wait ~60s:
SELECT SYSTEM$PIPE_STATUS('RETAIL_DW.RAW.PIPE_ORDERS');   -- executionState RUNNING
SELECT COUNT(*) FROM RAW.ORDERS_RAW;                       -- baseline + increment rows

SELECT FILE_NAME, ROW_COUNT, LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
     TABLE_NAME => 'RAW.ORDERS_RAW', START_TIME => DATEADD('hour', -24, CURRENT_TIMESTAMP())));

-- If a file was landed BEFORE notifications were wired: ALTER PIPE RAW.PIPE_ORDERS REFRESH;
