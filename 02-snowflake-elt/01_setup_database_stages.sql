-- =====================================================================
-- Phase 1 — Database, schemas, warehouses, file format, S3 stage
-- Run as ACCOUNTADMIN in a Snowflake worksheet, statement by statement.
-- Replace <BUCKET> and <AWS_ACCOUNT_ID> placeholders.
-- =====================================================================

USE ROLE ACCOUNTADMIN;

-- ---- 1. Warehouses: separate compute per workload, aggressive auto-suspend ----
CREATE WAREHOUSE IF NOT EXISTS LOAD_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE COMMENT = 'Snowpipe/COPY loading';
CREATE WAREHOUSE IF NOT EXISTS TRANSFORM_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE COMMENT = 'Tasks / MERGE transforms';
CREATE WAREHOUSE IF NOT EXISTS BI_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE COMMENT = 'Power BI / analyst queries';

-- ---- 2. Database + schemas (RAW -> STAGING -> ANALYTICS) ----
CREATE DATABASE IF NOT EXISTS RETAIL_DW;
CREATE SCHEMA IF NOT EXISTS RETAIL_DW.RAW;        -- landing, append-only
CREATE SCHEMA IF NOT EXISTS RETAIL_DW.STAGING;    -- conformed dims (SCD2)
CREATE SCHEMA IF NOT EXISTS RETAIL_DW.ANALYTICS;  -- facts + BI views

USE DATABASE RETAIL_DW;

-- ---- 3. File format ----
CREATE OR REPLACE FILE FORMAT RAW.FF_CSV
  TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL') ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

-- ---- 4. Storage integration (secure S3 access, no keys in SQL) ----
-- AWS side first:
--   a) IAM role "snowflake-retail-role" with policy: s3:GetObject, s3:ListBucket
--      on arn:aws:s3:::<BUCKET> and arn:aws:s3:::<BUCKET>/*
--   b) Trust policy: leave placeholder, fix in step (c) below.
CREATE OR REPLACE STORAGE INTEGRATION S3_RETAIL_INT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<AWS_ACCOUNT_ID>:role/snowflake-retail-role'
  STORAGE_ALLOWED_LOCATIONS = ('s3://<BUCKET>/snowflake/');

--   c) Run this, then paste STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID
--      into the IAM role's trust policy (Principal + sts:ExternalId condition):
DESC INTEGRATION S3_RETAIL_INT;

-- ---- 5. External stages ----
CREATE OR REPLACE STAGE RAW.S3_ORDERS
  URL = 's3://<BUCKET>/snowflake/orders/'
  STORAGE_INTEGRATION = S3_RETAIL_INT FILE_FORMAT = RAW.FF_CSV;
CREATE OR REPLACE STAGE RAW.S3_CUSTOMERS
  URL = 's3://<BUCKET>/snowflake/customers/'
  STORAGE_INTEGRATION = S3_RETAIL_INT FILE_FORMAT = RAW.FF_CSV;

-- ---- VERIFY (PLAN.md acceptance) ----
LIST @RAW.S3_ORDERS;      -- must show orders_batch0.csv
LIST @RAW.S3_CUSTOMERS;   -- must show customers_batch0.csv
