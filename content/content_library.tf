# Provider content library (spec 3.3): its own apply stage, split out of the
# platform root (region/orgs/networking/quota). See README's "Content is its
# own stage" section for why: content must not gate identity or networking.
#
# vcfa_content_library requires org_id (the System org, for a PROVIDER-type
# library) and storage_class_ids, not a region reference: the spec's
# original sketch used region_ids, which does not match the provider's
# real v1.2 schema (confirmed against the published docs).
#
# Org and region are consumed here as data sources, by name, not via
# terraform_remote_state against the platform root's state: this stage
# reads nothing out of the platform stage's state file, only live VCFA
# objects the platform stage already created.

data "vcfa_org" "system" {
  name = "System"
}

data "vcfa_region" "region01" {
  name = var.region_name
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

  region_id = data.vcfa_region.region01.id
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

# Only meaningful for non-subscribed libraries: var.content_libraries'
# provider_library entry is subscribed (see envs/lab.tfvars) and its
# items list stays empty, since a subscribed library's content comes
# from the publisher, not manually specified items.
resource "vcfa_content_library_item" "this" {
  for_each = local.content_library_items

  content_library_id = vcfa_content_library.this[each.value.cl_key].id
  name               = each.value.item.name
  file_paths         = each.value.item.file_paths
}

# Adopts the library that was created live in run 30784618486 (platform
# CI run) but never entered platform Terraform state: the create call's
# VCFA sync task took 60+ minutes, the provider session expired mid-wait,
# and the create errored on a 401 retrieving task status before Terraform
# ever recorded a successful creation. Scott confirmed in the VCFA portal
# that "vcf-lab-content-library" exists server-side under org System with
# the subscription config below. See README's "Session-expiry note" and
# "Adopting the live library" sections.
#
# Import ID format confirmed against the vmware/terraform-provider-vcfa
# v1.2.0 docs (docs/resources/content_library.md, Import section): PROVIDER
# libraries import as "<org name>"."<library name>" with "." as the
# default separator (VCFA_IMPORT_SEPARATOR / provider import_separator to
# change it), which is a single string once the shell's adjacent-quote
# concatenation is resolved: "System.vcf-lab-content-library" below.
#
# Gated by var.adopt_content_library, not unconditional: an unconditional
# import block fails any future fresh rebuild of this stage (importing an
# object that doesn't exist yet errors the plan). The content CI job's
# "Probe for existing content library" step (see
# .github/workflows/configure-private-cloud.yml) answers this per run by
# querying VCFA for the library by name and supplying
# TF_VAR_adopt_content_library, so nobody hand-flips this in committed
# config. See README's "Adopting the live library" section.
import {
  for_each = var.adopt_content_library ? { adopt = 1 } : {}
  to       = vcfa_content_library.this["provider_library"]
  id       = "System.vcf-lab-content-library"
}
