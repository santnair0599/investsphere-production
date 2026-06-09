# Databricks script -- build the RAG knowledge base with Databricks AI Search
# (formerly Databricks Vector Search). Run on Databricks with serverless enabled.
#
# Steps:
#   1. Read the policy/research documents into a Delta table, split into chunks.
#   2. Create an AI Search endpoint.
#   3. Create a Delta-sync index that embeds the chunks with a Databricks-hosted
#      embedding model, so the assistant can retrieve relevant passages.
#
# NOTE: AI Search needs a Unity Catalog-enabled workspace and serverless compute.
# The Python SDK is still imported as `databricks.vector_search` even though the
# product is now called AI Search. Check which embedding model endpoints exist in
# your workspace (this uses databricks-gte-large-en).

import os

from pyspark.sql import SparkSession
from databricks.vector_search.client import VectorSearchClient

spark = SparkSession.builder.getOrCreate()

SOURCE_TABLE = "investsphere.ai.policy_chunks"
INDEX_NAME = "investsphere.ai.policy_index"
ENDPOINT = "investsphere_ai_search"
DOCS_VOLUME = "/Volumes/investsphere/ai/documents"   # upload data/documents/*.pdf here

# Only index APPROVED, non-restricted documents. AI Search cannot enforce row/column
# security, so confidential / portfolio-restricted material (e.g. the private
# investment committee memo) is intentionally EXCLUDED from the index.
# Approve by the LOGICAL document name -- uploads are date-stamped & immutable
# (e.g. investment_policy_statement_2026_06_05.pdf) so file-arrival triggers fire on
# each new version. Keep this consistent with ai/03_refresh_documents.py.
APPROVED_DOCS = {
    "investment_policy_statement",
    "portfolio_risk_guidelines",
    "listed_equity_research_note",
}


def _logical_name(file_name):
    """'investment_policy_statement_2026_06_05.pdf' -> 'investment_policy_statement',
    or None if the file is not an approved document."""
    if not file_name.lower().endswith(".pdf"):
        return None
    stem = file_name[:-4]  # drop '.pdf'
    for doc in APPROVED_DOCS:
        if stem == doc or stem.startswith(doc + "_"):
            return doc
    return None


def load_chunks():
    """Read the APPROVED PDFs and split each into chunks (one per non-empty line).
    chunk_id/doc_name are keyed on the stable LOGICAL name so the incremental MERGE in
    ai/03_refresh_documents.py updates these same rows instead of appending duplicates."""
    from pypdf import PdfReader   # pip install pypdf  (use a richer chunker in production)

    # If several dated versions of a doc linger in the volume, keep only the latest.
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
        lines = [line.strip() for line in text.split("\n") if line.strip()]
        for i, line in enumerate(lines):
            rows.append((doc + "#" + str(i), doc, line))
    return rows


# 1. write chunks to a Delta table (change data feed is needed for delta-sync).
# Explicit schema so the write doesn't fail on an empty/first run (Spark Connect cannot
# infer a schema from an empty list).
from pyspark.sql.types import StructType, StructField, StringType
CHUNK_SCHEMA = StructType([
    StructField("chunk_id", StringType(), False),
    StructField("doc_name", StringType(), False),
    StructField("chunk_text", StringType(), True),
])
df = spark.createDataFrame(load_chunks(), CHUNK_SCHEMA)
(df.write.format("delta").mode("overwrite")
   .option("delta.enableChangeDataFeed", "true")
   .saveAsTable(SOURCE_TABLE))

# 2. create the AI Search endpoint (safe to re-run)
vsc = VectorSearchClient()
try:
    vsc.create_endpoint(name=ENDPOINT, endpoint_type="STANDARD")
except Exception as error:
    print("endpoint may already exist:", error)

# 3. create the delta-sync index with managed embeddings
vsc.create_delta_sync_index(
    endpoint_name=ENDPOINT,
    index_name=INDEX_NAME,
    source_table_name=SOURCE_TABLE,
    primary_key="chunk_id",
    embedding_source_column="chunk_text",
    embedding_model_endpoint_name="databricks-gte-large-en",
    pipeline_type="TRIGGERED",
)
print("AI Search index created:", INDEX_NAME)
