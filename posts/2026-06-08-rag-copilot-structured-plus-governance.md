# One compliance question, three systems, one grounded answer

*Draft LinkedIn post — InvestSphere build log, 2026-06-08*

---

Here's a question a compliance officer might ask:

> *"Does the GULF_EQ portfolio breach the banking concentration limit, by how much, and which policy clause explains it?"*

It sounds like one question. It's actually **three**, and each needs a different system:

1. **The number** — *is there a breach, and by how much?* → structured analytics on governed Gold tables.
2. **The clause** — *which policy says so?* → unstructured text buried in PDF policy documents.
3. **The guardrail** — *is this user even allowed to see this portfolio?* → access governance.

Most "AI copilot" demos answer #1 *or* #2. The interesting engineering is fusing all three **without leaking anything**. That's what I built into InvestSphere this week on Databricks.

**How it fits together:**

- **Structured breach data** comes from a **governed Unity Catalog function** (`get_portfolio_breaches`), not a raw table. Because it's a UC function over secured Gold tables, it **inherits row/column security** — the assistant physically cannot return a portfolio the caller isn't entitled to.
- **Policy passages** come from **Databricks AI Search (Vector Search)** — a RAG retrieval over the policy PDFs (investment policy statement, risk guidelines).
- A **Databricks foundation model** (Llama 3.3 70B) writes the final answer, grounded **only** in the breach data + retrieved passages, and is told to **name the policy document** it relied on.

**The design decision I'm proudest of is a boundary, not a feature.**

Databricks AI Search does **not** enforce row/column-level security, and you **cannot index a table that has a row filter or column mask**. So the naive "just embed everything and let the LLM retrieve it" approach would quietly turn your vector index into a hole in your governance.

So the rule in InvestSphere is explicit:
- **Sensitive / portfolio-restricted structured data → only through the governed UC function** (which enforces UC security).
- **The vector index → only approved, non-restricted documents** (general policy + research). The confidential investment-committee memo is excluded by an allow-list.

The LLM never sees anything the user couldn't see. Governance lives in the *plumbing*, not in a prompt that says "please be careful."

**And a small, very relatable bug along the way:** my first run crashed with `too many values to unpack (expected 2)`. Turns out AI Search appends a **similarity score** to every result row — so each row is `[doc_name, chunk_text, score]`, not the two columns I asked for. One-line fix, good reminder: read what the API actually returns, not what you assume it returns.

**Takeaways for anyone building governed GenAI on a lakehouse:**
- Real questions fuse **structured + unstructured + governance** — design for all three, not just retrieval.
- Expose structured data to agents through **governed functions** (UC / a managed MCP server), so security is enforced by the platform, not the prompt.
- Your **vector index is an access-control surface** — only index what everyone is allowed to see.
- Ground the model in retrieved facts **and** make it cite its source, so answers are checkable.

The flashy part is the chatbot. The part that makes it shippable is that it can't say something it shouldn't.

#DataEngineering #Databricks #RAG #UnityCatalog #DataGovernance #GenAI #VectorSearch #Lakehouse

---

*Part of my InvestSphere build — a governed investment-data platform + AI copilot on Databricks. More build-log posts in this folder.*
