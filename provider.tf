provider "vcfa" {
  url                  = var.vcfa_url
  user                 = var.vcfa_admin_username
  password             = var.vcfa_admin_password
  org                  = "System"
  allow_unverified_ssl = var.insecure
  auth_type            = "integrated"
}

# Mints/rotates per-org OIDC client secrets via the VCF Operations IAM API
# (fleet-management/iam/ssorealms). This is a separate control plane from
# VCFA itself, see orgs.tf and README.md's "state is credential-bearing"
# section for why the client_secret round-trips through here instead of
# being carried by hand.
provider "restapi" {
  uri                   = var.ops_api_base_url
  write_returns_object  = true
  create_returns_object = true
  headers = {
    "Authorization" = "Bearer ${var.ops_api_token}"
    "Content-Type"  = "application/json"
  }
}
