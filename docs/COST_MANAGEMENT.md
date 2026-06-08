# InvestSphere — Cost Management

A beginner-friendly guide to keeping InvestSphere cheap to run on **Databricks
(serverless, Unity Catalog)** without surprises on the bill.

> **Read this first — the golden rule of cloud cost:** *you pay for things that are
> turned on, not things you use.* The single biggest risk in this project is an
> **AI / Vector Search endpoint left running after a demo** (see §5). Everything else
> is good hygiene; that one is real money burning idle.

> **About the dollar figures below:** treat them as *rough anchors to reason with*,
> not invoices. Exact cost depends on **cloud, region, and SKU**, and serverless vs
> classic pricing shifts over time. **Measure your own** numbers from
> `system.billing.usage` (and the `$` tiles in
> `../dashboards/platform_ops_dashboard.sql`) before quoting anything.

Cost anchors used in this doc (verify, don't quote as gospel):
- Classic Jobs Compute ≈ **$0.15 / DBU**.
- Serverless ≈ **$0.35–0.50 / DBU** (simpler, but more $/DBU).
- AI Search STANDARD index endpoint ≈ **$0.28 / hr ≈ $200 / month**, billing until
  deleted.

Related: `../dashboards/platform_ops_dashboard.sql` (cost tiles 10–13, 16),
`../storage_lifecycle/` (ADLS tiering), `SECURITY_HARDENING.md`.

---

## 1. Dev vs prod budget rules

- **Set budget alerts** on the Databricks account (and the cloud subscription) for
  both `dev` and `prod`, e.g. alert at 50% / 80% / 100% of a monthly cap. — You hear
  about overspend *before* the invoice, not after.
- **`dev` runs small and scales to zero:** smallest warehouse/compute, short
  auto-stop, serverless so idle = $0. — Dev is for iterating, not for steady load.
- **`prod` is sized for the real workload** but still tagged and watched (the cluster
  policy enforces tags — see `SECURITY_HARDENING.md` §5). — Tags make every dollar
  attributable per env in `system.billing.usage`.
- **Separate budgets per environment** so a runaway dev experiment doesn't hide under
  prod spend. — Anomalies are easy to localize.

## 2. SQL warehouse auto-stop & right-sizing

- **Set auto-stop to ~10 minutes idle** on every SQL warehouse (lower in dev). — A
  warehouse left "on" after a query bills the whole time; auto-stop reclaims it.
- **Start at the smallest size** (e.g. 2X-Small / X-Small) and size up only if queries
  are demonstrably slow. — Most analytical/demo queries don't need a big warehouse.
- **Don't run multiple warehouses when one will do.** — Each running warehouse bills
  independently.
- **Watch warehouse spend** via dashboard TILE 13 (`sku_name ILIKE '%SQL%'`). — Catches
  an oversized or never-stopping warehouse.

## 3. Job cluster sizing — serverless vs classic

- **Default to serverless for jobs.** — Simplest operationally, scales to zero between
  runs, no idle cluster to forget about. You pay more per DBU (~$0.35–0.50) but only
  while a run is actually executing.
- **Consider classic job clusters only for steady, high-volume, predictable
  workloads.** — At ~$0.15/DBU, classic is cheaper *per DBU*; the savings only beat
  serverless when utilization is consistently high enough to amortize startup and idle.
- **Rule of thumb:** spiky / occasional / demo work → **serverless**; large daily batch
  that runs for a long time every day → **evaluate classic** and measure both. — Pick
  with numbers from `system.billing.usage`, not vibes.
- **Right-size autoscale max** (the cluster policy caps it). — Stops a job from grabbing
  a huge cluster for a small dataset.
- **Never leave a job cluster as an always-on interactive cluster.** — That converts a
  per-run cost into a 24/7 cost.

## 4. Serverless usage monitoring & cost dashboard

- **`system.billing.usage` is the source of truth.** It records **DBUs**
  (`usage_quantity`), *not dollars* — multiply by price from
  `system.billing.list_prices` to get `$`. — Don't confuse DBUs with currency.
- **Use the platform-ops dashboard cost tiles** in
  `../dashboards/platform_ops_dashboard.sql`:
  - **TILE 10** — DBUs by workflow (last 30d).
  - **TILE 11** — serverless DBU/day trend.
  - **TILE 12** — top expensive jobs in **real $** (joins `list_prices`).
  - **TILE 13** — SQL warehouse usage.
  - **TILE 16** — AI / Vector Search spend (`sku_name ILIKE '%VECTOR%' OR '%SEARCH%'`).
- Quick 30-day spend-by-SKU check (also TILE 2):
  ```sql
  SELECT usage_date, sku_name, round(sum(usage_quantity), 2) AS dbus
  FROM system.billing.usage
  WHERE usage_date >= current_date() - INTERVAL 30 DAYS
  GROUP BY usage_date, sku_name
  ORDER BY usage_date DESC;
  ```
- **Requires system tables enabled** (`SYSTEM SCHEMA ENABLE`) and `SELECT` on the
  `system` catalog. — Without these the tiles return nothing.

## 5. AI / Vector Search cost guardrails — THE main paid risk ⚠️

The endpoint **`investsphere_ai_search`** with a **STANDARD index** is a **PAID,
always-on** resource: roughly **$0.28/hr ≈ $200/month**, and it **bills continuously
until you delete it** — whether or not anyone queries it.

- **One endpoint serves many indexes.** You do not need an endpoint per index; create
  indexes on the single `investsphere_ai_search` endpoint. — Avoids paying for
  duplicate always-on endpoints.
- **After every demo / dev session: DELETE the indexes, then the endpoint.** — This is
  the #1 way to leak money in this project.
- **Charges stop ~24h after the LAST index is deleted.** Deleting one index of several
  does *not* stop billing — the endpoint keeps running for the remaining indexes. —
  Budget for that ~24h tail; don't assume "deleted = $0 instantly."
- **Monitor it** with dashboard TILE 16 and the cloud cost view. — Spot a forgotten
  endpoint the next day, not at month-end.
- **Never leave it running "just in case."** Re-creating an index from a Delta source is
  cheap and fast compared to a month of idle endpoint cost. — Recreate on demand.
- **Add it to the monthly cleanup checklist** (§8) explicitly. — Belt and suspenders.

## 6. Storage lifecycle & Delta maintenance

ADLS tiering is already defined in `../storage_lifecycle/` (`adls_lifecycle_policy.json`
+ `main.tf`). Key rules:

- **Staging is auto-deleted after 30 days** (`investsphere/staging/`). — Landing files
  are transient; don't pay to keep them.
- **Archive cools then archives** (raw: Cool 30d → Archive 180d; documents: Cool 90d). —
  Rarely-read data moves to cheaper tiers automatically.
- **Active Delta tables are EXCLUDED from generic lifecycle rules.** — Tiering/deleting
  individual Delta/Parquet files breaks the transaction log and **corrupts the table**.
  Delta storage is managed *only* by Delta maintenance below.
- **Maintain Delta with `OPTIMIZE` + `VACUUM`**, and prefer **Predictive Optimization**
  to let Databricks schedule compaction/vacuum for you. — Keeps files compact (faster +
  cheaper scans) without manual tuning.
- **NEVER `VACUUM ... RETAIN 0 HOURS`.** — It deletes files still referenced by
  in-flight readers/time-travel and can corrupt the table or break concurrent queries.
  Keep the default 7-day retention unless you have a specific, understood reason.

## 7. Cost anomaly alerting

- **Budget alerts (§1) are the first line** — account + cloud subscription thresholds.
  — Cheapest possible "something's wrong" signal.
- **Add a trend query** over `system.billing.usage` to catch spikes before the budget
  trips:
  ```sql
  -- 7-day DBU total vs the prior 7 days, by SKU. Flag big jumps.
  WITH d AS (
    SELECT sku_name,
           sum(CASE WHEN usage_date >= current_date() - INTERVAL 7  DAYS
                    THEN usage_quantity END) AS dbus_last_7,
           sum(CASE WHEN usage_date <  current_date() - INTERVAL 7  DAYS
                     AND usage_date >= current_date() - INTERVAL 14 DAYS
                    THEN usage_quantity END) AS dbus_prev_7
    FROM system.billing.usage
    WHERE usage_date >= current_date() - INTERVAL 14 DAYS
    GROUP BY sku_name
  )
  SELECT sku_name, round(dbus_last_7,2) AS last_7,
         round(dbus_prev_7,2) AS prev_7,
         round((dbus_last_7 - dbus_prev_7) / nullif(dbus_prev_7,0) * 100, 1) AS pct_change
  FROM d
  WHERE dbus_last_7 > coalesce(dbus_prev_7,0) * 1.5   -- >50% jump week-over-week
  ORDER BY pct_change DESC;
  ```
- **Route anomalies to `oncall_email`** via the existing Prometheus / Pushgateway /
  Grafana path. — Same alerting plumbing as the rest of the platform.
- **Pay special attention to VECTOR/SEARCH and SERVERLESS SKUs** in the trend. — Those
  are the SKUs most likely to creep up unnoticed.

## 8. Monthly cleanup checklist

Run on the first working day of each month (covers `dev` especially):

- [ ] **Delete stray Vector Search indexes and the `investsphere_ai_search` endpoint**
  if no longer needed. — The single biggest avoidable cost (§5).
- [ ] **Terminate / remove forgotten all-purpose clusters** and confirm auto-stop is on.
  — Idle interactive compute bills 24/7.
- [ ] **Confirm SQL warehouses have auto-stop and none are stuck running.** — A
  never-stopping warehouse is a slow leak.
- [ ] **Delete old streaming checkpoints and orphaned `_checkpoint` / tmp dirs** no
  longer tied to a live job. — Reclaims storage and avoids confusing restarts.
- [ ] **Drop unused / experimental tables and stale `dev` catalogs/schemas.** — Storage
  and metadata clutter cost money and obscure the real estate.
- [ ] **Verify staging cleanup ran** (nothing older than 30d under
  `investsphere/staging/`). — Confirms the lifecycle policy is actually applied.
- [ ] **Run / confirm `OPTIMIZE` + `VACUUM` (or Predictive Optimization) on hot Delta
  tables** — never `RETAIN 0`. — Keeps scan cost down safely.
- [ ] **Review the month's top-spend SKUs** (TILE 12 in $, plus the §7 trend). — Catch
  anything that crept up before it compounds.
- [ ] **Spot-check tags** so all spend is attributable per env/project. — Untagged spend
  is un-investigable spend.

---

### TL;DR
- Serverless + scale-to-zero is your friend; **`dev` stays tiny**.
- **Auto-stop everything** (warehouses ~10 min idle).
- **The AI Search endpoint is the real money risk — delete it after demos**; billing
  tails ~24h after the last index is removed.
- **Active Delta tables are excluded from ADLS tiering; never `VACUUM RETAIN 0`.**
- **Measure cost from `system.billing.usage`** — DBUs aren't dollars; the exact $
  depends on cloud/region/SKU.
