# Data Contracts

This folder holds one **data contract** per upstream source feeding the InvestSphere
lakehouse. Contracts are written in YAML so they are **machine-readable** (a pipeline, a
test, or a CI check can load them) as well as human-readable.

---

## 1. What is a data contract?

A data contract is a written, version-controlled agreement between the team that
**produces** data (upstream) and the team that **consumes** it (us, the data platform).

It answers, for one source:

- **Who owns it?** (`source_owner`) and when will it arrive? (`sla`)
- **How does it arrive?** (`format`, `landing_path`, `filename_pattern`)
- **What columns and types are promised?** (`required_columns`)
- **What identifies a row?** (`primary_key` / `natural_key`)
- **What values are legal?** (`accepted_values`)
- **What happens when the shape changes?** (`schema_evolution`)
- **What rules must the data pass, and how hard do we react if it fails?** (`dq_rules`)

The contract is the **source of truth for the agreement**. The actual Spark column names
and types live in `pipelines/schemas.py`; each contract is kept consistent with it.

---

## 2. How a contract maps to this project's layers

Data flows **Bronze -> Silver -> Gold**. The contract drives the first two.

### Bronze = "land everything, rescue surprises"
`pipelines/bronze_ingest.py` uses Databricks **Auto Loader** with:

- the **explicit schema** from `schemas.py` (no guessing),
- `schemaEvolutionMode = "rescue"` and a `_rescued_data` column.

So if a producer adds, renames, or mistypes a column, the unexpected value is **captured
in `_rescued_data` instead of crashing the stream or silently changing the table**. Every
Bronze row also gets audit columns stamped by the platform:

| Column          | Meaning                                  |
|-----------------|------------------------------------------|
| `_ingest_ts`    | when we ingested the row                 |
| `_source_file`  | which file it came from                  |
| `_batch_id`     | which ingestion batch wrote it           |
| `_rescued_data` | non-null => schema drift to review       |

This is the `schema_evolution.policy: rescue` you see in every contract.

### Silver = three reaction tiers (FAIL / QUARANTINE / WARN)
`pipelines/silver_conform.py` validates Bronze against the contract and reacts at one of
three severities. Every rule in a contract's `dq_rules` is tagged with its `tier`:

| Tier         | What it means                                                                 | Example rule |
|--------------|-------------------------------------------------------------------------------|--------------|
| **FAIL**     | Stop the job. The data is unusable / unauditable (e.g. primary key is null).  | `transaction_id IS NOT NULL` |
| **QUARANTINE** | Keep the job running, but divert the bad rows to a `quarantine_*` table for investigation. Good rows still flow to Silver. | bad FK, `quantity > 0`, invalid `transaction_type`, `_rescued_data IS NOT NULL` |
| **WARN**     | Keep the row. Note the issue (metric / log). Nothing is blocked.              | missing optional `counterparty_id`, stale freshness |

Quarantined rows are written **append-only** with a human-readable `quarantine_reason`
and full lineage (`source_table`, `source_file`, `ingestion_ts`, `business_date`,
`pipeline_run_id`, `job_run_id`, `raw_payload`). A quarantine-rate metric is published to
`governance.dq_results` so we can alert when too much data goes bad.

> In short: **Bronze rescues schema surprises; Silver enforces the contract using
> FAIL / QUARANTINE / WARN.**

---

## 3. Who owns vs. who consumes

- **Producer / owner** (the `source_owner` in each contract — e.g. Trading Systems,
  Market Data Vendor Feed, Portfolio Accounting, Reference Data Mgmt, Risk & Compliance,
  Treasury/FX) is responsible for delivering files that match the contract: right
  columns, right types, on the agreed SLA, with the agreed filename pattern.
- **Consumer** (the InvestSphere data platform team) is responsible for ingesting,
  validating, quarantining, and serving the data, and for **alerting the producer** when
  the contract is breached (e.g. rising quarantine rate, late feed, schema drift in
  `_rescued_data`).

The contract makes this boundary explicit so neither side has to guess.

---

## 4. How a contract change is reviewed

Contracts and `schemas.py` are version-controlled, so a change is a reviewed pull request.

1. **Drift is detected first, safely.** A new/renamed/mistyped column shows up as non-null
   `_rescued_data` in Bronze (and quarantined rows in Silver). Nothing breaks; nothing is
   auto-promoted.
2. **An engineer reviews `_rescued_data`** to understand what the producer changed and
   confirms it with the `source_owner`.
3. **Classify the change:**
   - **Additive** (a genuinely new optional column): `allowed-via-review`. Update
     `schemas.py` to add the column, then update the contract's `required_columns` and any
     `accepted_values` / `dq_rules`. The new column flows into Bronze on the next run.
   - **Breaking** (dropping, renaming, or retyping a required column): `not-allowed`
     without a coordinated change. This is a contract breach — the producer must fix the
     feed, or both sides agree a migration and bump the contract together.
4. **Update both artifacts in the same PR** (`schemas.py` + the relevant contract YAML) so
   the agreement and the code never drift apart, and get sign-off from a platform engineer
   (and the producer for breaking changes).

---

## 5. File index

| Contract | Source owner | Format | Cadence |
|----------|--------------|--------|---------|
| `investment_transactions.yml`        | Trading Systems       | json | daily |
| `listed_market_prices.yml`           | Market Data Vendor Feed | csv | daily |
| `investment_holdings_snapshot.yml`   | Portfolio Accounting  | csv  | daily |
| `portfolio_master.yml`               | Reference Data Mgmt   | csv  | monthly |
| `investment_asset_master.yml`        | Reference Data Mgmt   | csv  | monthly |
| `investment_limits.yml`              | Risk & Compliance     | csv  | monthly |
| `currency_rates.yml`                 | Treasury/FX           | csv  | daily |
| `counterparty_master.yml`            | Reference Data Mgmt   | csv  | monthly |

Each YAML uses the **same key order** so they are easy to diff and read.
