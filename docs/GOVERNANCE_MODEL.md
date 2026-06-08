# InvestSphere Governance Model

How access to the `investsphere` Unity Catalog (UC) data platform is controlled:
who can read/write which layers, how portfolio managers are restricted to their
own portfolios, how sensitive columns are masked, and where the AI/RAG security
boundary actually lives.

This document is the single source of truth for the access model. If you change
a group, a privilege, a row filter, or a mask, update the matching section here.

---

## 1. Big picture

Everything lives under one Unity Catalog catalog: **`investsphere`**.

| Schema        | What it holds                                                        |
|---------------|---------------------------------------------------------------------|
| `bronze`      | Raw ingested data (Delta + audit columns).                          |
| `silver`      | Conformed, validated, deduplicated data.                            |
| `gold`        | Dimensional star + analytics facts (what analysts/PMs consume).     |
| `governance`  | Security objects: row-filter & column-mask functions, mapping tables.|
| `ai`          | RAG corpus: `policy_chunks` (Delta source) + `policy_index` (AI Search).|
| `features`    | Curated feature tables for ML.                                      |
| `ml`          | Model artifacts / registered models / inference outputs.            |

Access is granted to **groups**, never to individual users (except break-glass
admin). Three application groups exist.

---

## 2. Group model

| Group                     | Who they are                  | What they can do                                                                 |
|---------------------------|-------------------------------|----------------------------------------------------------------------------------|
| `investsphere_engineers`  | Platform / data engineers     | Build and run pipelines. **Full read/write on all layers.** See **raw** (unmasked) data and **all** portfolios. |
| `investsphere_analysts`   | Analysts / quants             | **Read Gold analytics only.** See all portfolios (no row filter), but sensitive columns are **masked**. |
| `investsphere_pms`        | Portfolio managers            | **Read Gold**, but **row-filtered to their own portfolios** only. Sensitive columns masked. |

Key idea: engineers are the only group with write access and the only group that
bypasses both the row filter and the column mask. Analysts and PMs are read-only
on Gold; the difference between them is that PMs are additionally row-restricted.

---

## 3. Privilege matrix (group x schema x privilege)

UC privileges used here:

- **USE** = `USE CATALOG` / `USE SCHEMA` — needed just to "see"/traverse a
  catalog or schema. Without `USE`, nothing inside is reachable.
- **SELECT** = read rows from tables/views in the schema.
- **ALL** = `ALL PRIVILEGES` — read + write + create/modify objects.

`-` means no grant (not reachable).

| Schema        | `investsphere_engineers` | `investsphere_analysts`        | `investsphere_pms`             |
|---------------|--------------------------|--------------------------------|--------------------------------|
| catalog root  | USE                      | USE                            | USE                            |
| `bronze`      | **ALL**                  | -                              | -                              |
| `silver`      | **ALL**                  | -                              | -                              |
| `gold`        | **ALL**                  | USE + SELECT                   | USE + SELECT (row-filtered)    |
| `governance`  | **ALL**                  | - (functions run implicitly)   | - (functions run implicitly)   |
| `ai`          | **ALL**                  | USE + SELECT (read RAG corpus) | - (access via agent only)      |
| `features`    | **ALL**                  | -                              | -                              |
| `ml`          | **ALL**                  | -                              | -                              |

Notes:

- Analysts/PMs are **never** granted access to `bronze`/`silver`. They consume
  Gold only. (Engineers expose anything analysts need by publishing it to Gold.)
- Analysts/PMs do **not** need direct `SELECT` on `governance`. Row filters and
  column masks call governance functions **implicitly** on the table owner's
  behalf at query time — the querying user does not need `EXECUTE` on the
  function. This is why the mapping/filter logic can stay private.
- PMs read the *same* Gold tables as analysts; the row filter (Section 4) is what
  narrows their result set.

---

## 4. Row-filter design — `governance.portfolio_row_filter`

### What it does

A single row-filter function is attached **by name** to the three
portfolio-scoped Gold facts:

- `gold.fact_portfolio_exposure`
- `gold.fact_daily_holding`
- `gold.fact_limit_breach`

Each is attached with `SET ROW FILTER governance.portfolio_row_filter ON (portfolio_id)`.
When any user queries one of these tables, UC silently wraps the query so that
only rows the function approves are returned.

### The logic

```sql
CREATE OR REPLACE FUNCTION governance.portfolio_row_filter(pid STRING)
RETURN
  -- Engineers and analysts: see ALL portfolios (override).
  is_account_group_member('investsphere_engineers')
  OR is_account_group_member('investsphere_analysts')
  -- Everyone else (PMs): only portfolios mapped to them.
  OR EXISTS (
       SELECT 1
       FROM governance.pm_portfolio_map m
       WHERE m.pm_user = current_user()
         AND m.portfolio_id = pid
     );
```

- The function receives the **column value** of the row being tested (the
  `portfolio_id` of that row), bound to parameter `pid`.
- Engineers and analysts short-circuit to `TRUE` → they see every row
  (the **engineering/analyst override**).
- A PM only sees a row if `(current_user(), that portfolio_id)` exists in
  `governance.pm_portfolio_map`.

### The contract (read this — it is the #1 source of bugs)

The filter parameter and the mapping-table columns must follow **one contract**:

> The mapping table column is **`portfolio_id`**, joined against the filter's
> portfolio parameter; the user column is **`pm_user`**, joined against
> `current_user()`.

If someone renames the mapping column (e.g. `portfolio_id` → `port_id`) or the
parameter, the query does not fail loudly at attach time — it breaks **later**
with a confusing `UNRESOLVED_COLUMN` error when a PM runs a query. Keep the names
`pm_user` and `portfolio_id` stable, or change all three places at once
(function body, mapping table, any docs/tests).

