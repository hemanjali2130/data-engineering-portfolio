"""
Phase 0 — Generate Snowflake source data: customers (with PII) + orders,
as an initial load AND 3 incremental batches (new orders + changed customer
addresses) so Snowpipe / Streams / SCD2 all have something real to do.

Run:    python3 00_generate_source_data.py
Output: ./snowflake_landing/customers/customers_batch0.csv        (50,000)
        ./snowflake_landing/orders/orders_batch0.csv              (500,000)
        ./snowflake_landing/increments/{customers,orders}_batch{1,2,3}.csv

Upload batch 0 first. Hold the increments back — drop them into S3 one at a
time later to watch Snowpipe + Tasks react.
"""

import csv, os, random
from datetime import datetime, timedelta

random.seed(7)
OUT = "snowflake_landing"
N_CUST, N_ORDERS = 50_000, 500_000
CITIES = ["Fairfax", "Arlington", "Richmond", "Austin", "Denver",
          "Seattle", "Chicago", "Atlanta", "Phoenix", "Boston"]
STATUSES = ["placed", "shipped", "delivered", "returned"]
START = datetime(2026, 1, 1)

cust_header = ["customer_id", "full_name", "email", "phone", "city", "state",
               "signup_date", "updated_at"]
order_header = ["order_id", "customer_id", "order_ts", "status", "channel",
                "items", "order_total"]

FIRST = ["Ava", "Liam", "Maya", "Noah", "Zoe", "Ethan", "Ivy", "Ray", "Nina", "Omar"]
LAST = ["Reddy", "Chen", "Patel", "Garcia", "Kim", "Nguyen", "Brown", "Silva", "Khan", "Lopez"]


def make_customer(cid, updated):
    name = f"{random.choice(FIRST)} {random.choice(LAST)}"
    return [f"C{cid:06d}", name,
            f"{name.split()[0].lower()}.{cid}@example.com",
            f"703-{random.randint(200,999)}-{random.randint(1000,9999)}",
            random.choice(CITIES), "VA",
            (START - timedelta(days=random.randint(30, 900))).strftime("%Y-%m-%d"),
            updated]


def make_order(oid, day_offset_max, updated_from=0):
    ts = START + timedelta(days=random.randint(updated_from, day_offset_max),
                           seconds=random.randint(0, 86399))
    return [f"O{oid:08d}", f"C{random.randint(1, N_CUST):06d}",
            ts.strftime("%Y-%m-%d %H:%M:%S"), random.choice(STATUSES),
            random.choice(["web", "mobile", "store"]),
            random.randint(1, 8), round(random.uniform(8, 400), 2)]


def write(path, header, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    print(f"{path}: {len(rows):,} rows")


# ---- batch 0: initial load ----
write(f"{OUT}/customers/customers_batch0.csv", cust_header,
      [make_customer(i, START.strftime("%Y-%m-%d %H:%M:%S"))
       for i in range(1, N_CUST + 1)])
write(f"{OUT}/orders/orders_batch0.csv", order_header,
      [make_order(i, 120) for i in range(1, N_ORDERS + 1)])

# ---- incremental batches 1–3 ----
oid = N_ORDERS
for b in range(1, 4):
    upd = (START + timedelta(days=120 + b)).strftime("%Y-%m-%d %H:%M:%S")
    # ~2,000 customers move city -> SCD2 must version them
    changed = []
    for cid in random.sample(range(1, N_CUST + 1), 2000):
        c = make_customer(cid, upd)
        c[4] = random.choice(CITIES)          # new city
        changed.append(c)
    # ~500 brand-new customers
    for cid in range(N_CUST + (b - 1) * 500 + 1, N_CUST + b * 500 + 1):
        changed.append(make_customer(cid, upd))
    write(f"{OUT}/increments/customers_batch{b}.csv", cust_header, changed)

    new_orders = [make_order(oid + i, 120 + b, 120 + b - 1) for i in range(1, 25001)]
    oid += 25000
    write(f"{OUT}/increments/orders_batch{b}.csv", order_header, new_orders)

print("\nUpload initial load:")
print("  aws s3 cp snowflake_landing/customers/ s3://<BUCKET>/snowflake/customers/ --recursive")
print("  aws s3 cp snowflake_landing/orders/    s3://<BUCKET>/snowflake/orders/ --recursive")
print("Later, drop increments one at a time into the same prefixes to demo the pipeline.")
