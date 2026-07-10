"""
Phase 0 — Generate 30 days of restaurant sales + inventory CSVs.

Run:    python3 00_generate_source_data.py
Output: ./adf_landing/sales_YYYYMMDD.csv      (5 stores x ~60 items x day)
        ./adf_landing/inventory_YYYYMMDD.csv

Planted for the pipeline to catch/handle:
  * ~1% duplicate sales rows           -> sp_dq_check_duplicates / silver dedupe
  * ~0.5% null item_id                 -> sp_dq_check_nulls
  * a few unknown item_ids             -> sp_dq_check_referential
  * menu price changes on day 10 & 20  -> SCD Type 2 versioning in DIM_MENU_ITEM
"""

import csv, os, random
from datetime import datetime, timedelta

random.seed(11)
OUT = "adf_landing"
os.makedirs(OUT, exist_ok=True)

START = datetime(2026, 5, 1)
DAYS = 30
STORES = ["GMU01", "GMU02", "FFX01", "ARL01", "DCA01"]
CATS = ["Entree", "Side", "Appetizer", "Drink", "Dessert"]
ITEMS = [{"item_id": f"M{n:03d}",
          "item_name": f"Menu Item {n:03d}",
          "category": random.choice(CATS),
          "price": round(random.uniform(2.5, 15.5), 2)} for n in range(1, 61)]

sales_header = ["business_date", "store_id", "item_id", "item_name", "category",
                "unit_price", "qty_sold", "gross_sales", "txn_count"]
inv_header = ["business_date", "store_id", "item_id", "begin_qty", "received_qty",
              "sold_qty", "waste_qty", "end_qty"]

for d in range(DAYS):
    day = START + timedelta(days=d)
    tag = day.strftime("%Y%m%d")

    # price changes: +6% on ~15 items at day 10, +4% on ~10 items at day 20
    if d == 10:
        for it in random.sample(ITEMS, 15):
            it["price"] = round(it["price"] * 1.06, 2)
    if d == 20:
        for it in random.sample(ITEMS, 10):
            it["price"] = round(it["price"] * 1.04, 2)

    with open(f"{OUT}/sales_{tag}.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(sales_header)
        for store in STORES:
            for it in ITEMS:
                if random.random() < 0.9:          # not every item sells daily
                    qty = random.randint(3, 120)
                    item_id = it["item_id"]
                    r = random.random()
                    if r < 0.005:
                        item_id = ""               # null item
                    elif r < 0.008:
                        item_id = f"M9{random.randint(90,99)}"  # orphan item
                    row = [day.strftime("%Y-%m-%d"), store, item_id,
                           it["item_name"], it["category"], it["price"], qty,
                           round(qty * it["price"], 2), random.randint(2, qty)]
                    w.writerow(row)
                    if random.random() < 0.01:
                        w.writerow(row)            # duplicate

    with open(f"{OUT}/inventory_{tag}.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(inv_header)
        for store in STORES:
            for it in ITEMS:
                begin = random.randint(20, 200)
                received = random.choice([0, 0, 50, 100])
                sold = min(begin + received, random.randint(3, 120))
                waste = random.randint(0, max(1, int(sold * 0.08)))
                w.writerow([day.strftime("%Y-%m-%d"), store, it["item_id"],
                            begin, received, sold, waste,
                            begin + received - sold - waste])

print(f"Wrote {DAYS} days x (sales + inventory) into ./{OUT}")
print("Upload: az storage blob upload-batch -s adf_landing -d landing "
      "--account-name <STORAGE_ACCOUNT>")
