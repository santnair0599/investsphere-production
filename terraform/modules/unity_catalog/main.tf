# Unity Catalog module for InvestSphere
# ==============================================================================
# Creates the full Unity Catalog object hierarchy:
#
#   catalog  : investsphere
#   schemas  : bronze, silver, gold, governance, ai, features, ml
#   volumes  : bronze.raw, bronze._checkpoints, bronze._schemas, ai.documents
#
# The databricks provider is configured by the ROOT module (the caller); this
# module only consumes it. Run against a UC-enabled workspace with a principal
# that has metastore-admin / account privileges.
# ==============================================================================

terraform {
  required_providers {
    databricks = {
      source = "databricks/databricks"
    }
  }
}

# ------------------------------------------------------------------------------
# Catalog -- the top-level container for all InvestSphere data.
# ------------------------------------------------------------------------------
resource "databricks_catalog" "investsphere" {
  name    = var.catalog_name
  comment = var.catalog_comment

  # storage_root is optional. If set, managed tables/volumes in this catalog
  # land under this external-location path; otherwise they use the metastore
  # default. Leave empty to inherit the metastore default.
  storage_root = var.storage_root != "" ? var.storage_root : null

  # Optional owner (a user, group, or service principal). Leave empty to keep
  # the creating principal as owner.
  owner = var.owner != "" ? var.owner : null

  # Keep the catalog even if Terraform is asked to destroy it while it still
  # holds objects. Flip to true only in throwaway/dev environments.
  force_destroy = false
}

# ------------------------------------------------------------------------------
# Schemas -- one per medallion layer + support areas.
# for_each over a set so adding/removing a schema is a one-line change to
# var.schemas.
# ------------------------------------------------------------------------------
resource "databricks_schema" "layers" {
  for_each = toset(var.schemas)

  catalog_name = databricks_catalog.investsphere.name
  name         = each.value
  comment      = "InvestSphere ${each.value} layer"

  force_destroy = false
}

# ------------------------------------------------------------------------------
# Volumes -- MANAGED volumes for non-tabular files.
#
# IMPORTANT (Auto Loader): the _checkpoints and _schemas volumes are REQUIRED.
# Auto Loader (cloudFiles) writes its streaming checkpoint and inferred-schema
# state to these volume paths. If they do not exist, Auto Loader can FAIL
# SILENTLY -- the stream appears to run but persists nothing. Always create
# these alongside the raw landing volume.
# ------------------------------------------------------------------------------

# Raw landing zone -- where source files arrive and Auto Loader reads from.
resource "databricks_volume" "bronze_raw" {
  name         = "raw"
  catalog_name = databricks_catalog.investsphere.name
  schema_name  = databricks_schema.layers["bronze"].name
  volume_type  = "MANAGED"
  comment      = "Bronze raw landing zone (Auto Loader source files)"
}

# Auto Loader streaming checkpoints. REQUIRED -- see note above.
resource "databricks_volume" "bronze_checkpoints" {
  name         = "_checkpoints"
  catalog_name = databricks_catalog.investsphere.name
  schema_name  = databricks_schema.layers["bronze"].name
  volume_type  = "MANAGED"
  comment      = "Auto Loader streaming checkpoints (REQUIRED by cloudFiles)"
}

# Auto Loader inferred-schema storage. REQUIRED -- see note above.
resource "databricks_volume" "bronze_schemas" {
  name         = "_schemas"
  catalog_name = databricks_catalog.investsphere.name
  schema_name  = databricks_schema.layers["bronze"].name
  volume_type  = "MANAGED"
  comment      = "Auto Loader inferred-schema location (REQUIRED by cloudFiles)"
}

# Document store for the AI / RAG layer (source docs for chunking + embedding).
resource "databricks_volume" "ai_documents" {
  name         = "documents"
  catalog_name = databricks_catalog.investsphere.name
  schema_name  = databricks_schema.layers["ai"].name
  volume_type  = "MANAGED"
  comment      = "AI/RAG source documents"
}
