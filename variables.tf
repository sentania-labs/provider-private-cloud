########################################
# VCFA provider connection
########################################

variable "vcfa_url" {
  type        = string
  description = "URL of the VCF-A (Aria Automation) endpoint."
}

/**
 * vcfa_admin_username / vcfa_admin_password
 * Username/password auth is the verified-working path for this repo (System org
 * admin, e.g. admin@system), not the api_token flow: the token in the pre-teardown
 * lab-config.json is stale. Supplied via TF_VAR_*, never defaulted or committed.
 */
variable "vcfa_admin_username" {
  type        = string
  description = "System-org admin username for the vcfa provider (e.g. admin@system)."
}

variable "vcfa_admin_password" {
  type        = string
  description = "Password for var.vcfa_admin_username. Supply via TF_VAR_vcfa_admin_password."
  sensitive   = true
}

variable "insecure" {
  type        = bool
  description = "Whether to skip SSL certificate verification when connecting to the VCF-A API (typically true for lab environments)."
  default     = true
}

########################################
# VCF Operations IAM API (OIDC client minting/rotation, see orgs.tf)
########################################

/**
 * ops_api_base_url / ops_api_token
 * Connection to the VCF Operations fleet-management IAM API, used only to mint and
 * rotate per-org OAuth app client secrets (ruling: vcfa_org_oidc's client_secret is
 * not recoverable once set, so it is minted here rather than carried by hand).
 * Both are sensitive and supplied via TF_VAR_*, never defaulted or committed: the
 * base URL is treated as sensitive alongside the token because it identifies the
 * specific Ops instance being administered.
 */
variable "ops_api_base_url" {
  type        = string
  description = "Base URL of the VCF Operations API (e.g. https://<ops-fqdn>). Supply via TF_VAR_ops_api_base_url."
  sensitive   = true
}

variable "ops_api_token" {
  type        = string
  description = "Bearer token for the VCF Operations fleet-management IAM API. Supply via TF_VAR_ops_api_token."
  sensitive   = true
}

variable "sso_realm_id" {
  type        = string
  description = "SSO realm id under which per-org OAuth apps are created (fleet-management/iam/ssorealms/{ssoRealmId}). Supplied later, during the lab-admin phase: no default."
}

########################################
# Region topology (spec 3.1)
########################################

variable "region_name" {
  type        = string
  description = "Name of the VCFA region to create."
  default     = "vcf-lab-region01"
}

variable "vcenter_name" {
  type        = string
  description = "Name of the registered vCenter backing the region."
}

variable "nsx_manager_name" {
  type        = string
  description = "Name of the registered NSX manager backing the region."
}

variable "supervisor_name" {
  type        = string
  description = "Name of the Supervisor to bind to the region."
}

variable "storage_policy_names" {
  type        = list(string)
  description = "Storage policy names to attach to the region."
  default     = ["iscsi-default-policy"]
}

########################################
# External connectivity (spec 3.2) -- BLOCKING, see README
########################################

variable "tier0_gateway_name" {
  type        = string
  description = "Name of the existing Tier-0 gateway the provider gateway attaches to."
}

/**
 * external_cidr
 * BLOCKING open decision (spec section 3.2 / section 9 item 1): needs a router-side
 * answer confirming a range that is routed to the T0 and does not collide with
 * 172.17.0.0/16 (in use by the supervisor's default connectivity profile). No default
 * on purpose, so an apply without an explicit answer fails closed instead of silently
 * reusing a stale or colliding block.
 */
variable "external_cidr" {
  type        = string
  description = "CIDR block for the region's external IP space. BLOCKING: must be confirmed against the T0's BGP neighbours/advertised prefixes before use, see README."
}

########################################
# Provider content library (spec 3.3)
########################################

variable "content_libraries" {
  type = map(object({
    name                = string
    storage_class_names = list(string)
    items = optional(list(object({
      name       = string
      file_paths = list(string)
    })), [])
  }))
  description = "Provider content libraries and their items. storage_class_names are resolved to storage class ids in the region (vcfa_content_library requires storage_class_ids, not a region reference)."
  default     = {}
}

########################################
# Orgs (spec 3.4) -- OIDC client_id/client_secret are minted via orgs.tf, not carried here
########################################

variable "orgs" {
  type = map(object({
    name         = string
    display_name = string
    description  = optional(string, "")
    is_enabled   = optional(bool, true)
    local_admin = optional(object({
      username = string
      role_ids = set(string)
    }))
    oidc = optional(object({
      ui_button_label        = optional(string, "VCF SSO")
      max_clock_skew_seconds = optional(number, 60)
      prefer_id_token        = optional(bool, false)
      scopes                 = optional(set(string), ["openid", "profile", "email", "group"])
      groups = optional(list(object({
        name = string # must be lowercase, matched case-sensitively at login
        role = string
      })), [])
      # Bump to force a fresh OAuth-app client secret via the Ops IAM rotate
      # endpoint (orgs.tf). Leaving it unchanged across applies must produce
      # a clean, empty plan for the rotate resource: rotation is on-demand,
      # never on every apply.
      rotation_id = string
    }))
    # Set to enable org networking for this org (the module that mints the
    # per-org default VPC). log_name is required by the module directly (max
    # 8 chars, must be unique in the backing network provider's logs) so it
    # lives here rather than being derived from the org name/key.
    networking = optional(object({
      log_name = string
    }))
    region_quota = optional(object({
      zone_name              = string
      cpu_limit_mhz          = number
      cpu_reservation_mhz    = number
      memory_limit_mib       = number
      memory_reservation_mib = number
      vm_classes             = list(string)
      storage_classes = map(object({
        limit_mib = number
      }))
    }))
  }))
  description = "Per-org topology: org identity, OIDC federation shape, org-networking membership, and region quota. OIDC client_id/client_secret are NOT fields here: client_id/secret are minted per org by the restapi resources in orgs.tf, never supplied as a manual variable."
}

/**
 * local_admin_passwords
 * Keyed the same as var.orgs, only for orgs whose local_admin is set. TF_VAR_ only,
 * never in a checked-in tfvars file.
 */
variable "local_admin_passwords" {
  type        = map(string)
  description = "Password for each org's local_admin user, keyed by the same key as var.orgs. Supply via TF_VAR_local_admin_passwords."
  sensitive   = true
  default     = {}
}
