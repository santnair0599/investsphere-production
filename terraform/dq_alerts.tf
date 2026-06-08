# InvestSphere DATA-QUALITY ALERTS as code.
#
# Turns the queries in quality_monitoring/dq_alerts.sql into scheduled Databricks SQL
# Alerts so DQ regressions are not just dashboarded but actually PAGE someone. Each
# metric becomes a single databricks_alert_v2 (inline query + condition + 30-minute
# schedule) that notifies the on-call destination on breach.
#
# Requires a SQL warehouse id and a Databricks provider that ships databricks_alert_v2.
#   terraform apply -var 'warehouse_id=...' -var 'oncall_email=...'

# Notification destination (email) the alerts fire to.
resource "databricks_notification_destination" "dq_oncall" {
  display_name = "investsphere-dq-oncall"
  config {
    email {
      addresses = [var.oncall_email]
    }
  }
}

# The DQ metrics we alert on. `op`/`threshold` mirror the conditions documented in
# quality_monitoring/dq_alerts.sql. `query` selects the latest value AS metric_value.
locals {
  dq_alerts = {
    schema_drift = {
      display   = "InvestSphere DQ - Bronze schema drift (rescued rows > 0)"
      check     = "bronze_rescued_rows_count"
      op        = "GREATER_THAN"
      threshold = 0
    }
    quarantine_rate = {
      display   = "InvestSphere DQ - Quarantine rate > 2%"
      check     = "transaction_quarantine_rate_pct"
      op        = "GREATER_THAN"
      threshold = 2
    }
    missing_feed = {
      display   = "InvestSphere DQ - Missing latest price feed"
      check     = "assets_missing_latest_price"
      op        = "GREATER_THAN"
      threshold = 0
    }
    freshness = {
      display   = "InvestSphere DQ - Transaction feed stale (> 1 day)"
      check     = "transaction_freshness_minutes"
      op        = "GREATER_THAN"
      threshold = 1440
    }
    expectation_failures = {
      display   = "InvestSphere DQ - Lakeflow expectation failures"
      check     = "expectation_failed_records"
      op        = "GREATER_THAN"
      threshold = 0
    }
  }
}

# One scheduled alert per metric, using the modern databricks_alert_v2 resource.
# alert_v2 folds the saved query + condition + schedule into ONE resource (the older
# databricks_alert + databricks_query split does not support an inline schedule).
# Re-evaluates every 30 minutes and notifies the on-call destination on breach.
#
# Note: evaluation/schedule/source/threshold/notification are typed ATTRIBUTES (objects),
# so they use `= { ... }` assignment, NOT block `{ ... }` syntax.
resource "databricks_alert_v2" "dq" {
  for_each     = local.dq_alerts
  display_name = each.value.display
  warehouse_id = var.warehouse_id
  query_text   = <<-SQL
    SELECT metric_value
    FROM investsphere.governance.dq_results
    WHERE check_name = '${each.value.check}'
    ORDER BY check_timestamp DESC LIMIT 1
  SQL

  evaluation = {
    comparison_operator = each.value.op # e.g. GREATER_THAN
    source = {
      name        = "metric_value"
      aggregation = "FIRST"
    }
    threshold = {
      value = {
        double_value = each.value.threshold
      }
    }
    notification = {
      notify_on_ok = true
      subscriptions = [{
        destination_id = databricks_notification_destination.dq_oncall.id
      }]
    }
  }

  schedule = {
    quartz_cron_schedule = "0 */30 * * * ?"
    timezone_id          = "Asia/Dubai"
    pause_status         = "UNPAUSED"
  }
}
