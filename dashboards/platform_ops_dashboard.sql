-- InvestSphere PLATFORM-OPERATIONS dashboard (AI/BI). Paste each query into a tile.
-- This is the "is the platform healthy?" view for data engineers / on-call -- distinct
-- from the business dashboard (exposure/breaches).
--
-- NOTE: system-table names evolve; verify in your workspace (system.lakeflow.*,
-- system.billing.usage). Tiles 3-5 use the project's own governance tables.

-- TILE 1: recent job run outcomes (last 7 days)
SELECT job_id, run_id, result_state, period_start_time, period_end_time
FROM system.lakeflow.job_run_timeline
WHERE period_start_time >= current_timestamp() - INTERVAL 7 DAYS
ORDER BY period_start_time DESC
LIMIT 100;

-- TILE 2: serverless / job spend in the last 30 days (cost watch)
SELECT usage_date, sku_name, round(sum(usage_quantity), 2) AS dbus
FROM system.billing.usage
WHERE usage_date >= current_date() - INTERVAL 30 DAYS
GROUP BY usage_date, sku_name
ORDER BY usage_date DESC;

-- TILE 3: latest data-quality check results (pass/fail)
SELECT check_name, metric_value, threshold, passed
FROM investsphere.governance.dq_results
QUALIFY row_number() OVER (PARTITION BY check_name ORDER BY check_timestamp DESC) = 1;

-- TILE 4: transaction quarantine-rate trend
SELECT date(check_timestamp) AS day, max(metric_value) AS quarantine_rate_pct
FROM investsphere.governance.dq_results
WHERE check_name = 'transaction_quarantine_rate_pct'
GROUP BY date(check_timestamp)
ORDER BY day DESC;

-- TILE 5: Gold freshness -- latest as_of_date present in the holding fact
SELECT max(as_of_date) AS latest_holding_date,
       count(DISTINCT portfolio_id) AS portfolios_loaded
FROM investsphere.gold.fact_daily_holding;

-- TILE 6: open breaches on the latest date
SELECT count(*) AS breach_count
FROM investsphere.gold.fact_limit_breach
WHERE as_of_date = (SELECT max(as_of_date) FROM investsphere.gold.fact_limit_breach);


-- =====================================================================================
-- PRODUCTION OBSERVABILITY (system tables)
-- =====================================================================================
-- The tiles below read Databricks SYSTEM TABLES for fleet-wide ops/cost/security signals.
-- They require:
--   * system tables to be ENABLED for the workspace (the relevant system schemas --
--     system.lakeflow, system.billing, system.access, system.compute -- must be turned on
--     via the account/metastore: `SYSTEM SCHEMA ENABLE`), AND
--   * the querying principal to hold SELECT on those system schemas (granted on the
--     `system` catalog by a metastore admin).
-- IMPORTANT: exact system-table / column names vary by workspace, region, and rollout
-- stage. Verify with `SHOW TABLES IN system.lakeflow;` etc. and adjust names/filters below.

-- TILE 7: daily job runs -- total vs FAILED (last 30 days), with workflow name.
--   system.lakeflow.job_run_timeline.result_state in
--   ('SUCCEEDED','FAILED','CANCELED','TIMED_OUT','INTERNAL_ERROR', ...).
SELECT
  date(t.period_start_time)                                              AS run_day,
  coalesce(j.name, cast(t.job_id AS STRING))                            AS workflow,
  count(*)                                                              AS total_runs,
  sum(CASE WHEN t.result_state IN ('FAILED','TIMED_OUT','INTERNAL_ERROR')
           THEN 1 ELSE 0 END)                                          AS failed_runs
FROM system.lakeflow.job_run_timeline t
LEFT JOIN system.lakeflow.jobs j
       ON t.job_id = j.job_id
      AND t.workspace_id = j.workspace_id
WHERE t.period_start_time >= current_timestamp() - INTERVAL 30 DAYS
GROUP BY run_day, workflow
ORDER BY run_day DESC, failed_runs DESC;

