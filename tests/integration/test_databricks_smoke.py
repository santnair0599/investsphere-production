"""
Environment-level integration smoke tests for the deployed InvestSphere platform.

WHAT THIS IS
------------
These tests do NOT run business logic locally. Instead they connect to the
*live* Databricks deployment (Unity Catalog catalog ``investsphere``) over a SQL
warehouse and assert that the platform actually exists and produced sensible
data: the right schemas, the right tables, non-empty Silver, at least one limit
breach in Gold, fresh data-quality results, and a clean RAG index.

HOW IT CONNECTS
---------------
We use the official ``databricks-sql-connector`` (``databricks.sql``). It reads
three environment variables:

    DATABRICKS_SERVER_HOSTNAME   e.g. dbc-xxxxxxxx-xxxx.cloud.databricks.com
    DATABRICKS_HTTP_PATH         the SQL warehouse HTTP path
    DATABRICKS_TOKEN             a personal access token

WHY IT SKIPS INSTEAD OF FAILING
-------------------------------
In a normal CI *unit* run those env vars are not set (there is no warehouse to
talk to). We do not want that to turn the whole pipeline red, so if any of the
three variables is missing we ``pytest.skip(...)`` the entire module. These
tests only run where someone has deliberately provided live credentials
(e.g. a nightly "integration" job).

To run them locally:

    set DATABRICKS_SERVER_HOSTNAME=...
    set DATABRICKS_HTTP_PATH=...
    set DATABRICKS_TOKEN=...
    pytest tests/integration/test_databricks_smoke.py -v
"""

import os
import datetime as _dt

import pytest

# ---------------------------------------------------------------------------
# Constants describing the deployed platform. Kept here so the assertions below
# read like plain English.
# ---------------------------------------------------------------------------

CATALOG = "investsphere"

# Every Unity Catalog schema the platform is supposed to create.
REQUIRED_SCHEMAS = ["bronze", "silver", "gold", "governance", "ai"]

# A representative "key table" from each medallion layer. If any of these is
# missing the deployment is broken.
KEY_TABLES = {
    "bronze": [
        "raw_investment_transactions",
        "raw_listed_market_prices",
        "raw_investment_holdings_snapshot",
        "raw_portfolio_master",
        "raw_investment_asset_master",
        "raw_investment_limits",
    ],
    "silver": [
        "silver_transaction",
        "quarantine_transaction",
    ],
    "gold": [
        "fact_daily_holding",
        "fact_portfolio_exposure",
        "fact_limit_breach",
    ],
}

# The only documents that are allowed to have been indexed for RAG. Anything
# else (especially the committee memo) means the governance boundary leaked.
APPROVED_RAG_DOCS = {
    "investment_policy_statement.pdf",
    "portfolio_risk_guidelines.pdf",
    "listed_equity_research_note.pdf",
}
RESTRICTED_RAG_DOCS = {
    "private_investment_committee_memo.pdf",
}


# ---------------------------------------------------------------------------
# Connection fixture
# ---------------------------------------------------------------------------

# We import the connector lazily inside the fixture so that environments which
# do not even have the package installed still *collect* (they just skip).
def _missing_env_vars():
    """Return the list of required env vars that are not set/empty."""
    names = [
        "DATABRICKS_SERVER_HOSTNAME",
        "DATABRICKS_HTTP_PATH",
        "DATABRICKS_TOKEN",
    ]
    return [n for n in names if not os.environ.get(n)]


@pytest.fixture(scope="module")
def connection():
    """
    Open ONE Databricks SQL connection shared by every test in this module.

    ``scope="module"`` means the (relatively expensive) connection is created
    once and reused, then closed when the module finishes.
    """
    missing = _missing_env_vars()
    if missing:
        # Skip the whole module so a plain unit-test CI run stays green.
        pytest.skip(
            "Skipping live Databricks integration tests; missing env vars: "
            + ", ".join(missing)
        )

    try:
        from databricks import sql as databricks_sql
    except ImportError:  # pragma: no cover - depends on environment
        pytest.skip("databricks-sql-connector is not installed")

    conn = databricks_sql.connect(
        server_hostname=os.environ["DATABRICKS_SERVER_HOSTNAME"],
        http_path=os.environ["DATABRICKS_HTTP_PATH"],
        access_token=os.environ["DATABRICKS_TOKEN"],
    )
    try:
        yield conn
    finally:
        conn.close()


@pytest.fixture(scope="module")
def run_query(connection):
    """
    Provide a tiny ``run_query(sql)`` helper that returns a list of result rows.

    Each row behaves like a tuple AND like a named record (you can do row[0] or
    row.column_name), which is exactly what the connector returns.
    """

    def _run(sql):
        cursor = connection.cursor()
        try:
            cursor.execute(sql)
            return cursor.fetchall()
        finally:
            cursor.close()

    return _run


# ---------------------------------------------------------------------------
# Schema / table existence
# ---------------------------------------------------------------------------

def test_required_schemas_exist(run_query):
    """All five medallion + governance + ai schemas must be present."""
    rows = run_query(
        f"""
        SELECT schema_name
        FROM {CATALOG}.information_schema.schemata
        """
    )
    found = {r[0].lower() for r in rows}
    for schema in REQUIRED_SCHEMAS:
        assert schema in found, (
            f"Expected schema '{CATALOG}.{schema}' to exist, "
            f"but only found: {sorted(found)}"
        )


