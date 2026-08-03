########################################
# VCFA provider connection
########################################

variable "vcfa_url" {
  type        = string
  description = "URL of the VCF-A (Aria Automation) endpoint."
}

variable "vcfa_api_token" {
  type        = string
  description = "API token for the vcfa provider, org System (VCF Admin service account). Supply via TF_VAR_vcfa_api_token. Same token the platform root uses: content library operations are org System, PROVIDER-scoped, same as the platform root's auth."
  sensitive   = true
}

variable "insecure" {
  type        = bool
  description = "Whether to skip SSL certificate verification when connecting to the VCF-A API (typically true for lab environments)."
  default     = true
}

########################################
# Region lookup (content library storage classes are region-scoped)
########################################

variable "region_name" {
  type        = string
  description = "Name of the VCFA region the content library's storage classes are resolved against. Must match the platform root's region_name (region.tf there); looked up here via a data source, not created, since region creation is a platform-stage concern."
  default     = "vcf-lab-region01"
}

########################################
# Provider content library (spec 3.3)
########################################

variable "adopt_content_library" {
  type        = bool
  description = "Whether to import the existing live content library instead of creating it fresh. Answered per-run: the content CI job's 'Probe for existing content library' step queries VCFA and supplies this via TF_VAR_adopt_content_library, true if the library already exists server-side, false if it doesn't. A local/manual run must supply this explicitly (TF_VAR_adopt_content_library=true or false) after checking the VCFA portal for whether the library already exists; there is no default that assumes an answer."
  # default = false, not omitted: a bare `terraform validate` or a local run
  # with nothing supplied should default to the no-accidental-import
  # posture (create), never to importing an object that may not exist.
  default = false
}

variable "content_libraries" {
  type = map(object({
    name                = string
    storage_class_names = list(string)
    items = optional(list(object({
      name       = string
      file_paths = list(string)
    })), [])
    subscription_config = optional(object({
      subscription_url = string
      password         = optional(string)
    }))
  }))
  description = "Provider content libraries and their items. storage_class_names are resolved to storage class ids in the region (vcfa_content_library requires storage_class_ids, not a region reference). subscription_config turns a library into a subscribed library pulling content from a publisher; subscription_url forces replacement if changed after creation (provider ForceNew), and items should stay empty for a subscribed library since content comes from the publisher."
  default     = {}
}
