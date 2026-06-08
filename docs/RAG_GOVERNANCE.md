# InvestSphere RAG Governance

Governance controls for the AI copilot's retrieval-augmented generation (RAG)
layer: which documents are allowed into the index, why the boundary lives where
it does, how documents are approved/versioned/refreshed/de-indexed, and how we
keep answers grounded and cited.

Companion to [`GOVERNANCE_MODEL.md`](GOVERNANCE_MODEL.md), which covers the data
access model. This file is specifically about **document/RAG** governance.

---

## 1. The control: an approved-document allowlist

The assistant retrieves chunks from `investsphere.ai.policy_chunks` (vector
search via `investsphere.ai.policy_index`). **Only approved documents are
indexed.** Restricted/private documents are **never** chunked or indexed.

| Document                               | Status      | In the index? |
|----------------------------------------|-------------|---------------|
| `investment_policy_statement.pdf`      | APPROVED    | YES           |
| `portfolio_risk_guidelines.pdf`        | APPROVED    | YES           |
| `listed_equity_research_note.pdf`      | APPROVED    | YES           |
| `private_investment_committee_memo.pdf`| RESTRICTED  | **NO — excluded** |

The allowlist is the literal `APPROVED_DOCS` set in `ai/03_refresh_documents.py`
(and mirrored as `APPROVED_RAG_DOCS` in the boundary test). Any file not in that
set is skipped at chunk time, so its text never reaches the index.

---

## 2. Why the boundary is at indexing time (not at query time)

> **Databricks AI Search / Vector Search CANNOT enforce row-level security or
> column masks at retrieval time. A Delta table that has a row filter or column
> mask attached CANNOT even be used as a Vector Search index source.**

Consequences:

- You **cannot** "index everything and rely on UC to hide the committee memo at
  query time." There is no security filter on the retrieval path — once a chunk
  is in `policy_chunks`/`policy_index`, anyone who can query the assistant can
  retrieve it.
- Therefore the **only** place to enforce confidentiality is **before indexing**:
  pre-filter the corpus so restricted documents are never embedded.

**AI Search requirements** (why the source table is shaped the way it is):

- **Unity Catalog**-managed source table.
- **Serverless** compute for the endpoint/sync.
- **Change Data Feed (CDF)** enabled on the source Delta table
  (`delta.enableChangeDataFeed = true`) so Delta-sync can pick up changes.

Because the source table must be CDF-synced and cannot carry a row filter/mask,
its protection is the allowlist — not UC policies.

---

## 3. Document approval register

Every candidate document is recorded here before it can be indexed. This register
is the human-readable authority; the allowlist in code must match the rows marked
`approved_for_index = Y`.

| doc_name                                | owner            | sensitivity | approved_for_index | version | approved_by      | approved_date |
|-----------------------------------------|------------------|-------------|--------------------|---------|------------------|---------------|
| investment_policy_statement.pdf         | Investment Office| Internal    | Y                  | v3      | Head of Governance | 2026-05-12  |
| portfolio_risk_guidelines.pdf           | Risk             | Internal    | Y                  | v2      | Head of Risk     | 2026-05-12    |
| listed_equity_research_note.pdf         | Research         | Internal    | Y                  | v1      | Head of Research | 2026-05-20    |
| private_investment_committee_memo.pdf   | Investment Cmte  | **Restricted** | **N**           | v1      | (n/a)            | (n/a)         |

Column meanings:

- **doc_name** — exact filename in `/Volumes/investsphere/ai/documents`.
- **owner** — accountable team for the content.
- **sensitivity** — Internal / Restricted (Restricted ⇒ never indexed).
- **approved_for_index** — Y/N gate. Only `Y` rows appear in the code allowlist.
- **version** — content version; bumped whenever the PDF changes (see Section 4).
- **approved_by** — approver who signed off indexing.
- **approved_date** — when sign-off happened.

Rule: a document may be indexed **only if** there is a register row with
`approved_for_index = Y`, **and** its filename is in the code allowlist. Two gates
must agree.

---

## 4. Document versioning + index refresh

Driver script: **`ai/03_refresh_documents.py`** (incremental, not a full rebuild).

When an approved document is added or changed:

1. **Upload** the PDF to `/Volumes/investsphere/ai/documents`.
2. The script parses + chunks **only allowlisted** files (anything not in
   `APPROVED_DOCS` is skipped).
3. Chunks are **MERGE**d into `investsphere.ai.policy_chunks` keyed on
   `chunk_id` (= `doc_name#<line>`): new chunks inserted, changed chunks updated.
4. The script triggers an **AI Search index sync** (`index.sync()` — Triggered
   sync, cheaper than Continuous for this project) so `policy_index` picks up the
   change.

