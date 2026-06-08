# InvestSphere — End-to-End Implementation Guide (Azure Production)

A complete, sequential build of InvestSphere on **Azure Databricks with ADLS Gen2** —
from an empty cloud subscription to a governed, orchestrated, monitored, CI/CD-deployed
lakehouse. Each phase has concrete commands and the project file it uses.

**Legend:** 🟢 one-time foundation · 🔁 per-environment (run for dev, then prod) · ⚙️ automated by CI/CD afterwards.

> Companion docs: `PRODUCTION_DEPLOYMENT.md` (phase reference), `GOVERNANCE_MODEL.md`,
> `SECURITY_HARDENING.md`, `COST_MANAGEMENT.md`, `ROLLBACK_RUNBOOK.md`, `RUNBOOK.md`.

---

## Phase 0 — Accounts & tooling 🟢
- An **Azure subscription** with rights to create resource groups, storage, and Databricks.
- Local tools (you already have these): `az` CLI, **Databricks CLI — latest (1.1.0+)**, `terraform`, `docker`, `python`, `git`, `gh`.
  > Bundles are now **Declarative Automation Bundles** (formerly Databricks Asset Bundles); `databricks.yml` is the main bundle config file. AI Search **endpoint resources** in bundles require **Databricks CLI ≥ 1.1.0**.
- Decide naming: RG `rg-investsphere`, region `uaenorth` (or `eastus`), storage `stinvestsphere`, workspaces `dbx-investsphere-dev` / `dbx-investsphere-prod`.
```powershell
az login
az account set --subscription "<your-sub-id>"
```

## Phase 1 — Source control 🟢
```powershell
cd C:\dev\investsphere-production
git init; git add .; git commit -m "InvestSphere production baseline"
gh repo create investsphere-production --private --source . --push
```
Branches: `feature/*` → **`develop`** (auto-deploys dev) → **`main`** (deploys prod, gated). Protect `main` (PR + approval).

## Phase 2 — Azure storage foundation (ADLS Gen2) 🟢
```powershell
az group create -n rg-investsphere -l uaenorth

# ADLS Gen2 = StorageV2 + hierarchical namespace
az storage account create -n stinvestsphere -g rg-investsphere -l uaenorth `
  --sku Standard_ZRS --kind StorageV2 --enable-hierarchical-namespace true

# one container per environment (keeps dev/prod data isolated)
az storage fs create -n investsphere-dev  --account-name stinvestsphere --auth-mode login
az storage fs create -n investsphere-prod --account-name stinvestsphere --auth-mode login

# Databricks Access Connector (managed identity Databricks uses to reach ADLS)
az databricks access-connector create -n ac-investsphere -g rg-investsphere -l uaenorth `
  --identity-type SystemAssigned
# grant it data access on the storage account
$acId  = az databricks access-connector show -n ac-investsphere -g rg-investsphere --query id -o tsv
$acMi  = az databricks access-connector show -n ac-investsphere -g rg-investsphere --query identity.principalId -o tsv
$saId  = az storage account show -n stinvestsphere -g rg-investsphere --query id -o tsv
az role assignment create --assignee-object-id $acMi --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Contributor" --scope $saId
```
> **File-arrival triggers / file events** need more than blob access. Grant the access connector managed identity, **by scope**:
> - **Storage account:** Storage Blob Data Contributor, **Storage Queue Data Contributor**, **Storage Account Contributor**
> - **Resource group:** **EventGrid Data Contributor**
>
> Databricks file events use storage queues + Event Grid; without these, file-arrival job triggers can't be set up.
> (For Auto Loader **file-notification** mode specifically, `EventGrid EventSubscription Contributor` may also appear in older/example-based guidance.)

> **Dev/prod isolation:** one storage account with separate containers (`investsphere-dev` / `-prod`) is acceptable for a controlled portfolio build. For **stronger production isolation** — independent lifecycle policies, cost tracking, network controls, and blast-radius separation — use **separate storage accounts and access connectors per environment** (`stinvestspheredev` / `stinvestsphereprod`, `ac-investsphere-dev` / `-prod`).

