# InvestSphere — Production Deployment Runbook

End-to-end sequence to take InvestSphere from a Free-Edition sandbox to a real
**dev → prod** Databricks deployment with orchestration, monitoring, and governance.
Each phase references the project artifact that implements it.

> Companion docs: `ROLLBACK_RUNBOOK.md` (recovery), `SECURITY_HARDENING.md`,
> `COST_MANAGEMENT.md`, `GOVERNANCE_MODEL.md`, `RAG_GOVERNANCE.md`, `RUNBOOK.md` (day-2).

---

## Phase 0 — Prerequisites (once)
1. **Two paid Databricks workspaces**: `investsphere-dev` and `investsphere-prod` (separate workspaces = cleanest isolation; minimum = one workspace + two catalogs). Unity Catalog enabled on both.
2. **Cloud account** (Azure or AWS) for storage + the monitoring host.
3. **Local tooling:** `databricks` CLI (≥ v0.2), `terraform`, `python -m pip`, `gh`.
4. **A service principal per environment** (non-interactive CI/CD) — create in the account console; record `client_id`/`secret`. Never use personal tokens in prod (see `SECURITY_HARDENING.md`).

## Phase 1 — Source control & branching
5. `git init`, push to GitHub. Flow: `feature/*` → **`develop`** (deploys dev) → **`main`** (deploys prod). Protect `main` (PR + approval).
6. `.gitignore` excludes `.venv/`, `dist/`, `__pycache__/`, `*.pyc`, `*.egg-info`.

## Phase 2 — Cloud + workspace foundation (Terraform)
7. Configure `terraform/providers.tf` + `terraform/variables.tf` with both workspace hosts and the cloud provider. **Separate Terraform state per environment.**
8. Apply the **Unity Catalog module** (`terraform/modules/unity_catalog/`): catalog `investsphere`, schemas `bronze/silver/gold/governance/ai/features/ml`, and the **Volumes** — `bronze.raw`, **`bronze._checkpoints`**, **`bronze._schemas`**, `ai.documents`. (The two `_`-volumes are the ones whose absence silently breaks ingestion.)
9. `terraform init && terraform plan && terraform apply` — **dev first**, then prod.

## Phase 3 — Identity, governance, secrets
10. Create account **groups**: `investsphere_engineers`, `investsphere_analysts`, `investsphere_pms`; add members. (`GRANT … TO group` works on paid workspaces.)
11. Run governance in order: `governance/01_catalog_and_schemas.sql` → `02_grants.sql` → `03_row_and_column_security.sql`. Verify with `SHOW GRANTS` + a filtered `SELECT`. Full model in `docs/GOVERNANCE_MODEL.md`.
12. **Secrets:** `databricks secrets create-scope investsphere`; store tokens/keys; reference via `dbutils.secrets.get(...)`. No hardcoded credentials.