**Versioning convention:** bump the document's `version` in the register
(Section 3) whenever its content changes. Because MERGE is keyed on
`doc_name#line`, re-uploading an edited PDF updates the affected chunks in place.

---

## 5. De-indexing when approval is revoked

**Important gap to know:** the MERGE in `03_refresh_documents.py` does
**insert/update only**. It does **NOT** delete chunks for documents removed from
the allowlist. Dropping a file from `APPROVED_DOCS` stops *future* re-indexing but
leaves its **existing** chunks in `policy_chunks` — still retrievable. De-indexing
is therefore a deliberate, manual step.

To revoke a document:

1. **Allowlist:** remove the filename from `APPROVED_DOCS` in
   `ai/03_refresh_documents.py` (and from the register: set
   `approved_for_index = N`).
2. **Delete its chunks** from the source table:
   ```sql
   DELETE FROM investsphere.ai.policy_chunks
   WHERE doc_name = '<revoked_doc>.pdf';
   ```
3. **Re-sync** the index so the deletions propagate:
   ```python
   VectorSearchClient().get_index(
       endpoint_name="investsphere_ai_search",
       index_name="investsphere.ai.policy_index",
   ).sync()
   ```
4. **Verify** with the boundary test (Section 9) that the doc is gone.

Skipping step 2 is the classic mistake — the document keeps answering questions
even though it was "removed."

---

## 6. Retrieval evaluation — golden question set

A small golden set to sanity-check that retrieval returns the **right** chunks and
that answers stay **grounded**. Run after every refresh / prompt change.

| # | Question                                                              | Should retrieve from                   | Expected behavior                                |
|---|-----------------------------------------------------------------------|----------------------------------------|--------------------------------------------------|
| 1 | "What is our maximum single-issuer concentration limit?"              | portfolio_risk_guidelines.pdf          | Cites the risk guidelines; states the limit.     |
| 2 | "What asset classes are permitted under the investment policy?"       | investment_policy_statement.pdf        | Cites the IPS; lists permitted classes.          |
| 3 | "Summarize the research view on the listed equity covered."           | listed_equity_research_note.pdf        | Cites the research note.                          |
| 4 | "What did the private investment committee decide in the memo?"       | (restricted — not indexed)             | **Must NOT answer**; says info not supported / unavailable. |
| 5 | "What is InvestSphere's rebalancing frequency?" (not in any doc)      | (nothing relevant)                     | Says "not supported by the policy documents."    |

Question 4 is the security probe: the assistant must have **no** retrievable
content for the restricted memo. Question 5 is the hallucination probe.

---

## 7. Source-citation + hallucination guardrail

The assistant must:

- **Cite its source.** Every substantive answer names the policy document it used
  (e.g. "per `portfolio_risk_guidelines.pdf`"). Retrieval returns `doc_name` with
  each chunk specifically so the answer can attribute it.
- **Answer only from retrieved context.** If the retrieved chunks do not contain
  the answer, the assistant says it is **"not supported by the available policy
  documents"** rather than guessing. No outside/parametric knowledge for policy
  questions.

This pairs with the allowlist: since restricted content is never retrievable, an
honest "answer only from context" assistant **cannot** surface it, even indirectly.

---

## 8. Index freshness check

After a refresh, confirm the index reflects the corpus:

- **Coverage:** every approved doc has chunks present —
  ```sql
  SELECT doc_name, COUNT(*) AS chunks
  FROM investsphere.ai.policy_chunks
  GROUP BY doc_name ORDER BY doc_name;
  ```
  Expect exactly the 3 approved docs, each with `chunks > 0`.
- **Sync state:** the `policy_index` last-sync timestamp is newer than the most
  recent document upload (check the AI Search index status / `describe`).
- **No leakage:** the restricted memo returns **zero** chunks (Section 9).

If coverage is missing or sync is stale, re-run `ai/03_refresh_documents.py`.

---

## 9. Test pointer — the allowlist guard

**`tests/integration/test_rag_boundary.py`** verifies the boundary held in the
live deployment (it connects via `DATABRICKS_SERVER_HOSTNAME` /
`DATABRICKS_HTTP_PATH` / `DATABRICKS_TOKEN`, and skips cleanly when those env
vars are absent, so unit CI stays green). It asserts:

1. **Every indexed `doc_name` is on the approved list** — nothing unexpected got
   indexed.
2. **The restricted committee memo has zero chunks** — the hard security
   boundary. If this fails, treat it as a **confidentiality incident**, not a
   flaky test.
3. **`policy_chunks` is non-empty** — retrieval actually has content.

Run it after every document refresh and de-index operation to prove the allowlist
is still enforced end-to-end.