---

## 5. Column-mask design — `governance.mask_counterparty_id`

### What it does

A column-mask function is attached **by name** to one sensitive column:

- `silver.silver_transaction.counterparty_id`
  via `ALTER ... ALTER COLUMN counterparty_id SET MASK governance.mask_counterparty_id`.

When the column is read, UC passes the cell value through the mask function and
returns whatever the function returns.

### The logic

```sql
CREATE OR REPLACE FUNCTION governance.mask_counterparty_id(cpty STRING)
RETURN
  CASE
    WHEN is_account_group_member('investsphere_engineers') THEN cpty   -- raw
    ELSE '***MASKED***'                                                -- everyone else
  END;
```

- **Engineers** get the raw `counterparty_id` (the **engineer override**).
- Every other principal sees the literal `***MASKED***`.

Note: `counterparty_id` lives in **Silver**, which only engineers can query
directly today. The mask is still attached as **defense-in-depth** — if a future
view or grant exposes Silver, the mask already protects the column without any
further change.

---

## 6. Portfolio-manager mapping table — `governance.pm_portfolio_map`

This table is the data behind the row filter for PMs.

| Column         | Type   | Meaning                                                   |
|----------------|--------|-----------------------------------------------------------|
| `pm_user`      | STRING | The PM's UC principal (matches `current_user()`, e.g. an email/UPN). |
| `portfolio_id` | STRING | A portfolio that PM is allowed to see.                    |

- One row per **(PM, portfolio)** pair. A PM managing 4 portfolios has 4 rows.
- **Who maintains it:** the platform/governance owner (an `investsphere_engineers`
  admin). PMs cannot self-grant — they have no write access to `governance`.
- **How PMs get mapped:** onboarding adds rows here (manually or from an HR/IBOR
  feed). Off-boarding **deletes** the PM's rows; access disappears on the next
  query (see lazy evaluation below) — no table re-grant needed.
- The values in `pm_user` must exactly match what `current_user()` returns in
  UC, otherwise the PM silently sees zero rows.

---

## 7. RAG approved-document boundary (why UC can't protect the index)

The AI copilot answers questions by retrieving chunks from
`ai.policy_chunks` (vector-searched via `ai.policy_index`, Databricks AI Search).

**Critical fact:** Databricks AI Search **cannot** enforce row-level security or
column masks at retrieval time. It also **cannot index a Delta table that has a
row filter or column mask** attached. Once data is synced into the index, the
index carries **no** row/column security — anyone who can query the assistant can
retrieve any indexed chunk.

Therefore the security boundary for RAG is **not** a UC policy on the index. It is
**pre-filtering the corpus before indexing** — an **allowlist**:

| Document                               | Indexed? |
|----------------------------------------|----------|
| `investment_policy_statement.pdf`      | YES (approved) |
| `portfolio_risk_guidelines.pdf`        | YES (approved) |
| `listed_equity_research_note.pdf`      | YES (approved) |
| `private_investment_committee_memo.pdf`| **NO (restricted — never indexed)** |

Restricted documents are **never chunked** into `ai.policy_chunks`, so they cannot
be retrieved. Details, versioning, de-indexing and tests live in
[`RAG_GOVERNANCE.md`](RAG_GOVERNANCE.md). AI Search additionally requires UC +
serverless compute + Change Data Feed (CDF) on the source Delta table.

---

## 8. Operational note — lazy evaluation + reference-by-name

Two UC behaviors you must understand to operate this safely:

1. **Filters and masks evaluate LAZILY, at query time.** They are not baked into
   the data. Editing `pm_portfolio_map` or redefining a function changes results
   on the **very next query** — no backfill, no re-grant, no table rewrite.

2. **They are referenced BY NAME.** A table stores "filter =
   `governance.portfolio_row_filter`", not a copy of the function body. So
   **fixing the function once fixes every table it is attached to.** You do not
   re-attach to each of the three facts.

Why this matters (the bug to never repeat): because nothing is validated until a
query runs, a column-name drift between the function and `pm_portfolio_map` (the
`pm_user` / `portfolio_id` contract in Section 4) stays invisible until a PM runs
a query and hits `UNRESOLVED_COLUMN`. Treat the column names as a frozen contract;
change function + table + tests together.

---

## 9. Future enhancement — ABAC (attribute-based access control)

**Current documented choice:** table-level `SET ROW FILTER` / `SET MASK` on a
small, explicit set of tables (three facts + one column). This is simple,
auditable, and correct for today's scope.

**The scale problem it eventually hits:** every new portfolio-scoped table needs
its own `SET ROW FILTER` statement, and every new sensitive column its own
`SET MASK`. With dozens of tables that becomes repetitive and easy to forget,
leaving a table accidentally unfiltered.

**Databricks' recommended answer at scale: ABAC.** You define **governed tags**
(e.g. `pii`, `portfolio_scoped`) and attach them at the **catalog or schema
level**, then write **ABAC policies** that say "any column tagged `pii` is masked
by function X" / "any table tagged `portfolio_scoped` is filtered by function Y."
The policy applies **automatically** to every current and future object carrying
the tag — no per-table statement.

**When to migrate to ABAC:**

- More than a handful of tables need the **same** row filter or the same mask.
- New tables are being added frequently and "did we remember to attach the
  filter?" becomes a real risk.
- You want consistent enforcement guaranteed by a tag/policy rather than by
  remembering to run `SET ROW FILTER` each time.

Until those triggers hit, **table-level filters/masks remain the documented,
in-force approach.**
