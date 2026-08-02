# External connection (spec 3.2): direct resources, no module. IP space +
# provider gateway on the T0, joined by one explicit reference. Provider
# gateways are region-scoped but shareable across orgs; this one instance
# serves all orgs in var.orgs.
#
# external_cidr = 172.17.0.0/16 (envs/lab.tfvars): live vCenter evidence
# (wld01-cl01-supervisor > Configure > Network > Workload Networks) shows a
# single External IP Block named "vcf-lab-region01-default-ip-space", whose
# name is derived from this repo's region name. This IS the region's own
# external IP space, a teardown survivor, not a foreign allocation to avoid
# colliding with. 172.18.0.0/16, seen in older docs, was a reservation for a
# second supervisor (wld01-cl02-supervisor) that was never built; that value
# is stale and unused.
#
# Because the block already exists, this resource is ADOPTED via the
# import block below, not created fresh: a plain `create` against an
# already-registered block is the collision this config now avoids by
# construction, not just by an operator reading the plan carefully. See
# README's "External CIDR" section for the quota-field caveat this still
# leaves open (unverified against the live block's actual configured quota).

data "vcfa_tier0_gateway" "t0" {
  name      = var.tier0_gateway_name
  region_id = vcfa_region.region01.id
}

# Adopts the teardown-surviving External IP Block instead of creating a
# second one over the same CIDR. Import ID format confirmed against the
# published provider docs (docs/resources/ip_space.md, "Importing" section):
# "<region-name>.<ip-space-name>".
import {
  to = vcfa_ip_space.ext
  id = "${var.region_name}.${var.region_name}-default-ip-space"
}

resource "vcfa_ip_space" "ext" {
  name      = "${var.region_name}-default-ip-space"
  region_id = vcfa_region.region01.id

  cidr_blocks {
    name = "block1"
    cidr = var.external_cidr
  }

  # Best-effort defaults, not confirmed against the live block's actual
  # configured quota (no API access from this workspace to read it back).
  # A plan immediately after import that wants to change these three fields
  # means the live block is configured differently than guessed here: that
  # plan output is the correction, not this comment.
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
