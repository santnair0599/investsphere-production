# InvestSphere — Security Hardening Checklist

A practical, checklist-style hardening guide for the InvestSphere platform on
**Databricks (serverless, Unity Catalog)**, deployed with a **Databricks Asset
Bundle** (targets `dev` / `prod`) and a GitHub Actions CD pipeline.

Each item is actionable and carries a one-line **why**. Work top-to-bottom per
area; treat unchecked boxes as open risk.

Related docs:
- Identity-level grants, row filters and column masks live in the governance SQL:
  `../governance/01_catalog_and_schemas.sql`, `../governance/02_grants.sql`,
  `../governance/03_row_and_column_security.sql` (the "GOVERNANCE_MODEL").
- Ops/cost guardrails: `COST_MANAGEMENT.md`.
- Audit & security dashboard tiles: `../dashboards/platform_ops_dashboard.sql`
  (TILE 14 grant changes, TILE 15 failed logins).

> Conventions used throughout: catalog `investsphere`; groups
> `investsphere_engineers` / `investsphere_analysts` / `investsphere_pms`;
> secret scope `investsphere`; bundle variable `oncall_email`.

---

## 1. Identity model (users vs groups vs service principals)

- [ ] **Humans authenticate interactively, in `dev` only.** — Engineers explore and
  build in dev; they never hold standing write access to prod data.
