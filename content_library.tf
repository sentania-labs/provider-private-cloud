# Provider content library (spec 3.3): direct resources, no module. One
# resource plus a child item list hides nothing; uses the same
# flatten-into-a-map locals pattern all-apps-private-cloud uses for
# project_role_bindings.
#
# vcfa_content_library requires org_id (the System org, for a PROVIDER-type
# library) and storage_class_ids, not a region reference: the spec's
# original sketch used region_ids, which does not match the provider's
# real v1.2 schema (confirmed against the published docs), so this file
# diverges from that sketch deliberately.

data "vcfa_org" "system" {
  name = "System"
}

locals {
  content_library_storage_classes = {
    for i in flatten([
      for k, cl in var.content_libraries : [
        for sc in cl.storage_class_names : {
          key    = "${k}:${sc}"
          cl_key = k
          name   = sc
        }
      ]
    ]) : i.key => i
  }
}

data "vcfa_storage_class" "this" {
  for_each = local.content_library_storage_classes

  region_id = vcfa_region.region01.id
  name      = each.value.name
}

resource "vcfa_content_library" "this" {
  for_each = var.content_libraries

  name   = each.value.name
  org_id = data.vcfa_org.system.id

  storage_class_ids = [
    for k, v in local.content_library_storage_classes : data.vcfa_storage_class.this[k].id
    if v.cl_key == each.key
  ]

  dynamic "subscription_config" {
    for_each = each.value.subscription_config != null ? [each.value.subscription_config] : []
    content {
      subscription_url = subscription_config.value.subscription_url
      password         = subscription_config.value.password
    }
  }
}

locals {
  content_library_items = {
    for i in flatten([
      for k, cl in var.content_libraries : [
        for item in cl.items : {
          key    = "${k}:${item.name}"
          cl_key = k
          item   = item
        }
      ]
    ]) : i.key => i
  }
}

resource "vcfa_content_library_item" "this" {
  for_each = local.content_library_items

  content_library_id = vcfa_content_library.this[each.value.cl_key].id
  name               = each.value.item.name
  file_paths         = each.value.item.file_paths
}
