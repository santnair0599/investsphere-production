# Input variables for the Unity Catalog module.
# The databricks provider itself is configured in the ROOT module; this module
# only consumes it, so no host/token variables live here.

variable "catalog_name" {
  type        = string
  description = "Name of the Unity Catalog catalog to create."
  default     = "investsphere"
}

variable "catalog_comment" {
  type        = string
  description = "Human-readable description attached to the catalog."
  default     = "InvestSphere capital-markets lakehouse (medallion + AI/ML)."
}

variable "storage_root" {
  type        = string
  description = <<-EOT
    Optional managed storage root (an external-location URL) for this catalog.
    Leave empty ("") to inherit the metastore default storage location.
  EOT
  default     = ""
}

variable "owner" {
  type        = string
  description = <<-EOT
    Optional owner principal (user, group, or service principal) for the
    catalog. Leave empty ("") to keep the creating principal as owner.
  EOT
  default     = ""
}

variable "schemas" {
  type        = list(string)
  description = "Schemas to create under the catalog."
  default     = ["bronze", "silver", "gold", "governance", "ai", "features", "ml"]
}