- [ ] **Prod jobs and CD run as a service principal (SP), never as a person.** — A
  pipeline must not break (or carry a human's privileges) when someone leaves.
- [ ] **All access is granted to GROUPS, not individual users or SPs.** — Membership
  changes in one place; grants stay stable and auditable.
- [ ] **Three role groups exist and are the only grant targets:**
  `investsphere_engineers` (build, read/write all layers),
  `investsphere_analysts` (read Gold), `investsphere_pms` (read Gold, row-filtered). —
  Maps cleanly to least privilege per persona.
- [ ] **Service principals are themselves placed in a dedicated group** (e.g.
  `investsphere_engineers` for the prod job SP, or a narrower SP-only group). — SP
  privileges are reviewed the same way as human ones.
- [ ] **One SP per environment** (a `dev` SP and a separate `prod` SP). — Blast radius
  of a leaked credential is confined to a single environment.

## 2. Service principals & tokens

- [ ] **Use OAuth M2M (client ID + secret) for the CD service principal — NO personal
  access tokens (PATs) in production.** — PATs are long-lived bearer tokens tied to a
  human; OAuth M2M secrets are SP-scoped and rotatable.
- [ ] **CD authenticates with `DATABRICKS_HOST` / `DATABRICKS_CLIENT_ID` /
  `DATABRICKS_CLIENT_SECRET` only** (the bundle reads these from the environment). —
  Keeps the deploy identity machine-only and environment-scoped.
- [ ] **The prod SP has exactly the privileges its jobs need — no `ALL PRIVILEGES` on
  the metastore.** — A compromised deploy identity cannot pivot to unrelated data.
- [ ] **Disable / do not issue PATs for the prod SP.** — Removes the easiest token to
  leak and the hardest to rotate.
- [ ] **Humans never share or reuse the SP credential locally.** — Preserves the
  human-vs-machine audit boundary; local dev uses the human's own login.

## 3. Secret management

- [ ] **All secrets live in Databricks secret scopes (scope `investsphere`) and are
  read via `dbutils.secrets.get(scope="investsphere", key=...)`.** — Secrets never sit
  in notebooks, repos, or job JSON; reads are access-controlled and redacted in logs.
- [ ] **What belongs in the scope:** source DB / API credentials, Pushgateway URL +
  auth, any third-party keys, vector-search / model endpoint tokens. — One audited
  place for every runtime secret.
- [ ] **What does NOT go in code or the bundle YAML:** any password, key, token, or
  connection string — reference the scope instead. — `git grep` for secrets should
  always come back empty.
- [ ] **CI/CD secrets live in GitHub *Environment* secrets, scoped per environment**
  (`dev` and `prod` environments, each with its own `DATABRICKS_HOST/CLIENT_ID/
  CLIENT_SECRET`). — Prod deploy credentials are unavailable to dev workflows and PRs.
- [ ] **Restrict who can read each secret scope** (engineers, prod SP). — Analysts/PMs
  have no reason to read pipeline credentials.
- [ ] **No secrets in plaintext env vars, cluster env, or print/log statements.** —
  Avoids accidental leakage into job logs and the driver console.

## 4. Least-privilege grants (Unity Catalog)

- [ ] **Grant to groups, never users** (see `../governance/02_grants.sql`). — Single
  source of truth for "who can see what".
- [ ] **Minimum privileges per layer:**
  - Engineers: `ALL PRIVILEGES` on `bronze` / `silver` / `gold` schemas (they build).
  - Analysts & PMs: `USE SCHEMA` + `SELECT` on **`gold` only** — no Bronze/Silver. —
    Raw and intermediate data stay invisible to read-only consumers.
- [ ] **Gold is read-only for analysts and PMs** (`SELECT`, never `MODIFY`). — Reporting
  users cannot mutate curated facts.
- [ ] **`USE CATALOG` is the floor for everyone; nothing above that by default.** —
  New objects are private until explicitly granted.
- [ ] **No grants directly on the metastore/storage credentials to consumer groups.** —
  Prevents bypassing UC table-level controls via raw paths.
- [ ] **Re-run grants from version-controlled SQL, not ad-hoc in the UI.** — Drift is
  caught by re-applying the authoritative script.

## 5. Cluster policies & SQL warehouses

- [ ] **Enforce a cluster policy that caps node types, autoscale max workers, and
  pins/limits the runtime (DBR) version.** — Stops accidental oversized or outdated
  clusters (cost + CVE exposure).
- [ ] **Policy forces required tags** (e.g. `env`, `project=investsphere`, cost-center).
  — Every dollar of spend is attributable in `system.billing.usage`.
- [ ] **Policy enforces auto-termination on interactive clusters.** — Idle clusters
  cannot linger and bill.
- [ ] **SQL warehouses: grant `CAN USE` to the right groups only; admins manage.** —
  Read consumers can query but cannot resize/stop shared warehouses.
- [ ] **Right-size warehouses and set short auto-stop** (see `COST_MANAGEMENT.md`). —
  Security and cost overlap: smaller, auto-stopping resources have a smaller window.
- [ ] **Serverless is the default; if classic compute is used, it must come from a
  policy.** — No unmanaged compute paths exist.

## 6. Unity Catalog fine-grained controls

- [ ] **Row-level security via `portfolio_row_filter`: PMs see only mapped portfolios;
  engineers/analysts see all.** — Enforces portfolio-manager data isolation centrally
  (`../governance/03_row_and_column_security.sql`).
- [ ] **Column masking hides raw counterparty id from non-engineers.** — Sensitive
  identifiers are masked at query time, not duplicated into "safe" copies.
- [ ] **Filters/masks are attached BY NAME to every Gold fact carrying `portfolio_id`.**
  — Fixing the function once fixes all tables; no per-table drift.
- [ ] **Keep the column contract** (`pm_portfolio_map(pm_user, portfolio_id)`) **in
  sync** — UC evaluates filters lazily, so a wrong column name only errors on read. —
  Prevents confusing `UNRESOLVED_COLUMN` failures in production queries.
- [ ] **Treat the governance SQL as the canonical policy and review changes to it like
  code.** — Security posture is reviewable in PRs.

## 7. Network controls *(availability varies by tier/cloud — confirm in your workspace)*

- [ ] **IP access lists on the workspace** restrict console/API access to known
  egress ranges (corp VPN, CI runners). — Stops credential use from arbitrary IPs.
- [ ] **Private Link / private networking** for workspace ↔ control plane and
  workspace ↔ storage where the tier supports it. — Keeps platform traffic off the
  public internet.
- [ ] **Storage firewall + private endpoints on ADLS**, allowing only the Databricks
  managed/VNet and trusted services. — Data at rest is unreachable via public network.
- [ ] **No "all-IPs" or public-blob fallbacks left enabled.** — Closes the default-open
  paths that survive misconfiguration.
- [ ] **Document which of these your tier actually supports** and mark the rest as
  compensating-control gaps. — Honest posture beats assumed protection.

## 8. Audit logging & monitoring

- [ ] **Enable Unity Catalog / account audit via system tables (`system.access.audit`)
  and grant SELECT on the `system` schema to security reviewers.** — Central, queryable
  record of every UC and account action.
- [ ] **Monitor grant / permission changes** (dashboard TILE 14:
  `action_name ILIKE '%Grant%' OR '%Permission%' OR '%updatePermissions%'`). —
  Privilege escalation is visible within a day.
- [ ] **Monitor failed logins** (dashboard TILE 15: `action_name ILIKE '%login%'` with
  non-200 / error). — Brute-force or credential-stuffing attempts surface early.
- [ ] **Alert on monitored events** through the existing Prometheus / Pushgateway /
  Grafana path; route to `oncall_email`. — Audit data is useless if no one is paged.
- [ ] **Review the audit tiles on a fixed cadence** (e.g. weekly) even with alerting. —
  Catches slow-burn misuse that no single alert trips.

## 9. Key & secret rotation

- [ ] **Define a rotation cadence:** SP OAuth secrets and source credentials every
  **90 days** (sooner on suspected compromise); review yearly. — Bounds the value of a
  leaked secret.
- [ ] **Rotate SP secrets with zero downtime** by overlapping: (1) generate a *second*
  OAuth secret on the SP, (2) update the GitHub Environment secret
  (`DATABRICKS_CLIENT_SECRET`), (3) confirm the next deploy/job succeeds, (4) delete
  the old secret. — Two valid secrets exist during the cutover, so nothing breaks.
- [ ] **Rotate scope contents** (DB/API creds) by writing the new value with
  `databricks secrets put-secret --scope investsphere ...`, verifying the next run,
  then revoking the old upstream credential. — `dbutils.secrets.get` picks up the new
  value with no code change.
- [ ] **If any PAT exists for break-glass, treat it as short-lived and rotate on use.**
  — Long-lived human tokens are the highest-risk credential.
- [ ] **Record each rotation** (what, when, by whom) and re-run the audit query to
  confirm. — Rotation is provable, not assumed.
- [ ] **On confirmed compromise:** revoke the secret immediately, rotate, and review
  `system.access.audit` for the credential's recent actions. — Limits and scopes the
  blast radius.

---

### Quick "is it hardened?" pass
1. No PATs in prod; CD uses a per-env SP via GitHub Environment secrets. ✅
2. `git grep` for secrets is empty; everything reads from scope `investsphere`. ✅
3. Grants target groups; analysts/PMs see Gold only; PMs are row-filtered. ✅
4. Cluster policy caps size/runtime and enforces tags; warehouses auto-stop. ✅
5. Audit tiles (grants, failed logins) reviewed and alerting to `oncall_email`. ✅
6. Rotation cadence defined and last rotation logged. ✅
