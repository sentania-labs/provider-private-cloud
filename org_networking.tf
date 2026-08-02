# Org networking (spec 3.5): mints the per-org default VPC that
# SupervisorNamespaces later reference by vpc_name. Its absence is exactly
# why the pre-teardown lab listed zero VPCs, zero transit gateways, zero
# connectivity profiles, and namespaces couldn't be created.
#
# Ordering trap this module exists to hide: vcfa_org_regional_networking
# must chain off the vcfa_org_networking resource id, not the org id, or
# log_name is unset at apply (silent failure, not an error). Encapsulated
# once inside sentania-labs/org-networking/vcfa instead of re-derived here.

module "org_networking" {
  source   = "sentania-labs/org-networking/vcfa"
  version  = "~> 0.1.0"
  for_each = { for k, o in local.effective_orgs : k => o if o.networking != null }

  org_id              = module.orgs[each.key].id
  log_name            = each.value.networking.log_name
  region_id           = vcfa_region.region01.id
  provider_gateway_id = vcfa_provider_gateway.pgw.id
  name                = "${each.value.name}-networking"
}
