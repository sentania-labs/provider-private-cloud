# Lab environment. Non-secret topology only -- no credentials, no client
# secrets, no realm id. See README.md for the full list of values that
# must be supplied separately via TF_VAR_* before a first apply.

vcfa_url           = "https://vcf-lab-automation.int.sentania.net"
vcenter_name       = "vcf-lab-vcenter-wld01" # PLACEHOLDER: confirm exact registered vCenter name
nsx_manager_name   = "vcf-lab-nsxmgr-wld01.int.sentania.net"
supervisor_name    = "wld01-cl01-supervisor"
tier0_gateway_name = "vcf-lab-wld01-gw"

region_name          = "vcf-lab-region01"
storage_policy_names = ["iscsi-default-policy"]

# external_cidr intentionally omitted: BLOCKING open decision, see README.
# Supply via -var or TF_VAR_external_cidr once the router-side answer lands.

content_libraries = {
  provider_library = {
    name                = "vcf-lab-content-library"
    storage_class_names = ["iscsi-default-policy"]
    items               = []
  }
}

orgs = {
  # PLACEHOLDER org names/CIDRs below. Adjust to match the actual three
  # orgs (system, all-apps, vm-apps) before a real apply; group names must
  # be lowercase (see variables.tf).
  all_apps = {
    name         = "vcf-lab-all-apps"
    display_name = "VCF Lab All Apps"
    is_enabled   = true
    oidc = {
      groups = [
        { name = "labadmins@int.sentania.net", role = "Organization Administrator" }
      ]
      rotation_id = "initial"
    }
    networking = {
      log_name = "allapps"
    }
    region_quota = {
      zone_name              = "domain-c10"
      cpu_limit_mhz          = 10000
      cpu_reservation_mhz    = 0
      memory_limit_mib       = 10000
      memory_reservation_mib = 0
      vm_classes             = ["best-effort-small", "best-effort-medium"]
      storage_classes = {
        "iscsi-default-policy" = { limit_mib = 102400 }
      }
    }
  }

  vm_apps = {
    name         = "vcf-lab-vm-apps"
    display_name = "VCF Lab VM Apps"
    is_enabled   = true
    oidc = {
      groups = [
        { name = "labadmins@int.sentania.net", role = "Organization Administrator" }
      ]
      rotation_id = "initial"
    }
    networking = {
      log_name = "vmapps"
    }
    region_quota = {
      zone_name              = "domain-c10"
      cpu_limit_mhz          = 10000
      cpu_reservation_mhz    = 0
      memory_limit_mib       = 10000
      memory_reservation_mib = 0
      vm_classes             = ["best-effort-small", "best-effort-medium"]
      storage_classes = {
        "iscsi-default-policy" = { limit_mib = 102400 }
      }
    }
  }
}
