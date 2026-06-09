"""
RAG governance-boundary tests for the deployed InvestSphere platform.

=====================================================================
WHY THESE TESTS EXIST  (read this before changing anything)
=====================================================================
The chat/agent feature answers questions by retrieving chunks from
``investsphere.ai.policy_chunks`` (vector-searched via ``ai.policy_index``).

Here is the crucial governance fact that drives these tests:

    Databricks AI / Vector Search CANNOT enforce row-level security or
    column masks at retrieval time. In fact, a Delta table that has row
    filters or column masks applied to it CANNOT be used as a Vector
    Search index source at all.

Consequences:
  * You cannot "index everything and rely on UC row filters to hide the
    confidential investment-committee memo at query time." There is no
    such filter on the retrieval path.
  * Therefore the ONLY place the boundary can be enforced is BEFORE
    indexing: you must pre-filter the corpus so that only APPROVED
    documents are ever embedded into ai.policy_chunks. Restricted
    documents must never be chunked/indexed in the first place.

These tests verify that this pre-filtering control actually held in the
live deployment:
  1. Every indexed document is on the approved list.
  2. The restricted committee memo is absent (the hard security boundary).
  3. The index is non-empty (so retrieval has something to return).

If test #2 ever fails, treat it as a confidentiality incident, not a
flaky test: a restricted document became retrievable by the assistant.

CONNECTION / SKIP BEHAVIOUR
---------------------------
Same pattern as test_databricks_smoke.py: a module-scoped fixture opens a
``databricks.sql`` connection from DATABRICKS_SERVER_HOSTNAME /
DATABRICKS_HTTP_PATH / DATABRICKS_TOKEN, and the whole module is skipped
if any of those env vars is missing (so unit CI runs stay green).
"""

import os

import pytest

CATALOG = "investsphere"

# Documents that are explicitly cleared for retrieval.
APPROVED_RAG_DOCS = {
    "investment_policy_statement.pdf",
    "portfolio_risk_guidelines.pdf",
    "listed_equity_research_note.pdf",
}

# The confidential document that must NEVER be indexed.
RESTRICTED_DOC = "private_investment_committee_memo.pdf"


def _missing_env_vars():
    """Return the list of required connection env vars that are not set."""
    names = [
        "DATABRICKS_SERVER_HOSTNAME",
        "DATABRICKS_HTTP_PATH",
        "DATABRICKS_TOKEN",
    ]
    return [n for n in names if not os.environ.get(n)]


@pytest.fixture(scope="module")
def connection():
    """Open one shared Databricks SQL connection; skip the module if unconfigured."""
    missing = _missing_env_vars()
    if missing:
        pytest.skip(
            "Skipping live RAG boundary tests; missing env vars: "
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
    """Small helper: run SQL and return all rows as a list."""

    def _run(sql):
        cursor = connection.cursor()
        try:
            cursor.execute(sql)
            return cursor.fetchall()
        finally:
            cursor.close()

    return _run


@pytest.fixture(scope="module")
def require_rag_index(run_query):
    """Skip RAG tests if the index hasn't been built yet.

    ``ai.policy_chunks`` is created by ai/01_build_ai_search_index.py, which needs the
    (paid) Databricks AI / Vector Search. When that optional layer isn't deployed the
    table is absent -- a test for a not-yet-built component should SKIP, not FAIL.
    """
    try:
        rows = run_query(f"SHOW TABLES IN {CATALOG}.ai LIKE 'policy_chunks'")
    except Exception:
        rows = []
    if not rows:
        pytest.skip(
            "ai.policy_chunks not found -- RAG index not built yet "
            "(run ai/01_build_ai_search_index.py; needs AI Search / Vector Search)."
        )


def _distinct_indexed_docs(run_query):
    """Fetch the set of distinct doc_name values currently in the RAG index."""
    rows = run_query(
        f"SELECT DISTINCT doc_name FROM {CATALOG}.ai.policy_chunks"
    )
    return {r[0] for r in rows}


def test_every_indexed_doc_is_approved(run_query, require_rag_index):
    """Every distinct doc_name in ai.policy_chunks must be on the approved list."""
    indexed = _distinct_indexed_docs(run_query)
    not_approved = indexed - APPROVED_RAG_DOCS
    assert not not_approved, (
        "ai.policy_chunks contains document(s) that are NOT approved for "
        f"retrieval: {sorted(not_approved)}. "
        f"Approved set: {sorted(APPROVED_RAG_DOCS)}."
    )


def test_restricted_committee_memo_not_indexed(run_query, require_rag_index):
    """
    HARD SECURITY BOUNDARY.

    The confidential investment-committee memo must not appear anywhere in the
    RAG index. Because Vector Search cannot mask/filter at retrieval time, its
    mere presence here would make it answerable by the assistant.
    """
    rows = run_query(
        f"""
        SELECT COUNT(*) AS n
        FROM {CATALOG}.ai.policy_chunks
        WHERE doc_name = '{RESTRICTED_DOC}'
        """
    )
    leaked_chunks = rows[0][0]
    assert leaked_chunks == 0, (
        f"SECURITY BOUNDARY VIOLATION: restricted document '{RESTRICTED_DOC}' "
        f"has {leaked_chunks} chunk(s) in ai.policy_chunks and is therefore "
        "retrievable by the RAG assistant. It must be excluded BEFORE indexing."
    )


def test_policy_chunks_is_non_empty(run_query, require_rag_index):
    """The index must actually contain content, otherwise retrieval is useless."""
    rows = run_query(
        f"SELECT COUNT(*) AS n FROM {CATALOG}.ai.policy_chunks"
    )
    total = rows[0][0]
    assert total > 0, (
        "ai.policy_chunks is empty; the RAG index has no content to retrieve. "
        "Check that approved documents were chunked and indexed."
    )
