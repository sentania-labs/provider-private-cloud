# External connection (spec 3.2): direct resources, no module. IP space +
# provider gateway on the T0, joined by one explicit reference. Provider
# gateways are region-scoped but shareable across orgs; this one instance
# serves all orgs in var.orgs.
#
# external_cidr = 172.17.0.0/16 (envs/lab.tfvars): live vCenter evidence
# (wld01-cl01-supervisor > Configure > Network > Workload Networks) shows a
# single External IP Block named "vcf-lab-region01-default-ip-space", whose
# name is derived from this repo's region name. This IS the region's own
# external IP space, not a foreign allocation to avoid colliding with. It
# survived the VCFA teardown and still exists on the supervisor under that
# name. 172.18.0.0/16, seen in older docs, was a reservation for a second
# supervisor (wld01-cl02-supervisor) that was never built; that value is
# stale and unused. See README's "External CIDR" section for the pre-apply
# check this leaves open: whether creating vcfa_region + vcfa_ip_space
# against a CIDR that already has a surviving block on the supervisor
# collides, or is adopted/expected.

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
