# External connection (spec 3.2): direct resources, no module. IP space +
# provider gateway on the T0, joined by one explicit reference. Provider
# gateways are region-scoped but shareable across orgs; this one instance
# serves all orgs in var.orgs.
#
# BLOCKING: var.external_cidr has no default, see variables.tf and README.
# It must be confirmed against the T0's BGP neighbours/advertised prefixes
# before a first apply; it must not collide with 172.17.0.0/16, which the
# supervisor's default connectivity profile already uses.

data "vcfa_tier0_gateway" "t0" {
  name      = var.tier0_gateway_name
  region_id = vcfa_region.region01.id
}

resource "vcfa_ip_space" "ext" {
  name      = "${var.region_name}-ipspace01"
  region_id = vcfa_region.region01.id

  cidr_blocks {
    name = "block1"
    cidr = var.external_cidr
  }

  default_quota_max_subnet_size = 24
  default_quota_max_cidr_count  = -1
  default_quota_max_ip_count    = -1
}

# external_scope on vcfa_ip_space is deprecated in provider v1.2 (confirmed
# against the published docs, superseding the spec's original sketch which
# predates that deprecation): inbound_remote_networks on the provider
# gateway is the current way to declare the span of external reachability.
resource "vcfa_provider_gateway" "pgw" {
  name                    = "${var.region_name}-pgw"
  region_id               = vcfa_region.region01.id
  tier0_gateway_id        = data.vcfa_tier0_gateway.t0.id
  ip_space_ids            = [vcfa_ip_space.ext.id]
  inbound_remote_networks = ["0.0.0.0/0"]

  nat_config_enabled     = true
  nat_config_ip_space_id = vcfa_ip_space.ext.id
}
