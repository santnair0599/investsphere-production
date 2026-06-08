# InvestSphere Monitoring Stack

Self-contained Prometheus + Pushgateway + Grafana stack for visualising
InvestSphere pipeline metrics. **This runs OUTSIDE Databricks** (e.g. on a VM,
a laptop, or a small always-on host) — Databricks jobs only *push* metrics to it.

## How the push flow works

Databricks jobs are short-lived, so we **push** metrics rather than have
Prometheus scrape a long-running endpoint:

```
Databricks job ──push_metrics()──▶ Pushgateway ──scrape──▶ Prometheus ──query──▶ Grafana
```

1. `pipelines/export_pipeline_metrics.py` calls
   `src/investsphere_platform/monitoring/prometheus_exporter.py:push_metrics()`.
2. Metrics (see the table below) are pushed to the **Pushgateway** as Prometheus
   gauges, namespaced `investsphere_*` (e.g. `investsphere_rows_valid`).
3. **Prometheus** scrapes the Pushgateway every 15s (`honor_labels: true`, so the
   pushed `job` label is preserved).
4. **Grafana** reads from Prometheus and renders the auto-provisioned dashboard.

## Run it

```bash
cd monitoring
docker compose up -d
```

Tear down (keep data):

```bash
docker compose down
```

Tear down and wipe stored metrics/dashboards state:

```bash
docker compose down -v
```

## URLs

| Service     | URL                     | Notes                                   |
|-------------|-------------------------|-----------------------------------------|
| Grafana     | http://localhost:3000   | Login `admin` / `admin` — **CHANGE IN PROD** |
| Prometheus  | http://localhost:9090   | Query / target health                   |
| Pushgateway | http://localhost:9091   | Pushed-metrics inspection endpoint      |

The dashboard **InvestSphere - Pipeline Performance** is auto-provisioned under
the *InvestSphere* folder — no manual import needed.

## Point the pipeline at the Pushgateway

Run the exporter with `--pushgateway_url` set to this stack's Pushgateway.

If the Databricks job can reach this host directly:

```bash
python pipelines/export_pipeline_metrics.py \
  --pushgateway_url http://YOUR_MONITORING_HOST:9091
```

Locally (exporter and stack on the same machine):

```bash
python pipelines/export_pipeline_metrics.py \
  --pushgateway_url http://localhost:9091
```

> Inside Docker, the services talk to each other by service name
> (`http://pushgateway:9091`, `http://prometheus:9090`). The `localhost` URLs
> above are for reaching the stack from the **host**.

## Required Prometheus metric names (the contract the dashboard depends on)

`push_metrics()` emits each metric as `investsphere_` + a sanitized, lower-cased
version of the dict key, with a `job` label. The exact names the EOD job pushes —
**these are what the Grafana panels query, so they must match exactly**:

| Dict key (in code) | Prometheus metric name | Pushed by | Panel |
|---|---|---|---|
| `rows_in` | `investsphere_rows_in` | `pipeline_metrics()` | — |
| `rows_valid` | `investsphere_rows_valid` | `pipeline_metrics()` | Valid rows |
| `rows_quarantined` | `investsphere_rows_quarantined` | `pipeline_metrics()` | Valid vs quarantined |
| `quarantine_rate_pct` | `investsphere_quarantine_rate_pct` | `pipeline_metrics()` | **Quarantine rate %** |
| `duration_seconds` | `investsphere_duration_seconds` | `pipeline_metrics()` | — |
| `breach_count` | `investsphere_breach_count` | `export_pipeline_metrics.py` | Open limit breaches |
| `bronze_rescued_rows` | `investsphere_bronze_rescued_rows` | `export_pipeline_metrics.py` | Bronze rescued rows |

All series carry the label `job="investsphere_eod"`.

> ⚠️ It is `investsphere_quarantine_rate_pct` — **not** `..._transaction_quarantine_rate_pct`.
> The authoritative source is `pipeline_metrics()` in
> `src/investsphere_platform/monitoring/pipeline_metrics.py` and the two extra keys
> added in `pipelines/export_pipeline_metrics.py`. If you add/rename a metric there,
> update the panel `expr` in `grafana/dashboards/investsphere_pipeline.json` to match.

### How to verify the names are correct
```bash
# 1. After a job run (or a manual push), list everything the Pushgateway holds:
curl -s http://localhost:9091/metrics | grep '^investsphere_'

# 2. Confirm a specific metric resolves in Prometheus:
#    open http://localhost:9090  and query:  investsphere_quarantine_rate_pct
```
If a Grafana panel is empty, 90% of the time the panel `expr` and the actual
pushed metric name disagree — compare the two with the `curl` above.

## Verifying (end-to-end smoke)

1. Push some metrics (run `export_pipeline_metrics.py` against the Pushgateway).
2. Confirm they landed: open http://localhost:9091 and look for
   `investsphere_*` series (or use the `curl` above).
3. In Prometheus (http://localhost:9090) query e.g. `investsphere_rows_valid`.
4. Open Grafana → *InvestSphere* folder → *Pipeline Performance*.

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Brings up pushgateway, prometheus, grafana |
| `prometheus.yml` | Prometheus scrape config (pushgateway + self) |
| `grafana/provisioning/datasources/prometheus.yml` | Auto-creates the Prometheus datasource |
| `grafana/provisioning/dashboards/dashboards.yml` | Dashboard provider config |
| `grafana/dashboards/investsphere_pipeline.json` | Auto-loaded dashboard |

The dashboard JSON mirrors `dashboards/grafana_pipeline_dashboard.json` at the
repo root; keep them in sync if you change panels.
