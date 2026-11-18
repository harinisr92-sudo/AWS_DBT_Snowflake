# AWS_DBT_Snowflake

An end-to-end analytics engineering project that uses **dbt** to transform Airbnb-style booking data in **Snowflake** using a **medallion (bronze / silver / gold) architecture**.

The dbt project lives in [`hsr_dbt_practice/`](hsr_dbt_practice). The repository root is a Python project (managed with [`uv`](https://docs.astral.sh/uv/)) that pins the dbt dependencies.

---

## Tech Stack

| Component | Details |
|-----------|---------|
| Transformation | dbt-core `>=1.12.7` |
| Warehouse adapter | dbt-snowflake `>=1.12.5` |
| Warehouse | Snowflake (database `AIRBNB`) |
| Language / tooling | Python `>=3.13`, `uv` for dependency management |

---

## Repository Structure

```
AWS_DBT_Snowflake/
├── pyproject.toml            # Python project + dbt dependencies
├── uv.lock                   # Locked dependency versions
├── .python-version
├── src/aws_dbt_snowflake/    # Placeholder Python package
└── hsr_dbt_practice/         # dbt project
    ├── dbt_project.yml
    ├── models/
    │   ├── sources/          # Source definitions (AIRBNB.STAGING)
    │   ├── bronze/           # Raw, incrementally loaded copies of sources
    │   ├── silver/           # Cleaned and enriched tables
    │   ├── gold/             # Business-ready OBT and fact table
    │   │   └── ephemeral/    # Ephemeral dimension feeders for snapshots
    │   └── demo/             # Simple demo view
    ├── snapshots/            # SCD Type 2 dimensions (YAML-defined)
    ├── macros/               # Reusable Jinja macros
    ├── tests/                # Singular data tests
    └── analyses/             # Ad-hoc / Jinja practice queries
```

---

## Data Flow

```
AIRBNB.STAGING (source: listings, bookings, hosts)
        │
        ▼
   BRONZE   bronze_bookings, bronze_listings, bronze_hosts
        │   (incremental, SELECT * with CREATED_AT high-water mark)
        ▼
   SILVER   silver_bookings, silver_listings, silver_hosts
        │   (incremental merge on business key, light transformations)
        ▼
   GOLD     obt  ──►  ephemeral: bookings, listings, hosts
                              │
                              ▼
                  Snapshots: dim_bookings, dim_listings, dim_hosts (SCD2)
                              │
                              ▼
                            fact
```

### Sources
Defined in `models/sources/sources.yml`: source `staging` in database `AIRBNB`, schema `staging`, with the tables `listings`, `bookings` and `hosts`.

### Bronze
Incremental models that copy the raw source tables. New rows are picked up with `CREATED_AT > max(CREATED_AT)` of the existing target table.

### Silver
Incremental models that merge on a unique key.

| Model | Unique key | Transformations |
|-------|-----------|-----------------|
| `silver_bookings` | `BOOKING_ID` | `TOTAL_AMOUNT = round(NIGHTS_BOOKED * BOOKING_AMOUNT, 2) + CLEANING_FEE + SERVICE_FEE` (via the `multiply` macro) |
| `silver_listings` | `LISTING_ID` | Adds `PRICE_PER_NIGHT_TAG` (`low` / `medium` / `high`) using the `tag` macro |
| `silver_hosts` | `HOST_ID` | Replaces spaces in `HOST_NAME` with `_`; derives `QUALITY` from `RESPONSE_RATE` (`VERY GOOD` > 95, `GOOD` > 80, `FAIR` > 60, else `POOR`) |

### Gold
- **`obt`**: One Big Table. Joins `silver_bookings` -> `silver_listings` -> `silver_hosts` (left joins). Built with a Jinja config-driven loop.
- **`gold/ephemeral/{bookings,listings,hosts}`**: Ephemeral models that slice `obt` into dimension-shaped datasets. They are not materialized and exist to feed the snapshots.
- **Snapshots** (`snapshots/*.yml`): `dim_bookings`, `dim_listings`, `dim_hosts` track history as SCD Type 2 using the `timestamp` strategy. They are written to `AIRBNB.gold`, and `dbt_valid_to_current` is set to `9999-12-31`.
- **`fact`**: Selects key and measure columns from `obt` and left joins to `dim_listings` and `dim_hosts`.

### Demo
`models/demo/demo.sql` is a view that selects directly from `AIRBNB.STAGING.LISTINGS`.

---

## Macros

| Macro | Purpose |
|-------|---------|
| `multiply(x, y, precision)` | Returns `round(x * y, precision)` |
| `tag(column_name)` | Buckets a numeric column into `low` (< 100), `medium` (< 200), `high` |
| `trimmer(column_name, node)` | Trims and upper-cases a value |
| `generate_schema_name` | Overrides dbt's default so a custom schema (`bronze`, `silver`, `gold`) is used **as-is**, without being prefixed by the target schema |

## Tests and Analyses

- `tests/source_tests.sql`: singular test, severity `warn`, that flags source bookings with `BOOKING_AMOUNT < 200`.
- `analyses/`: practice queries for Jinja loops (`loop.sql`), if/else logic (`if_else.sql`) and exploration (`explore.sql`).

---

## Getting Started

### Prerequisites
- Python 3.13+
- [`uv`](https://docs.astral.sh/uv/) installed
- A Snowflake account with access to the `AIRBNB` database, including the `STAGING` schema with the `LISTINGS`, `BOOKINGS` and `HOSTS` tables
- A role with permission to create schemas and tables in `AIRBNB` (`bronze`, `silver`, `gold`)

### 1. Install dependencies
```bash
uv sync
```

### 2. Configure the dbt profile
The project uses the profile name `hsr_dbt_practice`. Create or edit `~/.dbt/profiles.yml` (on Windows, `C:\Users\<you>\.dbt\profiles.yml`):

```yaml
hsr_dbt_practice:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: <your_account_identifier>
      user: <your_user>
      password: <your_password>      # or use key-pair / SSO authentication
      role: <your_role>
      database: AIRBNB
      warehouse: <your_warehouse>
      schema: dbt                    # default schema, used when no custom schema is set
      threads: 4
```

> Do not commit credentials. Keep `profiles.yml` outside the repository.

### 3. Verify the connection
```bash
cd hsr_dbt_practice
uv run dbt debug
```

### 4. Build the project
```bash
uv run dbt build          # models, snapshots, and tests
```

Or run the layers step by step:
```bash
uv run dbt run --select bronze
uv run dbt run --select silver
uv run dbt run --select obt
uv run dbt snapshot       # builds dim_bookings, dim_listings, dim_hosts
uv run dbt run --select fact
uv run dbt test
```

Snapshots are not included in `dbt run`. `fact` depends on `dim_listings` and `dim_hosts`, so run `dbt snapshot` before building `fact`, or use `dbt build`, which orders everything by dependency.

### Useful commands
```bash
uv run dbt build --full-refresh      # rebuild incremental models from scratch
uv run dbt compile                   # compile SQL without running it
uv run dbt docs generate && uv run dbt docs serve
```

---

## Configuration Summary (`dbt_project.yml`)

| Folder | Materialization | Schema |
|--------|-----------------|--------|
| `models/demo` | table (overridden to view in `demo.sql`) | target default |
| `models/bronze` | table (overridden to incremental in each model) | `bronze` |
| `models/silver` | table (overridden to incremental in each model) | `silver` |
| `models/gold` | table | `gold` |
| `models/gold/ephemeral` | ephemeral | `gold` |

---

## Known Limitations and Suggested Improvements

These came up while reading the code. They are not necessarily bugs, but are worth knowing about:

- **High-water mark uses `>`**: Bronze models filter with `CREATED_AT > max(CREATED_AT)`. Rows that share the latest timestamp, or arrive late, can be skipped. Consider `>=` plus a unique key, or a lookback window.
- **`models/properties.yml` references a model named `bronze`** that does not exist, and `module_level_properties.yml` sets `table` for the bronze models while the SQL overrides it to `incremental`. These can be cleaned up.
- **`fact` selects no columns from the dimensions**: It joins `dim_listings` and `dim_hosts` but only outputs `obt` columns. Add dimension keys (for example `dbt_scd_id`) if surrogate keys are intended.
- **Snapshots read from ephemeral models**, which are re-computed from `obt` on every snapshot run.
- **Snapshot `updated_at` columns** (`CREATED_AT`, `LISTINGS_CREATED_AT`, `HOST_CREATED_AT`) are creation timestamps. The timestamp strategy only captures changes if those values advance when a record changes.
- **No schema tests** (`unique`, `not_null`, `relationships`) or documentation exist yet on the models. Adding them to YAML would improve data quality coverage.
- The `trimmer` macro and the `src/aws_dbt_snowflake` Python package are placeholders and are not used by the models.

---

## Author

Harini Srinivasaraghavan

## Resources

- [dbt documentation](https://docs.getdbt.com/docs/introduction)
- [dbt-snowflake adapter docs](https://docs.getdbt.com/docs/core/connect-data-platform/snowflake-setup)
- [Snowflake documentation](https://docs.snowflake.com/)
