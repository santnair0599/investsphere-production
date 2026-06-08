-- InvestSphere RECONCILIATION checks (plain SQL -- runs on any Databricks SQL warehouse).
--
-- RECONCILIATION vs DATA QUALITY
-- ------------------------------
-- Data-quality (DQ) checks (see custom_dq_checks.sql) ask "is a single table / column
-- internally correct?" -- e.g. nulls, ranges, freshness, schema drift. They look at ONE
-- dataset at a time.
--
-- RECONCILIATION checks ask "do TWO points in the pipeline AGREE?" They are cross-table /
-- cross-stage controls that prove nothing was silently lost, duplicated, or mis-mapped as
-- data flowed Bronze -> Silver -> Gold. Classic finance examples encoded here:
--   * row-count balance across a split (Bronze == Silver valid + Quarantine),
--   * referential integrity (every holding maps to a price and an asset),
--   * additive totals (sector exposure per portfolio sums to ~100%),
--   * derived-fact consistency (every breach really does exceed its limit),
--   * feed completeness / freshness against the expected business date.
-- The expected metric for every reconciliation control below is 0 (zero discrepancies).
--
-- Parameters (passed by the EOD job's sql_task; the SQL editor prompts when ad-hoc):
--   :business_date  -- the data date being reconciled (e.g. 2026-05-29)
--   :job_run_id     -- the Databricks job run id ({{job.run_id}})

CREATE TABLE IF NOT EXISTS investsphere.governance.reconciliation_results (
  check_timestamp TIMESTAMP,
  check_name      STRING,
  source_table    STRING,
  business_date   DATE,
  pipeline_run_id STRING,
  job_run_id      STRING,
  metric_value    DOUBLE,
  threshold       DOUBLE,
  passed          BOOLEAN
);

-- 1. BRONZE vs SILVER BALANCE: every Bronze transaction for the run must end up either
--    in silver_transaction (valid) or quarantine_transaction (bad). No row may vanish.
--    metric = |bronze_count - (silver_count + quarantine_count)|  (expect 0).
INSERT INTO investsphere.governance.reconciliation_results
  (check_timestamp, check_name, source_table, business_date, pipeline_run_id, job_run_id,
   metric_value, threshold, passed)
WITH
bronze_cnt AS (
  SELECT count(*) AS c
  FROM investsphere.bronze.raw_investment_transactions
  WHERE date(transaction_date) = date(:business_date)
),
silver_cnt AS (
  SELECT count(*) AS c
  FROM investsphere.silver.silver_transaction
  WHERE date(transaction_date) = date(:business_date)
),
quarantine_cnt AS (
  SELECT count(*) AS c
  FROM investsphere.silver.quarantine_transaction
  WHERE business_date = date(:business_date)
)
SELECT current_timestamp(), 'bronze_silver_quarantine_balance',
       'bronze.raw_investment_transactions', date(:business_date), NULL, :job_run_id,
       abs((SELECT c FROM bronze_cnt) - ((SELECT c FROM silver_cnt) + (SELECT c FROM quarantine_cnt))),
       0,
       abs((SELECT c FROM bronze_cnt) - ((SELECT c FROM silver_cnt) + (SELECT c FROM quarantine_cnt))) = 0;

-- 2. DUPLICATE PRIMARY KEYS in silver_transaction (the upsert must keep transaction_id
--    unique). metric = count of transaction_id values appearing more than once (expect 0).
INSERT INTO investsphere.governance.reconciliation_results
  (check_timestamp, check_name, source_table, business_date, pipeline_run_id, job_run_id,
   metric_value, threshold, passed)
WITH dups AS (
  SELECT transaction_id
  FROM investsphere.silver.silver_transaction
  GROUP BY transaction_id
  HAVING count(*) > 1
)
SELECT current_timestamp(), 'silver_duplicate_transaction_ids',
       'silver.silver_transaction', date(:business_date), NULL, :job_run_id,
       (SELECT count(*) FROM dups), 0, (SELECT count(*) FROM dups) = 0;

-- 3. MISSING PRICES: holdings on the run date that have NO matching listed price for the
--    same asset/date (referential integrity, left-anti). metric = unmatched holdings (expect 0).
INSERT INTO investsphere.governance.reconciliation_results
  (check_timestamp, check_name, source_table, business_date, pipeline_run_id, job_run_id,
   metric_value, threshold, passed)
WITH missing AS (
  SELECT h.portfolio_id, h.investment_asset_id
  FROM investsphere.bronze.raw_investment_holdings_snapshot h
  WHERE h.as_of_date = date(:business_date)
  EXCEPT
  SELECT h.portfolio_id, h.investment_asset_id
  FROM investsphere.bronze.raw_investment_holdings_snapshot h
  JOIN investsphere.bronze.raw_listed_market_prices m
    ON h.investment_asset_id = m.investment_asset_id
   AND h.as_of_date = m.price_date
  WHERE h.as_of_date = date(:business_date)
)
SELECT current_timestamp(), 'holdings_missing_price',
       'bronze.raw_investment_holdings_snapshot', date(:business_date), NULL, :job_run_id,
       (SELECT count(*) FROM missing), 0, (SELECT count(*) FROM missing) = 0;

-- 4. MISSING ASSET MAPPINGS: holdings whose investment_asset_id is absent from the asset
--    master (left-anti against reference data). metric = unmapped holdings (expect 0).
INSERT INTO investsphere.governance.reconciliation_results
  (check_timestamp, check_name, source_table, business_date, pipeline_run_id, job_run_id,
   metric_value, threshold, passed)
SELECT current_timestamp(), 'holdings_missing_asset_master',
       'bronze.raw_investment_holdings_snapshot', date(:business_date), NULL, :job_run_id,
       count(*), 0, count(*) = 0
FROM investsphere.bronze.raw_investment_holdings_snapshot h
LEFT JOIN investsphere.bronze.raw_investment_asset_master a
       ON h.investment_asset_id = a.investment_asset_id
WHERE h.as_of_date = date(:business_date)
  AND a.investment_asset_id IS NULL;

-- 5. EXPOSURE TOTALS ~ 100%: for each portfolio/as_of_date on the run date, sum(exposure_pct)
--    must land inside 100 +/- 0.1 (allows rounding). metric = number of portfolios OUTSIDE
--    tolerance (expect 0).
INSERT INTO investsphere.governance.reconciliation_results
  (check_timestamp, check_name, source_table, business_date, pipeline_run_id, job_run_id,
   metric_value, threshold, passed)
WITH totals AS (
  SELECT portfolio_id, as_of_date, sum(exposure_pct) AS total_pct
  FROM investsphere.gold.fact_portfolio_exposure
  WHERE as_of_date = date(:business_date)
  GROUP BY portfolio_id, as_of_date
),
out_of_tol AS (
  SELECT * FROM totals WHERE abs(total_pct - 100.0) > 0.1
)
SELECT current_timestamp(), 'exposure_totals_not_100pct',
       'gold.fact_portfolio_exposure', date(:business_date), NULL, :job_run_id,
       (SELECT count(*) FROM out_of_tol), 0, (SELECT count(*) FROM out_of_tol) = 0;

-- 6. BREACH TABLE CONSISTENCY: every fact_limit_breach row must genuinely exceed its limit,
--    i.e. exposure_pct > max_pct. metric = count of INCONSISTENT breach rows (expect 0).
INSERT INTO investsphere.governance.reconciliation_results
  (check_timestamp, check_name, source_table, business_date, pipeline_run_id, job_run_id,
   metric_value, threshold, passed)
SELECT current_timestamp(), 'breach_rows_inconsistent_with_limit',
       'gold.fact_limit_breach', date(:business_date), NULL, :job_run_id,
       count(*), 0, count(*) = 0
FROM investsphere.gold.fact_limit_breach
WHERE as_of_date = date(:business_date)
  AND NOT (exposure_pct > max_pct);

-- 7. FEED DATE FRESHNESS: the newest price_date and the newest holdings as_of_date must
--    both equal the business date (no stale or future feed). metric = count of feeds whose
--    latest date != :business_date  (0, 1, or 2; expect 0).
INSERT INTO investsphere.governance.reconciliation_results
  (check_timestamp, check_name, source_table, business_date, pipeline_run_id, job_run_id,
   metric_value, threshold, passed)
WITH feed_max AS (
  SELECT 'prices' AS feed,
         (SELECT max(price_date) FROM investsphere.bronze.raw_listed_market_prices) AS latest_date
  UNION ALL
  SELECT 'holdings' AS feed,
         (SELECT max(as_of_date) FROM investsphere.bronze.raw_investment_holdings_snapshot) AS latest_date
),
stale AS (
  SELECT * FROM feed_max WHERE latest_date IS DISTINCT FROM date(:business_date)
)
SELECT current_timestamp(), 'feed_date_freshness',
       'bronze.raw_listed_market_prices,bronze.raw_investment_holdings_snapshot',
       date(:business_date), NULL, :job_run_id,
       (SELECT count(*) FROM stale), 0, (SELECT count(*) FROM stale) = 0;

-- See the latest reconciliation results:
-- SELECT * FROM investsphere.governance.reconciliation_results ORDER BY check_timestamp DESC;
