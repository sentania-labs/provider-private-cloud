provider "vcfa" {
  url                  = var.vcfa_url
  api_token            = var.vcfa_api_token
  org                  = "System"
  allow_unverified_ssl = var.insecure
  auth_type            = "api_token"
}

# Mints/rotates per-org OIDC client secrets via the VCF Operations IAM API
# (fleet-management/iam/ssorealms). This is a separate control plane from
# VCFA itself, see orgs.tf and README.md's "state is credential-bearing"
# section for why the client_secret round-trips through here instead of
# being carried by hand.
#
# var.ops_api_token is the standard Bearer token produced by the vIDB token
# exchange flow (see README's "Ops API auth" section), presented to
# suite-api as "Bearer <token>": confirmed working in the lab. The old
# "OpsToken <token>" scheme was specific to the suite-api username/password
# acquire flow, which is retired since it rejects the SSO-backed CI account.
provider "restapi" {
  uri                   = var.ops_api_base_url
  write_returns_object  = true
  create_returns_object = true
  headers = {
    "Authorization" = "Bearer ${var.ops_api_token}"
    "Content-Type"  = "application/json"
  }
}