## Phase 4 — Configure the bundle for dev/prod
13. In `databricks.yml`, set **distinct hosts** per target and override per-target variables; run prod jobs as the **service principal**:
```yaml
targets:
  dev:
    mode: development
    variables: { oncall_email: "dev-oncall@you.com", warehouse_id: "<dev_wh>" }
    workspace: { host: https://<dev-workspace>.databricks.com }
  prod:
    mode: production
    run_as: { service_principal_name: "<prod-sp-app-id>" }
    variables: { oncall_email: "prod-oncall@you.com", warehouse_id: "<prod_wh>" }
    workspace: { host: https://<prod-workspace>.databricks.com }
```
14. **Compute:** keep **serverless** (`environments` blocks — set `client` to your workspace's serverless env version) or switch to **classic job clusters** for steady-state cost control. Serverless = simplest; job clusters = cheaper at scale (sizing rules in `COST_MANAGEMENT.md`).
15. Confirm wheel wiring: `artifacts:` builds `investsphere_platform-*.whl`; each job's `environments.spec.dependencies` references it (+ `prometheus_client`, `pypdf`).

## Phase 5 — CI (validate, test, build)
16. `.github/workflows/ci.yml` on every PR: `pip install -e .` → `pytest -q` (unit) → `python -m pip wheel . --no-deps -w dist` → **`databricks bundle validate -t dev`**.

## Final local validation before first dev deployment
Run these locally and confirm each passes **before** the first `bundle deploy -t dev`:
```bash
pytest -q                          # unit tests (pure-Python lib) — proves code logic
pytest tests/integration -q        # integration smoke — SKIPS cleanly if no warehouse env vars
databricks bundle validate -t dev  # bundle schema + reference validation
terraform fmt -recursive           # format all Terraform (incl. modules/unity_catalog)
terraform validate                 # validate Terraform (run inside an initialized terraform/ dir)
docker compose -f monitoring/docker-compose.yml config   # validate the monitoring stack (no start)
```
- `pytest tests/integration -q` needs `DATABRICKS_SERVER_HOSTNAME` / `DATABRICKS_HTTP_PATH` / `DATABRICKS_TOKEN`; without them it **skips** (expected pre-deploy).
- `terraform validate` requires `terraform init` first; the `unity_catalog` module is consumed from the root config.
- `docker compose config` renders + validates the compose file without starting containers.

All green → proceed to Phase 6.

## Phase 6 — Deploy to DEV + smoke test
17. Authenticate CLI to dev, then:
```bash
databricks bundle validate -t dev
databricks bundle deploy   -t dev
```
18. Run the medallion end-to-end:
```bash
databricks bundle run investsphere_ingest -t dev   # bronze
databricks bundle run investsphere_eod    -t dev   # readiness→silver→gold→metrics→dq
```
19. Run the **integration smoke tests** (`tests/integration/test_databricks_smoke.py`) — they assert the deployed platform actually works (schemas, tables, breach data, DQ rows, RAG boundary), not just code logic.

## Phase 7 — Data landing + orchestration
20. Establish the landing zone with **immutable filenames** (`*_YYYY_MM_DD.csv/json` in `/Volumes/investsphere/bronze/raw/<source>/`) so file-arrival triggers fire on new files only. Each source is governed by a **data contract** (`contracts/*.yml`).
21. Orchestration is in the bundle: **file-arrival** `investsphere_ingest`, **daily 18:00** `investsphere_eod` (conditional `readiness_gate → feeds_ready → silver → gold → export_metrics + dq_checks`, else `notify_not_ready`), **monthly** NAV, **weekly** maintenance, **on-upload** docs→RAG. Retries/timeouts/health/notifications are applied via YAML anchors.

## Phase 8 — Monitoring (Prometheus + Pushgateway + Grafana)
22. Stand up the stack with `monitoring/docker-compose.yml` (Prometheus + Pushgateway + Grafana, dashboard auto-provisioned). Architecture in `MONITORING_EXTERNAL.md`.
23. The EOD `export_metrics` task runs `pipelines/export_pipeline_metrics.py` → `monitoring/prometheus_exporter.py`, pushing rows_valid/quarantined/quarantine_rate/breach_count/bronze_rescued_rows. Set the `pushgateway_url` job parameter.
24. Import `dashboards/grafana_pipeline_dashboard.json`. Add **Databricks system tables** (`system.billing`, `system.lakeflow`) as a second source for cost/job dashboards — queries in `dashboards/platform_ops_dashboard.sql`.

## Phase 9 — DQ + reconciliation + alerting
25. `quality_monitoring/custom_dq_checks.sql` (per-run DQ) and `quality_monitoring/reconciliation_checks.sql` (Bronze=Silver+Quarantine, dup keys, totals ≈100%, feed freshness) write to `governance.dq_results` / `governance.reconciliation_results`.
26. `terraform/dq_alerts.tf` creates Databricks SQL alerts on those tables (quarantine rate, freshness, rescued rows, breaches). `terraform apply` per env.

## Phase 10 — Promote to PROD (CD)
27. `.github/workflows/cd.yml`: on merge to `main`, authenticate with the **prod service principal** → `bundle validate -t prod` → **manual approval (GitHub environment)** → `bundle deploy -t prod` → **post-deploy smoke test**.
28. First prod deploy: run Terraform + governance for prod (Phases 2–3 against prod), then deploy. Jobs run **as the SP**.
29. Validate with a controlled backfill before enabling schedules.

### GitHub Environments & secrets setup (required by `cd.yml`)
`cd.yml` deploys via per-environment service principals and gates prod behind manual approval. Configure once in GitHub:
1. **Repo → Settings → Environments → New environment:** create **`dev`** and **`prod`**.
2. On **`prod`**, add **Required reviewers** (you / a teammate) — this enforces the manual approval gate before any prod deploy. Optionally add a wait timer and restrict deployments to the `main` branch.
3. **Per environment → Environment secrets**, add the service-principal (OAuth M2M) credentials — *different SP per environment*:
   - `DATABRICKS_HOST` — that environment's workspace URL
   - `DATABRICKS_CLIENT_ID` — the SP application (client) id
   - `DATABRICKS_CLIENT_SECRET` — the SP OAuth secret
4. Grant each SP the workspace + Unity Catalog privileges it needs (deploy bundles, run jobs, write its catalog) — see `SECURITY_HARDENING.md`.
5. Verify the flow: push to **`develop`** → dev deploy runs automatically; merge a PR to **`main`** → prod deploy **waits on the approval gate**, then runs.

> Use **environment-scoped** secrets (not repo-level) so dev and prod credentials stay isolated. Never commit tokens.

## Phase 11 — Production hardening
30. **DR:** Delta **DEEP CLONE** gold/silver to a secondary region (RPO ≤24h, RTO ≤4h, quarterly restore drill — `DEPLOYMENT.md`).
31. **Storage lifecycle:** `storage_lifecycle/` (staging→delete 30d; archive→Cool→Archive; **active Delta excluded**). Redundancy LRS (dev) / ZRS·GZRS (prod).
32. **Maintenance:** enable **Predictive Optimization** (prod) + keep weekly `maintenance` job; never `VACUUM RETAIN 0`.
33. **Security & cost:** complete `SECURITY_HARDENING.md` (cluster policies, network, key rotation) and `COST_MANAGEMENT.md` (budgets, warehouse auto-stop, AI Search cleanup).

## Phase 12 — Day-2 ops + AI/RAG
34. Operate from `RUNBOOK.md` (daily checklist, incident playbooks, backfill, teardown) and `ROLLBACK_RUNBOOK.md` for recovery.
35. **AI/RAG (paid):** `ai/01_build_ai_search_index.py` creates the Vector Search endpoint + index; `investsphere_docs_rag` keeps it fresh. Governance + tests in `RAG_GOVERNANCE.md` / `tests/integration/test_rag_boundary.py`. **Cost guard:** delete the AI Search index/endpoint after demos (~$200/mo idle).

---

## Deploy commands reference
```bash
databricks bundle validate -t dev      # CI + before every deploy
databricks bundle deploy   -t dev      # dev
databricks bundle run <job> -t dev      # run one job
# PR → main → cd.yml → approval →
databricks bundle deploy   -t prod      # prod, as service principal
```

## Production readiness checklist
- [ ] Terraform-provisioned catalog/schemas/volumes (incl. `_checkpoints`/`_schemas`)
- [ ] Groups + grants + row filters/masks applied and verified
- [ ] Secrets in scopes; no personal tokens in prod; SP-based CD
- [ ] CI (validate+test+wheel) green on PRs; CD with prod approval gate
- [ ] Data contracts enforced per source; reconciliation passing
- [ ] Monitoring stack up; Grafana + system-table dashboards live; DQ alerts firing
- [ ] DR clone + storage lifecycle + Predictive Optimization configured
- [ ] Rollback runbook tested; AI Search cost guard in place
