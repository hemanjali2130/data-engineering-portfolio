# Phase 4 — Build `PL_DAILY_MEDALLION` in ADF Studio

Low-code by design: two Copy activities + six Stored Procedure activities,
chained on success. Roughly 60–90 minutes in the UI.

## 1. Linked services (Manage → Linked services)
- `LS_Blob` → Azure Blob Storage → your storage account (account key auth is fine here)
- `LS_AzureSQL` → Azure SQL Database → RETAILDW (SQL auth; allow Azure services in
  the SQL server firewall)

## 2. Datasets
| Name | Type | Points at | Notes |
|---|---|---|---|
| `DS_SalesCsv` | DelimitedText | `landing/sales_@{ds}.csv` | parameter `p_date` (yyyyMMdd), first row header |
| `DS_InvCsv` | DelimitedText | `landing/inventory_@{ds}.csv` | same parameter |
| `DS_SalesRaw` | Azure SQL | `brz.SALES_RAW` | |
| `DS_InvRaw` | Azure SQL | `brz.INVENTORY_RAW` | |

Use dynamic content for the file name, e.g.
`@concat('sales_', dataset().p_date, '.csv')`.

## 3. Pipeline `PL_DAILY_MEDALLION`
Pipeline parameter: `p_business_date` (string, e.g. `2026-05-01`).
Derived: `p_date_tag = @{formatDateTime(pipeline().parameters.p_business_date,'yyyyMMdd')}`.

Activity chain (each connected on **Success**):

```
1. Copy_Sales_To_Bronze        (Copy: DS_SalesCsv  -> DS_SalesRaw)
2. Copy_Inventory_To_Bronze    (Copy: DS_InvCsv    -> DS_InvRaw)
3. DQ_Nulls        (Stored Proc: etl.sp_dq_check_nulls        @business_date)
4. DQ_Duplicates   (Stored Proc: etl.sp_dq_check_duplicates   @business_date)
5. DQ_Referential  (Stored Proc: etl.sp_dq_check_referential  @business_date)
6. Load_Silver_Sales      (etl.sp_load_silver_sales      @business_date)
7. Load_Silver_Inventory  (etl.sp_load_silver_inventory  @business_date)
8. SCD2_Dim_MenuItem      (etl.sp_upsert_dim_menu_item   @business_date)
9. Load_Fact_DailySales   (etl.sp_load_fact_daily_sales  @business_date)
```

Copy activity mapping tips: import schemas after uploading one real file; add an
additional column `_source_file` = `@{item().name}` or the dataset file name.

**Why the order matters (interview line):** DQ gates run against bronze *before*
any transformation spend; a `THROW` in steps 3–5 fails the run and nothing
downstream executes — bad data never reaches gold/reporting.

## 4. Backfill the 30 days
Wrap the chain in a **ForEach** over
`@range(0, 30)` with `p_business_date = addDays('2026-05-01', item())`
(sequential, batch 1), or simpler: run the pipeline manually for a handful of dates
including day 10 and day 20 (the SCD2 price-change days).

## 5. Trigger + alerting
- **Trigger:** New/Edit → Schedule → daily 06:00, pass
  `p_business_date = @{formatDateTime(addDays(utcNow(),-1),'yyyy-MM-dd')}` (yesterday).
- **Alert:** Monitor → Alerts & metrics → New alert rule → metric *Failed pipeline
  runs* → action group with your email. Test it by loading a file you've doctored
  to breach a gate (delete most item_ids from a copy of one sales file).

## 6. Evidence to capture for GitHub
- Green end-to-end run in Monitor (pipeline run details, all 9 activities)
- A red run showing the failure stopping at `DQ_Nulls`, plus the matching
  `etl.DQ_LOG` row and the alert email
- `gld.DIM_MENU_ITEM` two-version screenshot after day 10
- Optional: a Power BI page on `gld.FACT_DAILY_SALES` (sales, waste cost by store) —
  reuses your existing dashboard skills and completes the bronze→gold→BI story.
