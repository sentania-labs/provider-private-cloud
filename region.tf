# Region creation (spec 3.1). vCenter/NSX manager/Supervisor are data sources on
# purpose: Terraform must never propose changes to platform registration, only
# read the ids it needs.

data "vcfa_vcenter" "wld01" {
  name = var.vcenter_name
}

data "vcfa_nsx_manager" "wld01" {
  name = var.nsx_manager_name
}

data "vcfa_supervisor" "wld01" {
  name       = var.supervisor_name
  vcenter_id = data.vcfa_vcenter.wld01.id
}

# supervisor_ids is a list: adding a supervisor to the WLD later is an in-place
# update here, which is why the region is managed in terraform at all rather
# than left as a data source.
#
# Aftermath to expect, not a bug: creating the region re-registers the
# supervisor, which triggers the "Supervisor is shared with other TM
# instances" banner and requires a JWTAuthenticator applied by hand on the
# Supervisor control plane (out of scope for this repo, see spec 3.8).
resource "vcfa_region" "region01" {
  name                 = var.region_name
  nsx_manager_id       = data.vcfa_nsx_manager.wld01.id
  supervisor_ids       = [data.vcfa_supervisor.wld01.id]
  storage_policy_names = var.storage_policy_names
}
