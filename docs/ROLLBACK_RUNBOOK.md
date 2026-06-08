# InvestSphere — Rollback & Recovery Runbook

A **decision-first** runbook for getting InvestSphere back to a known-good state.
Each section follows the same shape:

> **Symptom** → **Action** (concrete commands) → **Verification** → **Comms**

This is written to be followed under pressure, by someone who did **not** necessarily
build the system. Commands are copy-pasteable; read the comments before you run them.

**Golden rule:** prefer the *smallest reversible action* that fixes the symptom. A
Delta `RESTORE` or a paused schedule is reversible; deleting tables or jobs is not.

---

## 0. First 5 minutes — triage

1. **Confirm the blast radius.** Is it a *deploy* problem, a *job-run* problem, a
   *data* problem, an *AI/RAG* problem, or a *governance/access* problem? Jump to
   the matching section below.
2. **Stop the bleeding.** If a scheduled job keeps making it worse, **pause its
   schedule first** (see §7) — you can resume it after the fix.
3. **Start comms** (see §9) in parallel — don't wait until you've fixed it.

Identifiers you'll reuse:
- Catalog: `investsphere` · schemas: `bronze` / `silver` / `gold` / `governance` / `ai` / `features` / `ml`
- Bundle target for production: `prod` (dev target: `dev`)
- On-call recipient (`oncall_email` bundle var): **santnair0599@gmail.com**

---

## 1. Failed Databricks Bundle deployment

