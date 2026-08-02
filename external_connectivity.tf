# External connection (spec 3.2): direct resources, no module. IP space +
# provider gateway on the T0, joined by one explicit reference. Provider
# gateways are region-scoped but shareable across orgs; this one instance
# serves all orgs in var.orgs.
#
# external_cidr = 172.18.0.0/16 (envs/lab.tfvars): a fresh, unused CIDR,
# confirmed live and free in NSX (a full ip-blocks listing and a Policy API
# search both show 5 live blocks total, none matching 172.18.0.0/16 or
# anything close to it). This is an additive second entry on the Default
# VPC Connectivity Profile: the profile's external_ip_blocks field is an
# array (maxItems: 5, live schema confirmed), and only 1 of 5 slots is
# currently used, by 172.17.0.0/16.
#
# 172.17.0.0/16 is a default block from initial vCenter+NSX onboarding. It
# stays untouched and unmanaged by this repo, permanently: no import, no
# name reuse, no quota comparison, zero contact with it in any form. It was
# also renamed live (from "vcf-lab-region01-default-ip-space" to
# "vcf-lab-wld01-default-ip-space") and had its vcfa/tenant-manager NSX tag
# stripped during an unrelated Supervisor decommission/rebuild cycle; that
# object and both of its names are permanently out of scope here.
#
# This resource CREATES a brand-new IP space on 172.18.0.0/16, it does not
# adopt or import anything.

data "vcfa_tier0_gateway" "t0" {
  name      = var.tier0_gateway_name
  region_id = vcfa_region.region01.id
}

resource "vcfa_ip_space" "ext" {
  name      = "${var.region_name}-ext-ip-space"
  region_id = vcfa_region.region01.id

  cidr_blocks {
    name = "block1"
    cidr = var.external_cidr
  }

  # Operator-chosen defaults for a brand-new IP space: there is no live
  # block to match against here (see comment above, this is a fresh
  # create, not an adopt), so these are simply the values Scott wants a
  # new external IP space to start with.
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
