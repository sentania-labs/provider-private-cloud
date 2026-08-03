provider "vcfa" {
  url                  = var.vcfa_url
  api_token            = var.vcfa_api_token
  org                  = "System"
  allow_unverified_ssl = var.insecure
  auth_type            = "api_token"
}
