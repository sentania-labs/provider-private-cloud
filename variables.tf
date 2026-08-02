########################################
# VCFA provider connection
########################################

variable "vcfa_url" {
  type        = string
  description = "URL of the VCF-A (Aria Automation) endpoint."
}

/**
 * vcfa_api_token
 * VCF Admin service-account API token, issued from the provider portal, scoped to
 * org "System" (matches the api_token auth pattern used by the sibling repos'
 * vcfa provider blocks). Supplied via TF_VAR_vcfa_api_token, never defaulted or
 * committed. The earlier username/password path (admin@system) is retired: the
 * token in the pre-teardown lab-config.json was stale, this is a freshly issued one.
 */
variable "vcfa_api_token" {
  type        = string
  description = "API token for the vcfa provider, org System (VCF Admin service account). Supply via TF_VAR_vcfa_api_token."
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

/**
 * ops_api_token
 * Short-lived Ops API token, acquired at CI runtime from VCF_LAB_OPS_USER /
 * VCF_LAB_OPS_PASSWORD via a login round-trip the restapi provider cannot do
 * itself (see .github/workflows/configure-private-cloud.yml's acquire step and
 * README's "Ops API auth" section). Sent as "OpsToken <token>", not "Bearer".
 */
variable "ops_api_token" {
  type        = string
  description = "Ops API token for the VCF Operations fleet-management IAM API, sent as an OpsToken header. Supply via TF_VAR_ops_api_token (acquired at CI runtime, not stored)."
  sensitive   = true
}

/**
 * sso_realm_id
 * Identifier, not a secret: supplied by envs/*.tfvars (ruling: a working system
 * ships with reasonable defaults, no hand-population via TF_VAR required to run).
 * See envs/lab.tfvars for the lab's realm id and its provenance.
 */
variable "sso_realm_id" {
  type        = string
  description = "SSO realm id under which per-org OAuth apps are created (fleet-management/iam/ssorealms/{ssoRealmId}). Set in envs/*.tfvars, not TF_VAR."
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
# External connectivity (spec 3.2)
########################################

variable "tier0_gateway_name" {
  type        = string
  description = "Name of the existing Tier-0 gateway the provider gateway attaches to."
}

/**
 * external_cidr
 * Resolved: 172.17.0.0/16, the region's own surviving External IP Block (see
 * external_connectivity.tf and README's "External CIDR" section). Set in
 * envs/lab.tfvars, no default here since it is env-specific topology.
 */
variable "external_cidr" {
  type        = string
  description = "CIDR block for the region's external IP space. See README's External CIDR section for the pre-apply collision check against the surviving supervisor-side block."
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

/**
 * oidc_wellknown_endpoint
 * Well-known OIDC discovery URL for the vIDB realm, shared by every org's OIDC
 * federation. Confirmed live: resolves to
 * https://vcf-lab-idb.int.sentania.net/acs/t/CUSTOMER/.well-known/openid-configuration
 * Kept as a plain committed value (not a data-source lookup): the restapi
 * provider's restapi_object data source is built for list-search responses
 * (search_key/search_value/results_key), and this endpoint returns a single
 * object, not an array -- that shape mismatch isn't a reasonable fit, so a
 * static, live-validated value is used instead. See README.
 */
variable "oidc_wellknown_endpoint" {
  type        = string
  description = "Well-known OIDC discovery URL for the vIDB realm shared by all orgs' OIDC federation."
}

/**
 * oauth_app_redirect_url_pattern / oauth_app_logout_url_pattern
 * format() patterns applied as format(pattern, vcfa_url, org_name) when creating
 * each org's OAuth app (orgs.tf). Logout returns to the tenant sign-in page per
 * Scott's ruling. The logout pattern ("%s/tenant/%s") is VCFA's confirmed tenant
 * context URL convention. The redirect pattern's callback suffix
 * ("%s/tenant/%s/oauth/callback") is NOT confirmed against a live OIDC client
 * registration -- VCFA computes its own true redirect URI only after
 * vcfa_org_oidc federation is created (module.orgs[*].oidc_redirect_uri), which
 * happens after this OAuth app is created, so this is a best-effort guess.
 * Override via -var if the real value differs after a first apply.
 */
variable "oauth_app_redirect_url_pattern" {
  type        = string
  description = "format() pattern (vcfa_url, org_name) for each org's OAuth app redirect URL. Guessed VCFA OIDC callback path, see README."
  default     = "%s/tenant/%s/oauth/callback"
}

variable "oauth_app_logout_url_pattern" {
  type        = string
  description = "format() pattern (vcfa_url, org_name) for each org's OAuth app logout URL. Points at the tenant sign-in page."
  default     = "%s/tenant/%s"
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
