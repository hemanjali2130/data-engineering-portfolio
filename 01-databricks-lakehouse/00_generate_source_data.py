"""
Phase 0 — Generate the three raw sources for the Retail Clickstream Lakehouse.

Run:    python3 00_generate_source_data.py
Output: ./landing/pos_sales/       14 daily CSVs   (~1.4M rows, dirty on purpose)
        ./landing/clickstream/     14 daily JSONL  (~700K events)
        ./landing/products/        1 JSON feed     (~5,000 SKUs)

Deliberate "mess" (so silver has real work to do):
  * ~0.8% duplicated POS lines            -> dedupe on business keys
  * ~0.7% null SKUs in POS                -> null-threshold DQ check
  * ~0.5% SKUs that don't exist in feed   -> referential-integrity quarantine
  * loyalty_id column appears on day 8+   -> Auto Loader schema evolution
Only the Python standard library is used.
"""

import csv, json, os, random
from datetime import datetime, timedelta

random.seed(42)
OUT = "landing"
DAYS = 14
START = datetime(2026, 4, 1)
STORES = [f"S{n:03d}" for n in range(1, 21)]
DEVICES = ["ios", "android", "web"]
EVENTS = ["page_view", "product_view", "add_to_cart", "purchase"]
CATEGORIES = ["Snacks", "Beverages", "Frozen", "Produce", "Household", "Personal Care"]
BRANDS = ["Acme", "Northline", "Vela", "Sundial", "Ridge", "Pacifica"]

SKUS = [f"SKU{n:05d}" for n in range(1, 5001)]


def gen_products():
    os.makedirs(f"{OUT}/products", exist_ok=True)
    rows = []
    for sku in SKUS:
        rows.append({
            "sku": sku,
            "name": f"{random.choice(BRANDS)} {random.choice(CATEGORIES)} Item {sku[-4:]}",
            "category": random.choice(CATEGORIES),
            "brand": random.choice(BRANDS),
            "list_price": round(random.uniform(1.5, 45.0), 2),
            "updated_at": START.strftime("%Y-%m-%dT%H:%M:%S"),
        })
    with open(f"{OUT}/products/products_feed.json", "w") as f:
        json.dump(rows, f)
    print(f"products: {len(rows)} SKUs")


def gen_pos():
    os.makedirs(f"{OUT}/pos_sales", exist_ok=True)
    total = 0
    for d in range(DAYS):
        day = START + timedelta(days=d)
        has_loyalty = d >= 7                      # schema evolution on day 8
        path = f"{OUT}/pos_sales/pos_{day:%Y%m%d}.csv"
        header = ["store_id", "txn_id", "line_id", "txn_ts", "sku",
                  "qty", "unit_price", "payment_type"]
        if has_loyalty:
            header.append("loyalty_id")
        with open(path, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(header)
            n_rows = random.randint(95000, 105000)
            for i in range(n_rows):
                store = random.choice(STORES)
                txn = f"T{day:%Y%m%d}{i//3:07d}"
                sku = random.choice(SKUS)
                r = random.random()
                if r < 0.007:
                    sku = ""                       # null SKU
                elif r < 0.012:
                    sku = f"SKU9{random.randint(9000,9999)}"  # orphan SKU
                row = [store, txn, i % 3 + 1,
                       (day + timedelta(seconds=random.randint(28800, 79200)))
                       .strftime("%Y-%m-%d %H:%M:%S"),
                       sku, random.randint(1, 6),
                       round(random.uniform(1.5, 45.0), 2),
                       random.choice(["card", "cash", "mobile"])]
                if has_loyalty:
                    row.append(f"L{random.randint(1,99999):06d}"
                               if random.random() < 0.6 else "")
                w.writerow(row)
                if random.random() < 0.008:        # duplicate line
                    w.writerow(row)
                    total += 1
            total += n_rows
        print(f"pos {day:%Y-%m-%d}: ~{n_rows} rows"
              + ("  [+loyalty_id col]" if has_loyalty else ""))
    print(f"pos total: ~{total} rows")


def gen_clickstream():
    os.makedirs(f"{OUT}/clickstream", exist_ok=True)
    total = 0
    for d in range(DAYS):
        day = START + timedelta(days=d)
        path = f"{OUT}/clickstream/events_{day:%Y%m%d}.jsonl"
        n = random.randint(48000, 52000)
        with open(path, "w") as f:
            for i in range(n):
                evt = {
                    "event_id": f"E{day:%Y%m%d}{i:07d}",
                    "user_id": f"U{random.randint(1, 40000):06d}",
                    "session_id": f"G{random.randint(1, 120000):07d}",
                    "event_type": random.choices(EVENTS, weights=[50, 30, 12, 8])[0],
                    "sku": random.choice(SKUS),
                    "event_ts": (day + timedelta(seconds=random.randint(0, 86399)))
                                .strftime("%Y-%m-%dT%H:%M:%S"),
                    "device": random.choice(DEVICES),
                }
                f.write(json.dumps(evt) + "\n")
        total += n
        print(f"clickstream {day:%Y-%m-%d}: {n} events")
    print(f"clickstream total: {total} events")


if __name__ == "__main__":
    gen_products()
    gen_pos()
    gen_clickstream()
    print("\nDone. Upload with:")
    print("  aws s3 cp landing/ s3://<YOUR_BUCKET>/landing/ --recursive")
