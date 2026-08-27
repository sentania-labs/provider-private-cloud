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
  region_quota_orgs = { for k, o in local.effective_orgs : k => o if o.region_quota != null }

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

# CORRECTED 2026-08-27. This comment previously read that neither the
# org/vcfa module nor vcfa_org exposes an org classification argument, and
# concluded the VCF 9.1 restriction on region quotas for VM-Apps orgs was
# therefore not applicable here. The first half was wrong:
# vcfa_org.is_classic_tenant has existed since provider v1.0.0 (verified in
# resource_vcfa_org.go at v1.0.0/v1.1.0/v1.2.0). Only the module lacked a
# passthrough, which it no longer does. vcf-lab-vm-apps was created
# non-classic as a result of that gap, not by choice.
#
# So the restriction IS live once an org here sets is_classic_tenant = true.
# Confirm what a classic tenant may hold in a region quota before the first
# apply that creates one: VM classes and storage policies are expected to
# behave, but a classic tenant has no Supervisor namespaces, so anything in
# this file that assumes Supervisor backing needs re-checking against a real
# plan rather than assumed to carry over.
# Forces the quota to be REPLACED, not updated in place, whenever its org is
# replaced. Without this the teardown deadlocks, and it did on 2026-08-27:
#
#   vcfa_org_region_quota.this["vm_apps"] will be updated in-place
#   ...
#   Error: error deleting Organization: [409:INVALID_STATE] You must delete
#   this organization's Region Quotas before you can delete the organization.
#
# The dependency edge (org_id below references module.orgs[key].id) is real,
# but it only orders a destroy that Terraform actually plans. `org_id` is not
# ForceNew on this resource, so a replaced org produced an in-place quota
# update, meaning there was NO quota destroy to sequence before the org
# delete. Terraform deleted the org while its quota still existed and VCFA
# refused with a 409.
#
# terraform_data mirrors the org id, so it only shows a diff when the org is
# actually replaced; replace_triggered_by then turns the quota's in-place
# update into a destroy-and-create. Because the quota depends on the org, the
# destroy is ordered BEFORE the org's own destroy, which is the ordering the
# note at the top of this file describes. Same pattern as
# terraform_data.oauth_app_rotation_trigger in orgs.tf.
resource "terraform_data" "org_replace_trigger" {
  for_each = local.region_quota_orgs

  # triggers_replace, NOT input. This is the whole point of the resource and
  # it was wrong on the first attempt: with `input`, a changed org id updates
  # terraform_data IN PLACE, and replace_triggered_by referencing the whole
  # resource only fires when that resource is REPLACED. The plan on run
  # 33098229616 proved it, still showing
  #   vcfa_org_region_quota.this["vm_apps"] will be updated in-place
  # against an org that "must be replaced". triggers_replace makes the
  # terraform_data itself get replaced when the org id changes, which is what
  # replace_triggered_by is watching for.
  triggers_replace = module.orgs[each.key].id
}

resource "vcfa_org_region_quota" "this" {
  for_each = local.region_quota_orgs

  lifecycle {
    replace_triggered_by = [terraform_data.org_replace_trigger[each.key]]
  }

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
