"""
00_load_data.py
Loads the Dunnhumby "The Complete Journey" CSV files into PostgreSQL.

Before running:
1. Create an empty database named "dunnhumby" in pgAdmin.
2. Download the dataset from Kaggle and place the CSV files in data/archive (1)/
3. Install packages: pip install pandas sqlalchemy "psycopg[binary]"

Run from any folder:  python sql/00_load_data.py
The script asks for the postgres password at runtime. Nothing is stored in this file.

Notes:
- causal_data is not loaded. It is very large (about 36 million rows) and not needed
  for the questions in this project.
- psycopg 3 is used because psycopg2 has no prebuilt package for Python 3.14.
- Rows are loaded with PostgreSQL COPY in chunks of 200,000, which is much faster than
  inserting row by row for the 2.6 million transaction rows.
- Re-running replaces the tables, so it is safe to repeat.
"""

import getpass
from io import StringIO
from pathlib import Path

import pandas as pd
import psycopg
from sqlalchemy import create_engine
from sqlalchemy.engine import URL

# CSV folder, relative to this script: <project>/data/archive (1)/
DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "archive (1)"
DB_NAME = "dunnhumby"
TABLES = [
    "product",
    "hh_demographic",
    "campaign_desc",
    "campaign_table",
    "coupon",
    "coupon_redempt",
    "transaction_data",
]

password = getpass.getpass("postgres password: ")

# SQLAlchemy engine: used only to create each table with column types from the CSV
url = URL.create(
    "postgresql+psycopg",
    username="postgres",
    password=password,
    host="localhost",
    port=5432,
    database=DB_NAME,
)
engine = create_engine(url)

# Direct psycopg connection: used for fast loading with COPY
conn = psycopg.connect(
    dbname=DB_NAME, user="postgres", password=password, host="localhost", port=5432
)

for t in TABLES:
    path = DATA_DIR / f"{t}.csv"
    if not path.exists():
        print(f"SKIP {t}: file not found at {path}")
        continue

    total = 0
    first = True
    for chunk in pd.read_csv(path, chunksize=200_000):
        # Lowercase column names so SQL queries do not need quotes
        chunk.columns = chunk.columns.str.lower().str.strip()

        if first:
            # Create the empty table, using column types inferred from the first chunk
            chunk.head(0).to_sql(t, engine, if_exists="replace", index=False)
            first = False

        # Write the chunk to an in-memory CSV and stream it into PostgreSQL with COPY
        cols = ", ".join(f'"{c}"' for c in chunk.columns)
        buf = StringIO()
        chunk.to_csv(buf, index=False, header=False)
        buf.seek(0)

        with conn.cursor() as cur:
            with cur.copy(f'COPY "{t}" ({cols}) FROM STDIN WITH (FORMAT csv)') as copy:
                copy.write(buf.read())
        conn.commit()

        total += len(chunk)
        print(f"  {t}: {total:,} rows loaded", end="\r")

    print(f"DONE {t}: {total:,} rows" + " " * 20)

conn.close()
print("All tables loaded.")