-- TILE 8: explicit FAILED job runs (last 7 days) -- on-call triage list.
SELECT
  coalesce(j.name, cast(t.job_id AS STRING)) AS workflow,
  t.job_id, t.run_id, t.result_state,
  t.period_start_time, t.period_end_time
FROM system.lakeflow.job_run_timeline t
LEFT JOIN system.lakeflow.jobs j
       ON t.job_id = j.job_id
      AND t.workspace_id = j.workspace_id
WHERE t.result_state IN ('FAILED','TIMED_OUT','INTERNAL_ERROR')
  AND t.period_start_time >= current_timestamp() - INTERVAL 7 DAYS
ORDER BY t.period_start_time DESC
LIMIT 200;

-- TILE 9: average job-duration TREND per workflow (minutes, last 30 days).
SELECT
  date(t.period_start_time)                                            AS run_day,
  coalesce(j.name, cast(t.job_id AS STRING))                          AS workflow,
  round(avg(timestampdiff(SECOND, t.period_start_time, t.period_end_time)) / 60.0, 2)
                                                                       AS avg_duration_min
FROM system.lakeflow.job_run_timeline t
LEFT JOIN system.lakeflow.jobs j
       ON t.job_id = j.job_id
      AND t.workspace_id = j.workspace_id
WHERE t.period_end_time IS NOT NULL
  AND t.period_start_time >= current_timestamp() - INTERVAL 30 DAYS
GROUP BY run_day, workflow
ORDER BY run_day DESC, avg_duration_min DESC;

-- TILE 10: job COST by workflow (last 30 days).
--   NOTE: system.billing.usage records DBUs (usage_quantity), NOT currency. To get $ you
--   must join system.billing.list_prices (see TILE 12). usage.usage_metadata.job_id ties a
--   serverless/jobs usage row to its workflow.
SELECT
  coalesce(j.name, cast(u.usage_metadata.job_id AS STRING))           AS workflow,
  u.sku_name,
  round(sum(u.usage_quantity), 2)                                     AS total_dbus
FROM system.billing.usage u
LEFT JOIN system.lakeflow.jobs j
       ON u.usage_metadata.job_id = j.job_id
      AND u.workspace_id = j.workspace_id
WHERE u.usage_date >= current_date() - INTERVAL 30 DAYS
  AND (u.usage_metadata.job_id IS NOT NULL OR u.sku_name ILIKE '%JOBS%')
GROUP BY workflow, u.sku_name
ORDER BY total_dbus DESC;

-- TILE 11: SERVERLESS cost TREND (DBUs/day, last 30 days).
SELECT
  u.usage_date,
  u.sku_name,
  round(sum(u.usage_quantity), 2)                                     AS dbus
FROM system.billing.usage u
WHERE u.usage_date >= current_date() - INTERVAL 30 DAYS
  AND u.sku_name ILIKE '%SERVERLESS%'
GROUP BY u.usage_date, u.sku_name
ORDER BY u.usage_date DESC;

-- TILE 12: TOP EXPENSIVE JOBS in real currency (last 30 days).
--   Converts DBUs -> $ by joining the price effective on each usage_date. list_prices uses
--   price ranges (price_start_time / price_end_time); pick the row whose range covers the day.
WITH priced AS (
  SELECT
    u.usage_metadata.job_id                                    AS job_id,
    u.workspace_id,
    u.usage_quantity * lp.pricing.effective_list.default       AS cost_usd
  FROM system.billing.usage u
  JOIN system.billing.list_prices lp
    ON u.sku_name = lp.sku_name
   AND u.usage_unit = lp.usage_unit
   AND u.usage_end_time >= lp.price_start_time
   AND (lp.price_end_time IS NULL OR u.usage_end_time < lp.price_end_time)
  WHERE u.usage_date >= current_date() - INTERVAL 30 DAYS
    AND u.usage_metadata.job_id IS NOT NULL
)
SELECT
  coalesce(j.name, cast(p.job_id AS STRING))                   AS workflow,
  round(sum(p.cost_usd), 2)                                    AS cost_usd_30d
