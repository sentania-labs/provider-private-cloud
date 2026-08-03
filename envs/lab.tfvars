# Lab environment. Non-secret topology only -- no credentials, no client
# secrets. See README.md for the full list of values that must be supplied
# separately via TF_VAR_* before a first apply.

vcfa_url = "https://vcf-lab-automation.int.sentania.net"
# vCenter-attested value (VirtualCenter.InstanceName, read live via govc).
# Not yet independently confirmed via a live VCFA data.vcfa_vcenter lookup,
# since no live VCFA session was obtainable at the time this was set;
# data.vcfa_vcenter in region.tf will re-confirm or correct this on the
# first real plan.
vcenter_name       = "vcf-lab-vcenter-wld01.int.sentania.net"
nsx_manager_name   = "vcf-lab-nsxmgr-wld01.int.sentania.net"
supervisor_name    = "wld01-cl01-supervisor"
tier0_gateway_name = "vcf-lab-wld01-gw"

region_name          = "vcf-lab-region01"
storage_policy_names = ["iscsi-default-policy"]

# Scott's phased apply plan: phase 1 was region + external IP space +
# provider gateway only, no orgs (that apply is done, on main). Merging
# this PR IS the phase-2 apply: it creates both orgs, their local admin
# users, OIDC federation, org networking, and region quotas, on Scott's
# explicit go given during this PR's development.
enable_orgs = true

# Realm "VCF Lab", the only realm on the appliance (Ops 9.1.0.0 build
# 25541561). An identifier, not a secret: committed here instead of
# hand-supplied via TF_VAR so a working system needs no hand-population to run.
sso_realm_id = "83369e94-bcad-4674-ba0d-e4b8b70730ee"

# Confirmed live against the appliance. A URL, not a secret.
oidc_wellknown_endpoint = "https://vcf-lab-idb.int.sentania.net/acs/t/CUSTOMER/.well-known/openid-configuration"


# Fresh, unused CIDR for a brand-new external IP space (see
# external_connectivity.tf and README's "External CIDR" section): confirmed
# live and free in NSX, zero contact with the untouched 172.17.0.0/16
# onboarding block.
external_cidr = "172.18.0.0/16"

# The provider content library now lives in its own apply stage
# (content/envs/lab.tfvars): content is not platform, and must not gate
# identity/networking. See README's "Content is its own stage" section.

orgs = {
  # PLACEHOLDER org CIDRs/zone below. There are TWO tenant orgs (all-apps,
  # vm-apps); System is not a tenant org this repo creates. Group names must
  # be lowercase (see variables.tf). Region quota is deliberately unlimited
  # (whole region, no ceiling): the provider docs don't document a true
  # unlimited sentinel for these fields, so 999999999 is used as a
  # large-but-finite proxy. See README's "Region quota" section.
  #
  # Group-to-role mapping: the org module's oidc.groups[].role is a single
  # string (confirmed against the module source), so a group that needs more
  # than one role gets one list entry per role, same group name repeated.
  # See README's "Group to role mappings" section for the role set chosen for
  # labadmins and why, and the one-time manual portal step this still needs
  # (the vcfa provider has no resource for the actual group-to-role binding).
  all_apps = {
    name         = "vcf-lab-all-apps"
    display_name = "VCF Lab All Apps"
    is_enabled   = true
    # Break-glass local admin: federated OIDC users authenticate through a
    # browser redirect and can't mint a vcfa_api_token non-interactively
    # from CI, so a local (non-federated) admin bootstraps tenant-repo
    # credentials headlessly. See README's tenant token minting section.
    #
    # Disabled 2026-08-03 pending a rights fix: vcfa_org_local_user creation
    # returns ACCESS_TO_RESOURCE_IS_FORBIDDEN for the CI service account.
    # Re-enable by restoring this block once the account's VCFA role covers
    # user management.
    local_admin = null
    oidc = {
      groups = [
        { name = "labadmins@int.sentania.net", role = "Organization Administrator" },
        { name = "labadmins@int.sentania.net", role = "Service Broker Admin" },
        { name = "labadmins@int.sentania.net", role = "Assembler" },
      ]
      rotation_id = "initial"
    }
    networking = {
      log_name = "allapps"
    }
    region_quota = {
      zone_name              = "domain-c10"
      cpu_limit_mhz          = 999999999
      cpu_reservation_mhz    = 0
      memory_limit_mib       = 999999999
      memory_reservation_mib = 0
      vm_classes             = ["best-effort-small", "best-effort-medium"]
      storage_classes = {
        "iscsi-default-policy" = { limit_mib = 999999999 }
      }
    }
  }

  vm_apps = {
    name         = "vcf-lab-vm-apps"
    display_name = "VCF Lab VM Apps"
    is_enabled   = true
    # Break-glass local admin, same rationale as all_apps above.
    #
    # Disabled 2026-08-03 pending a rights fix: vcfa_org_local_user creation
    # returns ACCESS_TO_RESOURCE_IS_FORBIDDEN for the CI service account.
    # Re-enable by restoring this block once the account's VCFA role covers
    # user management.
    local_admin = null
    oidc = {
      groups = [
        { name = "labadmins@int.sentania.net", role = "Organization Administrator" },
        { name = "labadmins@int.sentania.net", role = "Service Broker Admin" },
        { name = "labadmins@int.sentania.net", role = "Assembler" },
        { name = "self-service-user@int.sentania.net", role = "Organization Member" },
        { name = "self-service-user@int.sentania.net", role = "Service Broker User" },
        { name = "self-service-user@int.sentania.net", role = "approver" },
        { name = "self-service-admin@int.sentania.net", role = "Organization Member" },
        { name = "self-service-admin@int.sentania.net", role = "Service Broker User" },
        { name = "self-service-admin@int.sentania.net", role = "Assembler" },
      ]
      rotation_id = "initial"
    }
    networking = {
      log_name = "vmapps"
    }
    region_quota = {
      zone_name              = "domain-c10"
      cpu_limit_mhz          = 999999999
      cpu_reservation_mhz    = 0
      memory_limit_mib       = 999999999
      memory_reservation_mib = 0
      vm_classes             = ["best-effort-small", "best-effort-medium"]
      storage_classes = {
        "iscsi-default-policy" = { limit_mib = 999999999 }
      }
    }
  }
}
