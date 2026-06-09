# Databricks script  ---  incremental document refresh for RAG (on document upload)
#
# Triggered when a new/changed policy or research PDF is uploaded. Instead of
# REBUILDING the whole index, this does incremental AI data engineering:
#   parse + chunk the PDFs  ->  MERGE changed chunks into the Delta source table
#   ->  trigger a Databricks AI Search index sync (Triggered sync, cheaper than
#       Continuous for a personal project).
#
# Requires the one-time setup in ai/01_build_ai_search_index.py to have created the
# Delta source table + the Triggered-sync index.

import datetime
import os

from pyspark.sql import SparkSession
from pyspark.sql.types import StructType, StructField, StringType
from delta.tables import DeltaTable
from databricks.vector_search.client import VectorSearchClient

spark = SparkSession.builder.getOrCreate()

DOCS_VOLUME = "/Volumes/investsphere/ai/documents"
SOURCE_TABLE = "investsphere.ai.policy_chunks"
INDEX_NAME = "investsphere.ai.policy_index"
ENDPOINT = "investsphere_ai_search"

# Only index APPROVED, non-restricted documents (AI Search has no row/column security).
# Uploads use IMMUTABLE, date-stamped filenames (e.g. investment_policy_statement_2026_06_05.pdf)
# so file-arrival triggers fire on each new version. We approve by the LOGICAL document name
# (the stem before the _YYYY_MM_DD suffix), not the exact filename.
APPROVED_DOCS = {
    "investment_policy_statement",
    "portfolio_risk_guidelines",
    "listed_equity_research_note",
}


def _logical_name(file_name):
    """Map a dated filename to its logical doc key, or None if not approved.
    'investment_policy_statement_2026_06_05.pdf' -> 'investment_policy_statement'."""
    if not file_name.lower().endswith(".pdf"):
        return None
    stem = file_name[:-4]  # drop '.pdf'
    for doc in APPROVED_DOCS:
        if stem == doc or stem.startswith(doc + "_"):
            return doc
    return None


def load_chunks():
    from pypdf import PdfReader   # pip install pypdf

    # If several dated versions of the same doc are still in the volume, keep only the
    # LATEST (filenames sort chronologically thanks to the _YYYY_MM_DD suffix) so the
    # MERGE updates each logical doc's chunks instead of mixing versions.
    latest = {}
    for file_name in os.listdir(DOCS_VOLUME):
        doc = _logical_name(file_name)
        if doc is None:
            continue
        if doc not in latest or file_name > latest[doc]:
            latest[doc] = file_name

    rows = []
    for doc, file_name in latest.items():
        reader = PdfReader(os.path.join(DOCS_VOLUME, file_name))
        text = "\n".join((page.extract_text() or "") for page in reader.pages)
        # chunk_id is keyed on the LOGICAL doc (stable across versions) so re-uploads
        # update existing chunks rather than appending a parallel set.
        for i, line in enumerate(ln.strip() for ln in text.split("\n") if ln.strip()):
            rows.append((doc + "#" + str(i), doc, line))
    return rows


# Explicit schema: an upload can land 0 approved chunks (no approved files yet, a
# non-approved file, or a PDF with no extractable text). Spark Connect cannot infer a
# schema from an empty list, so declare it -- and skip the MERGE/sync when there's nothing.
CHUNK_SCHEMA = StructType([
    StructField("chunk_id", StringType(), False),
    StructField("doc_name", StringType(), False),
    StructField("chunk_text", StringType(), True),
])

rows = load_chunks()
if not rows:
    print(f"no approved chunks found in {DOCS_VOLUME} -- nothing to merge; skipping index sync")
else:
    new_chunks = spark.createDataFrame(rows, CHUNK_SCHEMA)

    # MERGE: insert new chunks, update changed ones (incremental, not a full rebuild)
    (DeltaTable.forName(spark, SOURCE_TABLE).alias("t")
        .merge(new_chunks.alias("s"), "t.chunk_id = s.chunk_id")
        .whenMatchedUpdateAll()
        .whenNotMatchedInsertAll()
        .execute())

    # Trigger the AI Search Delta-sync index to pick up the changed chunks.
    # A freshly-created TRIGGERED index is still PROVISIONING (and runs an initial sync
    # of all rows on creation), so an explicit sync() now would raise
    # "BadRequest: ... is not ready". Wait for it to come ONLINE, then sync; if it's
    # still not ready, skip rather than fail the job -- the data is already MERGEd into
    # the source table and the index will pick it up on its next sync.
    index = VectorSearchClient().get_index(endpoint_name=ENDPOINT, index_name=INDEX_NAME)

    # Best-effort wait for provisioning to finish, if the SDK exposes a waiter.
    # (Method/signature varies across databricks-vectorsearch vs databricks-ai-search,
    # so guard it -- a missing or differently-shaped waiter must not fail the job.)
    waiter = getattr(index, "wait_until_ready", None)
    if waiter is not None:
        try:
            waiter(verbose=True, timeout=datetime.timedelta(minutes=20))
        except Exception as err:
            print(f"index readiness wait did not complete: {err}")

    try:
        index.sync()
        print(f"{len(rows)} chunks merged into Delta + AI Search index sync triggered")
    except Exception as err:
        print(f"{len(rows)} chunks merged into Delta; index sync skipped "
              f"(index not ready yet: {err}). It will sync once provisioning completes "
              f"or on the next upload.")
