# Outputs exposed to the caller (root module).

output "catalog_name" {
  description = "Name of the created catalog."
  value       = databricks_catalog.investsphere.name
}

output "schema_names" {
  description = "Names of all created schemas."
  value       = [for s in databricks_schema.layers : s.name]
}

# Fully-qualified /Volumes paths -- the form code uses to read/write files,
# e.g. /Volumes/investsphere/bronze/raw
output "volume_paths" {
  description = "Map of logical volume name -> /Volumes path."
  value = {
    bronze_raw         = "/Volumes/${databricks_catalog.investsphere.name}/bronze/raw"
    bronze_checkpoints = "/Volumes/${databricks_catalog.investsphere.name}/bronze/_checkpoints"
    bronze_schemas     = "/Volumes/${databricks_catalog.investsphere.name}/bronze/_schemas"
    ai_documents       = "/Volumes/${databricks_catalog.investsphere.name}/ai/documents"
  }
}
