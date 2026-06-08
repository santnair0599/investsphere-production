# Unity Catalog module

Creates the InvestSphere Unity Catalog hierarchy:

- **Catalog**: `investsphere` (configurable)
- **Schemas**: `bronze`, `silver`, `gold`, `governance`, `ai`, `features`, `ml`
- **Volumes** (MANAGED):
  - `bronze.raw` — Auto Loader landing zone
  - `bronze._checkpoints` — Auto Loader streaming checkpoints **(required)**
  - `bronze._schemas` — Auto Loader inferred-schema state **(required)**
  - `ai.documents` — AI/RAG source documents

> The `_checkpoints` and `_schemas` volumes are **required** by Auto Loader
> (`cloudFiles`). Without them the stream can fail silently.

## Requirements

- A **Unity-Catalog-enabled** workspace.
- A principal with **metastore-admin / account-level** privileges (catalog and
  schema creation are metastore operations).
- The `databricks` provider configured in the **root** module (this module does
  not configure it).

## Usage (from the root module)

```hcl
# providers.tf in the root already configures the databricks provider.

module "unity_catalog" {
  source = "./modules/unity_catalog"

  catalog_name    = "investsphere"
  catalog_comment = "InvestSphere capital-markets lakehouse."

  # Optional:
  # storage_root = "abfss://uc@yourstorage.dfs.core.windows.net/investsphere"
  # owner        = "data-platform-admins"
  # schemas      = ["bronze", "silver", "gold", "governance", "ai", "features", "ml"]
}

output "uc_volume_paths" {
  value = module.unity_catalog.volume_paths
}
```

## Outputs

| Output | Description |
|--------|-------------|
| `catalog_name` | Name of the created catalog |
| `schema_names` | List of created schema names |
| `volume_paths` | Map of logical name → `/Volumes/...` path |