## Phase 3 — Databricks workspaces + Unity Catalog 🔁
```powershell
# Premium SKU is required for Unity Catalog
az databricks workspace create -n dbx-investsphere-dev  -g rg-investsphere -l uaenorth --sku premium
az databricks workspace create -n dbx-investsphere-prod -g rg-investsphere -l uaenorth --sku premium
```
In the **Databricks account console** (accounts.azuredatabricks.net): create/assign a **Unity Catalog metastore** for the region and attach both workspaces. Note each workspace URL (→ `databricks.yml` targets).

## Phase 4 — Wire UC to ADLS: storage credential + external location 🔁
This is the "Volumes are ADLS" wiring. Do it per environment (dev container, then prod). SQL form (run in each workspace's SQL editor as a metastore admin):
```sql
-- 1. credential = the access connector
CREATE STORAGE CREDENTIAL investsphere_cred
  WITH AZURE_MANAGED_IDENTITY (access_connector_id = '<acId from Phase 2>');

-- 2. external location = a governed pointer at the ADLS container
CREATE EXTERNAL LOCATION investsphere_dev
  URL 'abfss://investsphere-dev@stinvestsphere.dfs.core.windows.net/'
  WITH (STORAGE CREDENTIAL investsphere_cred);
```
> **Validate the exact syntax once.** The concept is correct — an Azure managed-identity storage credential uses the **Access Connector ID** — but the `CREATE STORAGE CREDENTIAL` SQL form varies slightly by Databricks SQL / UI version. Run it once in a **dev** SQL editor; if it errors, use **Terraform** (the repeatable, industry-standard path):
> ```hcl
> resource "databricks_storage_credential" "investsphere" {
>   name = "investsphere_cred"
>   azure_managed_identity {
>     access_connector_id = var.access_connector_id
>   }
> }
> resource "databricks_external_location" "investsphere_dev" {
>   name            = "investsphere_dev"
>   url             = "abfss://investsphere-dev@stinvestsphere.dfs.core.windows.net/"
>   credential_name = databricks_storage_credential.investsphere.name
> }
> ```
> Add these to `terraform/modules/unity_catalog/` for repeatability.

## Phase 5 — Catalog, schemas, volumes (IaC) 🔁
Call the Terraform UC module from a root config that also creates the **external** volumes on ADLS:
```powershell
cd terraform
$env:DATABRICKS_HOST = "https://<dev-workspace-url>"
$env:DATABRICKS_TOKEN = "<dev PAT or use OAuth>"
terraform init
terraform apply   # creates catalog investsphere + 7 schemas + volumes
```
Volumes (raw / `_checkpoints` / `_schemas` / `ai.documents`) — in prod make the landing + documents volumes **external** so upstream teams write to a known ADLS path:
```sql
CREATE EXTERNAL VOLUME investsphere.bronze.raw
  LOCATION 'abfss://investsphere-dev@stinvestsphere.dfs.core.windows.net/bronze/raw';
CREATE EXTERNAL VOLUME investsphere.ai.documents
  LOCATION 'abfss://investsphere-dev@stinvestsphere.dfs.core.windows.net/ai/documents';
-- internal state can stay managed:
CREATE VOLUME IF NOT EXISTS investsphere.bronze.`_checkpoints`;
CREATE VOLUME IF NOT EXISTS investsphere.bronze.`_schemas`;
```
> ⚠️ **Non-overlapping paths:** keep each external volume in its **own subdirectory** under the external location; do **not** create tables and volumes on overlapping paths (path conflicts break governance/listing).
> ⚠️ **Checkpoint/schema volumes:** `_checkpoints` and `_schemas` should exist as **dedicated Unity Catalog volumes**. If they're missing or misconfigured, Auto Loader may fail, lose schema/checkpoint state, or write metadata to an unintended location.

## Phase 6 — Identity, governance, secrets 🔁
```sql
-- run in order in the SQL editor
-- governance/01_catalog_and_schemas.sql   (if not done by Terraform)
-- governance/02_grants.sql                (groups investsphere_engineers/analysts/pms must exist first)
-- governance/03_row_and_column_security.sql
-- quality_monitoring/reconciliation_checks.sql is run by the EOD job later
```
Create the 3 **account groups** + members in **Account console → Identity**. Secrets:
```powershell
databricks secrets create-scope investsphere
databricks secrets put-secret investsphere pushgateway_token   # etc.
```
Full model in `GOVERNANCE_MODEL.md`; hardening in `SECURITY_HARDENING.md`.

## Phase 7 — Package the library + configure the bundle 🟢/🔁
```powershell
python -m pip wheel . --no-deps -w dist     # builds investsphere_platform-0.1.0-...whl (bundle artifacts does this on deploy too)
```
Edit `databricks.yml` targets — distinct hosts, per-env variables, prod runs as a service principal:
```yaml
targets:
  dev:
    variables: { warehouse_id: "<dev_wh>", oncall_email: "dev-oncall@you.com" }
    workspace: { host: https://<dev-workspace-url> }
  prod:
    run_as: { service_principal_name: "<prod-sp-app-id>" }
    variables: { warehouse_id: "<prod_wh>", oncall_email: "prod-oncall@you.com" }
    workspace: { host: https://<prod-workspace-url> }
```
**Compute:** keep serverless `environments` (set `client` to your workspace's serverless env version), or switch jobs to classic `job_clusters` for steady-state cost (sizing in `COST_MANAGEMENT.md`).

## Phase 8 — CI (validate + test + build) ⚙️
`.github/workflows/ci.yml` runs on every PR: `pip install -e .` → `pytest -q` → `pip wheel` → `databricks bundle validate -t dev`. Confirm it goes green on your first PR.

## Phase 9 — Deploy to DEV 🔁
```powershell
databricks auth login --host https://<dev-workspace-url>
databricks bundle validate -t dev
databricks bundle deploy   -t dev     # uploads wheel + creates 5 jobs + Lakeflow pipeline + schedules/triggers
```

## Phase 10 — Land data + run the medallion 🔁
```powershell
python data\generate_data.py
# upload each source into its OWN folder named exactly the table key (immutable dated filenames):
databricks fs cp data\reference_data\portfolio_master_2026_06_05.csv `
  dbfs:/Volumes/investsphere/bronze/raw/portfolio_master/ --overwrite
# ... 14 sources

databricks bundle run investsphere_ingest -t dev   # Bronze (Auto Loader → raw_*)
databricks bundle run investsphere_eod    -t dev   # readiness → silver → gold → export_metrics + dq_checks
```
The EOD job is the conditional DAG: `readiness_gate → feeds_ready (condition) → silver → gold`, false-branch → `notify_not_ready`. Monthly NAV, weekly maintenance, and the docs→RAG file-arrival job deploy alongside.

## Phase 11 — Verify 🔁
```powershell
$env:DATABRICKS_SERVER_HOSTNAME="<dev-host>"; $env:DATABRICKS_HTTP_PATH="/sql/1.0/warehouses/<wh>"; $env:DATABRICKS_TOKEN="<PAT>"
pip install databricks-sql-connector
pytest tests/integration -q          # schemas/tables/breach/DQ/RAG-boundary on the LIVE platform
```
Each source is governed by `contracts/*.yml`; reconciliation populates `governance.reconciliation_results`.

## Phase 12 — Monitoring 🔁
**In-platform (no external infra):** schedule `dashboards/platform_ops_dashboard.sql` (system tables) for job/cost/audit/DQ dashboards.
**Prometheus + Grafana** (for the pushed pipeline metrics): run the stack on a **small Azure VM with a reachable IP** (a serverless job can't reach localhost):
```bash
# on the VM:
cd monitoring && docker compose up -d        # Pushgateway :9091, Prometheus :9090, Grafana :3000
```
Set the EOD job's `pushgateway_url` parameter to `http://<vm-ip>:9091`. Metric-name contract + verification in `monitoring/README.md`.

## Phase 13 — DQ alerting (Terraform) 🔁
```powershell
cd terraform
terraform apply -var "databricks_host=https://<host>" -var "warehouse_id=<wh>" -var "oncall_email=<you>"
# creates one databricks_alert_v2 per metric (inline query + 30-min schedule) + notification destination
```

## Phase 14 — AI / RAG (optional, paid) 🔁
- **First-time setup** → `ai/01_build_ai_search_index.py` (creates the AI Search endpoint + Delta-sync index over `ai.policy_chunks`).
- **After document changes** → `ai/03_refresh_documents.py` (incremental MERGE + index sync). Or via the bundle:
```powershell
# upload ONLY APPROVED PDFs to /Volumes/investsphere/ai/documents/
# (NEVER the restricted private_investment_committee_memo.pdf), then:
databricks bundle run investsphere_docs_rag -t dev
```
**Requirements:** AI Search needs **Unity Catalog + serverless compute + Change Data Feed** on the source table (standard endpoints). SDK = `databricks-vectorsearch`; notebooks import `VectorSearchClient`. Governance + tests: `RAG_GOVERNANCE.md`, `tests/integration/test_rag_boundary.py`.
> 💸 **Cost guard:** AI Search endpoints are charged once an index is created; charges stop ~24h after the **last index is deleted from the endpoint**, and an endpoint's cost scales with the total size of indexes it serves. **Delete unused indexes/endpoints after demos and monitor billing.**

## Phase 15 — CD + promote to PROD ⚙️🔁
1. **GitHub Environments:** create `dev`/`prod`; add **Required reviewers** on `prod`; add per-env SP secrets (`DATABRICKS_HOST/CLIENT_ID/CLIENT_SECRET`). (Setup steps in `PRODUCTION_DEPLOYMENT.md`.)
2. Run Phases 3–6 against the **prod** workspace/container.
3. Merge to `main` → `cd.yml` runs `bundle validate -t prod` → **approval gate** → `bundle deploy -t prod` → smoke test. Jobs run as the SP.
4. Validate prod with a controlled backfill before enabling schedules.

## Phase 16 — Hardening & Day-2
- **DR:** Delta DEEP CLONE gold/silver to a secondary region (RPO ≤24h / RTO ≤4h).
- **Storage lifecycle:** apply `storage_lifecycle/` on the ADLS account (staging→delete 30d; archive→Cool→Archive; **active Delta excluded**). Redundancy ZRS/GZRS for prod.
- **Maintenance:** enable Predictive Optimization; keep weekly `maintenance` job; never `VACUUM RETAIN 0`.
- **Cost/security:** `COST_MANAGEMENT.md` (budgets, warehouse auto-stop, AI Search cleanup), `SECURITY_HARDENING.md` (SP rotation, cluster policies, network/Private Link).
- **Operate/recover:** `RUNBOOK.md` daily checklist; `ROLLBACK_RUNBOOK.md` for incidents.

---

## End-to-end verification checklist
- [ ] ADLS Gen2 + access connector + role assignment created
- [ ] UC metastore attached; storage credential + external location per env
- [ ] Catalog/schemas + volumes (raw/`_checkpoints`/`_schemas`/`ai.documents`) on ADLS
- [ ] Groups + grants + row filters/masks applied and verified
- [ ] Wheel built; bundle deploys; 5 jobs + Lakeflow pipeline present
- [ ] Bronze→Silver→Gold run clean; breach output present
- [ ] Integration tests pass against the live platform
- [ ] Data contracts + reconciliation passing
- [ ] In-platform dashboards live; Prometheus/Grafana reachable; DQ alerts firing
- [ ] CI green on PRs; CD deploys prod through the approval gate
- [ ] DR clone + storage lifecycle + cost guardrails configured
- [ ] AI Search endpoint deleted after demo

## Map: who runs what
| Concern | Tool | Files |
|---|---|---|
| Azure storage/identity | `az` CLI | (Phase 2) |
| UC catalog/schemas/volumes/credentials | Terraform | `terraform/`, `terraform/modules/unity_catalog/` |
| Governance | SQL | `governance/*.sql` |
| Orchestration/jobs/pipeline | DAB | `databricks.yml`, `pipelines/`, `ai/` |
| Quality/reconciliation | SQL | `quality_monitoring/*.sql` |
| CI/CD | GitHub Actions | `.github/workflows/ci.yml`, `cd.yml` |
| Monitoring | docker / system tables | `monitoring/`, `dashboards/`, `terraform/dq_alerts.tf` |
