# Databricks Free Edition — verified run status

Completed in the `workspace` catalog on 2026-07-09:

| Layer | Object / outcome | Verified result |
|---|---|---:|
| Landing | Unity Catalog Volume source data | 1,417,495 POS rows; 702,124 clickstream events; 5,000 products |
| Bronze | `workspace.bronze` tables | 1,417,495 POS; 702,124 clickstream; 5,000 products |
| Silver | cleansed + quarantine tables | 1,389,049 valid sales; 17,073 quarantined sales |
| Gold | `workspace.gold.fact_sales` | 1,389,049 rows |
| Workflow | bronze → silver → gold | all three tasks succeeded (24s, 52s, 47s); 2 retries at 1-minute intervals |

The workflow job ID is `353291655645688`. It uses serverless compute and notebook
paths in the workspace user folder. A full production permissions demonstration still
needs a separate analyst principal: Free Edition currently has only the owner account.