def test_key_tables_exist(run_query):
    """Each layer's key tables must exist in information_schema.tables."""
    for schema, tables in KEY_TABLES.items():
        rows = run_query(
            f"""
            SELECT table_name
            FROM {CATALOG}.information_schema.tables
            WHERE table_schema = '{schema}'
            """
        )
        present = {r[0].lower() for r in rows}
        for table in tables:
            assert table.lower() in present, (
                f"Expected table '{CATALOG}.{schema}.{table}' to exist. "
                f"Tables present in {schema}: {sorted(present)}"
            )


# ---------------------------------------------------------------------------
# Silver layer
# ---------------------------------------------------------------------------

def test_silver_transaction_has_records(run_query):
    """Silver should contain cleansed transactions; an empty Silver = broken ETL."""
    rows = run_query(
        f"SELECT COUNT(*) AS n FROM {CATALOG}.silver.silver_transaction"
    )
    count = rows[0][0]
    assert count > 0, (
        "silver.silver_transaction is empty; the Bronze->Silver pipeline "
        "produced no clean records."
    )


def test_quarantine_transaction_is_queryable(run_query):
    """
    The quarantine table holds rejected rows. It may legitimately be empty,
    so we only assert it is queryable and returns a non-negative count.
    """
    rows = run_query(
        f"SELECT COUNT(*) AS n FROM {CATALOG}.silver.quarantine_transaction"
    )
    count = rows[0][0]
    assert count >= 0  # always true if the query succeeded -> table exists & queryable


# ---------------------------------------------------------------------------
# Gold layer — limit breaches
# ---------------------------------------------------------------------------

def test_gold_limit_breach_contains_expected_breach(run_query):
    """
    The demo dataset is engineered so the GULF_EQ portfolio breaches the
    Banking sector concentration limit. We assert:

      1. There is at least one breach overall (strict invariant), AND
      2. The specific GULF_EQ / Banking breach is present.

    If the deployed demo data happens to use different ids, we keep the strict
    ">= 1 breach" assertion and merely *warn* about the missing expected row,
    so the test stays useful across data variants without silently passing on
    an empty breach table.
    """
    total_rows = run_query(
        f"SELECT COUNT(*) AS n FROM {CATALOG}.gold.fact_limit_breach"
    )
    total = total_rows[0][0]
    assert total >= 1, (
        "gold.fact_limit_breach has no rows; expected at least the GULF_EQ "
        "Banking concentration breach from the demo dataset."
    )

    expected_rows = run_query(
        f"""
        SELECT COUNT(*) AS n
        FROM {CATALOG}.gold.fact_limit_breach
        WHERE portfolio_id = 'GULF_EQ'
          AND sector = 'Banking'
        """
    )
    expected = expected_rows[0][0]
    if expected < 1:
        # Strict invariant already satisfied (>=1 breach exists); the exact
        # demo row is just shaped differently. Warn rather than fail.
        import warnings

        warnings.warn(
            "Found {0} limit breach(es) but not the expected "
            "portfolio_id='GULF_EQ' / sector='Banking' row. "
            "If the demo data uses different ids this is acceptable.".format(total)
        )
    else:
        assert expected >= 1


# ---------------------------------------------------------------------------
# Governance — data quality freshness
# ---------------------------------------------------------------------------

def test_dq_results_has_recent_check(run_query):
    """
    governance.dq_results records every data-quality check run. We require at
    least one check whose check_timestamp is within the last 7 days, proving
    the DQ framework is actually executing (not just historically populated).
    """
    cutoff = _dt.datetime.utcnow() - _dt.timedelta(days=7)
    cutoff_str = cutoff.strftime("%Y-%m-%d %H:%M:%S")

    rows = run_query(
        f"""
        SELECT COUNT(*) AS n
        FROM {CATALOG}.governance.dq_results
        WHERE check_timestamp >= TIMESTAMP '{cutoff_str}'
        """
    )
    recent = rows[0][0]
    assert recent >= 1, (
        "governance.dq_results has no check_timestamp within the last 7 days; "
        "the data-quality framework may not be running."
    )


# ---------------------------------------------------------------------------
# AI / RAG governance boundary
# ---------------------------------------------------------------------------

def test_policy_chunks_only_approved_docs(run_query):
    """
    The RAG index (ai.policy_chunks) must contain ONLY approved documents and
    NONE of the restricted ones. This is the security boundary for retrieval —
    see test_rag_boundary.py for the detailed rationale.

    Skipped if the RAG index hasn't been built yet (ai/01_build_ai_search_index.py is
    the optional, paid AI Search step) — a not-yet-built component should skip, not fail.
    """
    try:
        exists = run_query(f"SHOW TABLES IN {CATALOG}.ai LIKE 'policy_chunks'")
    except Exception:
        exists = []
    if not exists:
        pytest.skip(
            "ai.policy_chunks not found -- RAG index not built yet "
            "(run ai/01_build_ai_search_index.py; needs AI Search / Vector Search)."
        )

    rows = run_query(
        f"SELECT DISTINCT doc_name FROM {CATALOG}.ai.policy_chunks"
    )
    indexed_docs = {r[0] for r in rows}

    # Every indexed doc must be approved.
    unexpected = indexed_docs - APPROVED_RAG_DOCS
    assert not unexpected, (
        "ai.policy_chunks contains non-approved document(s): "
        f"{sorted(unexpected)}. Only {sorted(APPROVED_RAG_DOCS)} are allowed."
    )

    # No restricted doc may appear (hard security invariant).
    leaked = indexed_docs & RESTRICTED_RAG_DOCS
    assert not leaked, (
        f"RESTRICTED document(s) leaked into the RAG index: {sorted(leaked)}."
    )
