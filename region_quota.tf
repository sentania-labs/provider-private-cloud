# Region quota (spec 3.6, ruling 1): NOT a module. The three lookups it
# needs are region-scoped and identical across orgs, so they run once here
# and vcfa_org_region_quota is for_each'd directly over the orgs that want
# one. A "region-quota" module (local or registry) would just be re-running
# the same three data lookups per instance for no benefit -- there is no
# trap here to hide, only tedium, and the tedium is gone once the lookups
# are hoisted to root.
#
# Teardown lesson that makes this file's existence non-optional: the region
# quota is the vcf_virtual_datacenter row. An org cannot be deleted while it
# owns one -- the API returns 202 and then the task fails with a raw
# Postgres FK error. Quota-before-org on the way out, org-before-quota on
# the way in (this file already depends on module.orgs, so create order is
# correct by construction; destroy order is the operator's job to respect).

locals {
  region_quota_orgs = { for k, o in var.orgs : k => o if o.region_quota != null }

  region_quota_vm_classes = {
    for i in flatten([
      for k, o in local.region_quota_orgs : [
        for vc in o.region_quota.vm_classes : {
          key      = "${k}:${vc}"
          org_key  = k
          vm_class = vc
        }
      ]
    ]) : i.key => i
  }

  region_quota_storage_policies = {
    for i in flatten([
      for k, o in local.region_quota_orgs : [
        for sp, cfg in o.region_quota.storage_classes : {
          key           = "${k}:${sp}"
          org_key       = k
          storage_class = sp
          limit_mib     = cfg.limit_mib
        }
      ]
    ]) : i.key => i
  }
}

data "vcfa_region_zone" "this" {
  for_each = { for k, o in local.region_quota_orgs : k => o.region_quota.zone_name }

  region_id = vcfa_region.region01.id
  name      = each.value
}

data "vcfa_region_vm_class" "this" {
  for_each = local.region_quota_vm_classes

  region_id = vcfa_region.region01.id
  name      = each.value.vm_class
}

data "vcfa_region_storage_policy" "this" {
  for_each = local.region_quota_storage_policies

  region_id = vcfa_region.region01.id
  name      = each.value.storage_class
}

resource "vcfa_org_region_quota" "this" {
  for_each = local.region_quota_orgs

  org_id         = module.orgs[each.key].id
  region_id      = vcfa_region.region01.id
  supervisor_ids = [data.vcfa_supervisor.wld01.id]

  zone_resource_allocations {
    region_zone_id         = data.vcfa_region_zone.this[each.key].id
    cpu_limit_mhz          = each.value.region_quota.cpu_limit_mhz
    cpu_reservation_mhz    = each.value.region_quota.cpu_reservation_mhz
    memory_limit_mib       = each.value.region_quota.memory_limit_mib
    memory_reservation_mib = each.value.region_quota.memory_reservation_mib
  }

  region_vm_class_ids = [
    for k, v in local.region_quota_vm_classes : data.vcfa_region_vm_class.this[k].id
    if v.org_key == each.key
  ]

  dynamic "region_storage_policy" {
    for_each = {
      for k, v in local.region_quota_storage_policies : k => v
      if v.org_key == each.key
    }
    content {
      region_storage_policy_id = data.vcfa_region_storage_policy.this[region_storage_policy.key].id
      storage_limit_mib        = region_storage_policy.value.limit_mib
    }
  }
}