FROM priced p
LEFT JOIN system.lakeflow.jobs j
       ON p.job_id = j.job_id
      AND p.workspace_id = j.workspace_id
GROUP BY workflow
ORDER BY cost_usd_30d DESC
LIMIT 20;

-- TILE 13: SQL WAREHOUSE usage / cost (last 30 days).
--   SQL warehouse consumption is billed under SKUs containing 'SQL'. usage_metadata may
--   carry warehouse_id depending on rollout; group on it when present.
SELECT
  u.usage_date,
  u.usage_metadata.warehouse_id                                AS warehouse_id,
  u.sku_name,
  round(sum(u.usage_quantity), 2)                              AS dbus
FROM system.billing.usage u
WHERE u.usage_date >= current_date() - INTERVAL 30 DAYS
  AND u.sku_name ILIKE '%SQL%'
GROUP BY u.usage_date, warehouse_id, u.sku_name
ORDER BY u.usage_date DESC, dbus DESC;

-- TILE 14: GOVERNANCE AUDIT -- GRANT / permission changes (last 30 days).
--   system.access.audit captures Unity Catalog / account actions. Permission-changing
--   actions surface as names containing 'Grant'/'Permission'/'updatePermissions'.
SELECT
  a.event_time,
  a.user_identity.email                                        AS actor,
  a.service_name,
  a.action_name,
  a.request_params
FROM system.access.audit a
WHERE a.event_date >= current_date() - INTERVAL 30 DAYS
  AND (a.action_name ILIKE '%Grant%'
       OR a.action_name ILIKE '%Permission%'
       OR a.action_name ILIKE '%updatePermissions%')
ORDER BY a.event_time DESC
LIMIT 200;

-- TILE 15: SECURITY -- FAILED LOGINS (last 30 days).
--   Login attempts appear under the accounts/auth services; failures carry a non-zero
--   response.status_code or an error message. Column shapes vary -- adjust the filter.
SELECT
  a.event_time,
  a.user_identity.email                                        AS actor,
  a.source_ip_address,
  a.action_name,
  a.response.status_code                                       AS status_code,
  a.response.error_message                                     AS error_message
FROM system.access.audit a
WHERE a.event_date >= current_date() - INTERVAL 30 DAYS
  AND a.action_name ILIKE '%login%'
  AND (a.response.status_code <> 200 OR a.response.error_message IS NOT NULL)
ORDER BY a.event_time DESC
LIMIT 200;

-- TILE 16: AI / VECTOR SEARCH activity (BEST EFFORT -- availability varies).
--   There is no stable dedicated system table for Vector Search indexes in every region.
--   Two practical signals:
--   (a) Vector Search endpoint COST -- serverless usage whose SKU mentions vector search:
SELECT
  u.usage_date, u.sku_name,
  round(sum(u.usage_quantity), 2)                              AS dbus
FROM system.billing.usage u
WHERE u.usage_date >= current_date() - INTERVAL 30 DAYS
  AND (u.sku_name ILIKE '%VECTOR%' OR u.sku_name ILIKE '%SEARCH%')
GROUP BY u.usage_date, u.sku_name
ORDER BY u.usage_date DESC;
--   (b) Index SYNC jobs as ordinary workflow runs (if you wrap syncs in a Lakeflow job,
--       name it 'vector_index_sync%' and it shows up via TILE 7/8). Adjust the name filter:
-- SELECT * FROM system.lakeflow.jobs WHERE name ILIKE '%vector%' OR name ILIKE '%index%';

-- TILE 17: DATA-QUALITY FAILURE TREND -- DQ checks that FAILED over time.
--   Sourced from the project's own governance table (not a system table). Pairs naturally
--   with the system-table ops view above for a single "platform health" dashboard.
SELECT
  date(check_timestamp)                                        AS day,
  count(*)                                                     AS failed_checks,
  collect_set(check_name)                                      AS failing_check_names
FROM investsphere.governance.dq_results
WHERE passed = false
  AND check_timestamp >= current_timestamp() - INTERVAL 30 DAYS
GROUP BY date(check_timestamp)
ORDER BY day DESC;