**Symptom:** the CD workflow's `databricks bundle deploy -t prod` failed, or a deploy
succeeded but left prod broken (jobs won't start, wrong wheel, bad config).

### Action — roll back to the last known-good release

The clean way to roll back a deploy is to **re-deploy a previous Git tag**. The bundle
is fully declarative, so deploying an older commit restores the older jobs, pipeline,
and the older wheel version.

```bash
# 1. See what tagged releases exist (newest last).
git tag --list "v*" --sort=version:refname

# 2. Check out the last KNOWN-GOOD tag (read-only "detached HEAD" — safe).
git checkout v1.4.2          # <-- replace with the good tag

# 3. Authenticate as the prod service principal (OAuth M2M). In CI these are env
#    vars already; locally export them or use a configured CLI profile:
export DATABRICKS_HOST=https://dbc-d3c7f717-df2a.cloud.databricks.com
export DATABRICKS_CLIENT_ID=<prod-sp-client-id>
export DATABRICKS_CLIENT_SECRET=<prod-sp-secret>

# 4. Rebuild the wheel for THIS (older) commit so artifacts upload the matching
#    investsphere_platform-<version>.whl, then validate and deploy.
python -m pip wheel . --no-deps -w dist
databricks bundle validate -t prod
databricks bundle deploy   -t prod
```

> **Why a tag and not just `git revert`?** Tagging gives you an immutable, named
> point to roll *to*. `revert` works too but you still want to deploy from a commit
> you trust. Either way, the deploy is what changes the workspace.

### How to tag releases (do this on every prod release going forward)

```bash
# Tag the commit you are about to ship, then push the tag so CI/others can see it.
git checkout main
git pull
git tag -a v1.5.0 -m "InvestSphere release 1.5.0"
git push origin v1.5.0
```

Keep the **wheel version** (`investsphere_platform-0.1.0`) bumped in lock-step with
releases so "previous wheel" is unambiguous; the `artifacts` block rebuilds whatever
version the checked-out code declares.

### Verification
```bash
# Bundle now resolves to the older config without errors:
databricks bundle validate -t prod
# Jobs exist and are healthy in the workspace:
databricks bundle run investsphere_eod -t prod   # smoke run; should succeed
```

### Comms
Post in the incident channel: "Rolled prod back to `v1.4.2` via bundle redeploy.
Smoke EOD run green. Root cause of `v1.5.0` deploy under investigation."

---

## 2. Failed job run

**Symptom:** a run of `investsphere_eod` (or `investsphere_ingest`, `_private_nav`,
`_docs_rag`, `_maintenance_demo`) failed. On-call got the `on_failure` email.

### Action — inspect first, then decide fix-forward vs. roll back

```bash
# List recent runs for the job to get the failing run id.
databricks jobs list-runs --job-id <job_id> --limit 10

# Drill into the failed run: which task failed and why.
databricks jobs get-run <run_id>
# (Or open the run in the UI: Workflows -> the job -> the failed run -> task logs.)
```

**Decide:**
- **Transient** (timeout, flaky feed, infra blip)? The bundle already retries
  (`max_retries: 2`). Just **re-run**:
  ```bash
  databricks jobs repair-run <run_id> --rerun-all-failed-tasks
  # or trigger a fresh run with the same date:
  databricks bundle run investsphere_eod -t prod -- --run_date 2026-06-08
  ```
- **Code/config bug → FIX-FORWARD** (preferred): fix the code, ship via the normal
  CD flow (PR → `main` → approved prod deploy), then re-run the job. Fix-forward is
  usually safer than rolling the whole platform back for one bad task.
- **Bad recent deploy caused it → ROLL BACK** the deployment per **§1**, then re-run.

> Note the EOD DAG is conditional: `readiness_gate → feeds_ready → silver → gold →
> export_metrics + dq_checks`. If `feeds_ready` went false, that's *not* a failure —
> it intentionally skips Gold and runs `notify_not_ready`. Check upstream feeds, not the job.

### Verification
Re-run completes; `dq_checks` populates `governance.dq_results` for the business date
with no breaches.

### Comms
State whether you fixed-forward or rolled back, and the business date that was reprocessed.

---

## 3. Bad data loaded into Bronze / Silver / Gold

**Symptom:** a load wrote wrong/corrupt rows (e.g. a bad feed inflated
`investsphere.gold.fact_limit_breach`). Delta tables support **time travel** and
**RESTORE**, so this is recoverable without a backup as long as the data still
exists in history (within the table's retention window).

### Action — always look at history BEFORE you restore

```sql
-- 1. Inspect the version history. Note the version number / timestamp from BEFORE
--    the bad load (look at the operation, user, and timestamp columns).
DESCRIBE HISTORY investsphere.gold.fact_limit_breach;

-- 2. (Optional, recommended) peek at a past version to confirm it's the good one
--    before you commit to restoring it:
SELECT * FROM investsphere.gold.fact_limit_breach VERSION AS OF 41 LIMIT 20;

-- 3. RESTORE the table to the good version. This creates a NEW commit that makes
--    the table's current state identical to that version (itself reversible).
RESTORE TABLE investsphere.gold.fact_limit_breach TO VERSION AS OF 41;
-- You can also restore by time:
-- RESTORE TABLE investsphere.gold.fact_limit_breach TO TIMESTAMP AS OF '2026-06-07 17:00:00';
```

Apply the same pattern to the affected layer — `investsphere.silver.silver_transaction`,
a bronze table, etc. If bad data flowed downstream (Bronze → Silver → Gold), restore
the **upstream** table first, then re-run the EOD job (§2) to rebuild downstream cleanly.

### Restore from a CLONE backup (when history won't reach far enough)

If the good version has aged out of retention, recover from a backup clone. Take
these proactively before risky operations:

```sql
-- Take a point-in-time backup (DEEP CLONE = independent copy of data + metadata).
CREATE TABLE investsphere.gold.fact_limit_breach_backup
  DEEP CLONE investsphere.gold.fact_limit_breach;

-- ...to restore from that backup later, overwrite the live table from the clone:
CREATE OR REPLACE TABLE investsphere.gold.fact_limit_breach
  DEEP CLONE investsphere.gold.fact_limit_breach_backup;
```
> SHALLOW CLONE only copies metadata/pointers (fast, but breaks if source files are
> vacuumed) — use **DEEP CLONE** for a real backup you can rely on.

### Verification
```sql
DESCRIBE HISTORY investsphere.gold.fact_limit_breach;  -- newest op = RESTORE/CLONE
SELECT count(*) FROM investsphere.gold.fact_limit_breach;  -- row count back to expected
```

### Comms
Note which tables/business dates were restored and to which version, so downstream
consumers (dashboards, the AI agent) know which data changed.

---

## 4. Accidental table overwrite

**Symptom:** someone ran `CREATE OR REPLACE TABLE` / an `overwrite` write against the
wrong table, or a job overwrote a table it shouldn't have.

### Action
An overwrite is just another Delta commit — **RESTORE to the prior version**:

```sql
DESCRIBE HISTORY investsphere.silver.silver_transaction;       -- find the pre-overwrite version
RESTORE TABLE investsphere.silver.silver_transaction TO VERSION AS OF 88;
```

If the table was **dropped** (not just overwritten), recover with `UNDROP` within the
retention window:
```sql
UNDROP TABLE investsphere.silver.silver_transaction;
```

### Verification
`DESCRIBE HISTORY` shows the RESTORE/UNDROP as the latest op; spot-check row counts and
a few known keys.

### Comms
Same as §3 — name the table, version restored, and any downstream reruns triggered.

---

## 5. Broken RAG index

**Symptom:** the AI agent returns stale, empty, or wrong policy answers, or the
`investsphere.ai.policy_index` Vector/AI Search index is out of sync or failing.

### Action — re-sync, rebuild, or de-index

```bash
# OPTION A (fastest): trigger an incremental re-sync. The docs->RAG job does the
# MERGE + index sync end to end:
databricks bundle run investsphere_docs_rag -t prod

# OPTION B (full rebuild): re-run the index builder. This (re)creates the
# investsphere.ai.policy_index index on endpoint investsphere_ai_search.
#   Source: ai/01_build_ai_search_index.py
databricks workspace run ai/01_build_ai_search_index.py    # or run it as a notebook in the workspace
```

If the index itself is corrupt and a rebuild won't take, **de-index** (drop it) and
recreate from clean:

```python
# DE-INDEX: delete the broken index, then rebuild it from ai/01_build_ai_search_index.py.
from databricks.vector_search.client import VectorSearchClient
vsc = VectorSearchClient()
vsc.delete_index(
    endpoint_name="investsphere_ai_search",
    index_name="investsphere.ai.policy_index",
)
# Then re-run ai/01_build_ai_search_index.py to recreate + populate it.
```

> While the index is down, the agent should **fail closed** (no policy context) rather
> than answer from stale data. If your agent tooling supports it, disable the retrieval
> tool until the index is healthy.

### Verification
- The endpoint shows the index **ONLINE** and a recent sync timestamp.
- Ask the agent a known policy question and confirm a correct, sourced answer.
- Run the agent eval (`ai/evaluate_agent.py`) if you need a quantitative check.

### Comms
Tell stakeholders the agent's answers may have been unreliable during the window, and
when retrieval was restored.

---

## 6. Broken governance policy (row filter / column mask)

**Symptom:** a change to a row filter or column mask is over-blocking (users see
nothing) or under-blocking (users see data they shouldn't). Functions in play:
- Row filter `governance.portfolio_row_filter` — applied to **gold facts**.
- Column mask `governance.mask_counterparty_id` — applied to `silver.silver_transaction`.

### Action

**Fastest unblock — detach the policy from the affected table** (stops the bleeding;
data becomes visible again, so use deliberately):

```sql
-- Remove a row filter from a table (e.g. the gold fact):
ALTER TABLE investsphere.gold.fact_limit_breach DROP ROW FILTER;

-- Remove a column mask from a column:
ALTER TABLE investsphere.silver.silver_transaction
  ALTER COLUMN counterparty_id DROP MASK;
```

**Proper fix — correct the FUNCTION, not each table.** Filters/masks are referenced by
**name**, so fixing the underlying function fixes *every* table that uses it — no need
to touch each table:

```sql
-- Re-create the corrected row-filter function (logic fixed here propagates everywhere
-- portfolio_row_filter is referenced):
CREATE OR REPLACE FUNCTION governance.portfolio_row_filter(portfolio_id STRING)
RETURNS BOOLEAN
RETURN is_account_group_member('investsphere_full_access')
    OR portfolio_id IN (SELECT portfolio_id FROM governance.user_portfolio_acl
                        WHERE user_email = current_user());   -- corrected logic

-- Same idea for the column mask:
CREATE OR REPLACE FUNCTION governance.mask_counterparty_id(cid STRING)
RETURNS STRING
RETURN CASE WHEN is_account_group_member('investsphere_full_access')
            THEN cid ELSE 'REDACTED' END;
```

If you had to `DROP` the filter/mask off a table in the unblock step, **re-attach** it
after the function is fixed:

```sql
ALTER TABLE investsphere.gold.fact_limit_breach
  SET ROW FILTER governance.portfolio_row_filter ON (portfolio_id);

ALTER TABLE investsphere.silver.silver_transaction
  ALTER COLUMN counterparty_id SET MASK governance.mask_counterparty_id;
```

### Verification
Query as a **restricted** user (or impersonate one) and confirm they see exactly the
rows/columns they should — and an admin still sees everything.

### Comms
Governance bugs may be a **data-exposure incident**. If unmasked/over-shared data was
visible, notify security/compliance immediately and record the exposure window.

---

## 7. Emergency schedule disablement

**Symptom:** a scheduled job (e.g. `investsphere_eod`, `investsphere_maintenance_demo`)
keeps firing and making things worse, and you need it to **stop now** without losing
its definition.

### Action — PAUSE the schedule (don't delete the job)

```bash
# Find the job id by name.
databricks jobs list --output JSON | jq -r '.jobs[] | select(.settings.name=="investsphere_eod") | .job_id'

# Pause ONLY the schedule trigger; the job, history, and config stay intact.
databricks jobs update --job-id <job_id> --json '{"pause_status": "PAUSED"}'
```

> **UI alternative:** Workflows → open the job → the **Schedule/Trigger** panel → **Pause**.
> File-arrival-triggered jobs (`investsphere_ingest`, `investsphere_docs_rag`) have a
> trigger rather than a cron — pause the **trigger** the same way to stop them firing.

**Resume** once the incident is resolved:
```bash
databricks jobs update --job-id <job_id> --json '{"pause_status": "UNPAUSED"}'
# (or click Resume in the UI)
```

> Do **not** `databricks jobs delete` — that destroys the definition. The next
> `bundle deploy` would recreate it, but you'd lose any out-of-band state. Pause is
> reversible and instant.

### Verification
`databricks jobs get --job-id <job_id>` shows the trigger `pause_status: PAUSED`; no new
runs appear in the run list.

### Comms
Announce which schedule is paused and the expected resume time, so people aren't
surprised that EOD/maintenance "didn't run".

---

## 8. Quick reference — command cheat sheet

| Situation | One-liner |
|---|---|
| Roll back a deploy | `git checkout <tag>` → `python -m pip wheel . --no-deps -w dist` → `databricks bundle deploy -t prod` |
| Re-run a failed job | `databricks jobs repair-run <run_id> --rerun-all-failed-tasks` |
| See table history | `DESCRIBE HISTORY investsphere.gold.fact_limit_breach;` |
| Restore bad data | `RESTORE TABLE investsphere.gold.fact_limit_breach TO VERSION AS OF n;` |
| Backup a table | `CREATE TABLE x_backup DEEP CLONE x;` |
| Recover dropped table | `UNDROP TABLE investsphere.silver.silver_transaction;` |
| Rebuild RAG index | `databricks bundle run investsphere_docs_rag -t prod` (or run `ai/01_build_ai_search_index.py`) |
| Drop a row filter / mask | `ALTER TABLE ... DROP ROW FILTER;` / `ALTER COLUMN ... DROP MASK;` |
| Pause a schedule | `databricks jobs update --job-id <id> --json '{"pause_status":"PAUSED"}'` |

---

## 9. Communication & incident process

Run comms **in parallel** with the technical fix — don't wait for resolution.

1. **Declare the incident.** Post in the **#investsphere-incidents** channel:
   what's broken, when it started, suspected blast radius, who's driving (incident lead).
2. **Notify on-call.** On-call recipient = **`oncall_email` → santnair0599@gmail.com**
   (the address wired into every job's `on_failure` / duration alerts and the Lakeflow
   pipeline notifications). For data-exposure or governance incidents (§6), also page
   **security/compliance**.
3. **Status updates every 30 min** (or on any material change): current state, action
   in progress, next checkpoint time. Keep updates in the same incident thread.
4. **Notify affected consumers** if data changed: dashboard owners, downstream teams,
   and anyone relying on the AI agent's answers — state which tables/dates/versions moved.
5. **Declare resolution** with the final state: what was rolled back/restored/fixed, and
   the data versions now live.
6. **Post-incident review (within 48h).** Write a blameless PIR: timeline, root cause,
   detection gap, the rollback that worked, and concrete follow-ups (e.g. tag every
   release, add a DQ check, take a DEEP CLONE before risky loads). Track the action items
   to closure.
