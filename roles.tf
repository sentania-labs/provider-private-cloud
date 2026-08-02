# Roles and rights (spec 3.7): only custom roles/rights bundles belong
# here, direct resources, for_each over a map. Do not redeclare VCFA's
# stock global roles / rights bundles / provider roles.
#
# Left empty/minimally scaffolded on purpose: capturing which of the
# pre-teardown lab's 5 global roles, 28 rights bundles, and 6 provider
# roles were custom (versus stock) requires diffing against
# vcfa-state.json from the pre-teardown capture, which is Scott's
# teardown-state artifact and not something available in this workspace
# to fabricate role definitions against. This is a follow-up once that
# diff is supplied, not a guess made now.
#
# Checked again on 2026-08-02 for docs/state-captures/2026-08-01-vcfa-pre-teardown/
# in the lab-admin repo (the path a compiled inputs summary in that repo
# points at): the directory is not present on disk there, so there is
# still nothing to diff against. Still a follow-up, not a guess.

# Example shape for the follow-up (uncomment and adapt once the custom
# role/rights-bundle diff is available):
#
# variable "custom_roles" {
#   type = map(object({
#     name          = string
#     description   = string
#     rights        = set(string)
#     bundle_key    = optional(string)
#   }))
#   default = {}
# }
#
# resource "vcfa_role" "this" {
#   for_each    = var.custom_roles
#   org_id      = data.vcfa_org.system.id
#   name        = each.value.name
#   description = each.value.description
#   rights      = each.value.rights
# }
