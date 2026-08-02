# Phase-1/phase-2 rollout gate (var.enable_orgs, variables.tf). Every
# org-scoped for_each in orgs.tf, org_networking.tf, and region_quota.tf
# reads local.effective_orgs instead of var.orgs directly, so flipping the
# flag is the only thing that changes what gets built: var.orgs itself, and
# envs/lab.tfvars' actual org definitions, stay fully committed either way.
locals {
  effective_orgs = var.enable_orgs ? var.orgs : {}
}
