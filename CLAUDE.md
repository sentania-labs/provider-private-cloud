# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **single root Terraform configuration** (not a reusable child module) that acts as the **region-layer control plane** for a VCF Automation (VCFA) private cloud: region creation, external connectivity, provider content library, orgs (whole org product including OIDC federation), org networking, and region quotas. Two sibling repos (`vm-apps-private-cloud`, `all-apps-private-cloud`) own the tenant-facing layers on top and consume what this repo creates by name via data sources, never remote state, so a bad plan in a tenant repo can't reach the region and this repo's state layout is never an API another repo depends on.

It composes two published `sentania-labs/*/vcfa` registry modules (org, org-networking) plus direct resources everywhere else. See `README.md` for the product-level narrative, the OIDC-secret-minting design, and the open decisions Scott still needs to resolve.

## Commands

No build, no tests. The entire workflow is Terraform CLI:

```bash
terraform init
terraform fmt                                    # MUST run before commit -- CI fails on fmt -check
terraform validate
terraform plan  -var-file="envs/lab.tfvars"
terraform apply -var-file="envs/lab.tfvars"
```

`envs/lab.tfvars` carries only non-secret topology (placeholder org names/CIDRs, marked as such). Everything else comes from `TF_VAR_*`: see README's "Variables not in tfvars" section before attempting a real plan/apply.

## Apply order (spec section 4)

```
data: vcfa_vcenter, vcfa_nsx_manager, vcfa_supervisor
   └-> vcfa_region
         |-> vcfa_ip_space -> vcfa_provider_gateway
         |-> vcfa_content_library (+ items)
         `-> module.orgs (org_id needed by everything below)
               |-> module.org_networking  (REQUIRES provider_gateway_id)
               `-> vcfa_org_region_quota
                     `-> [tenant repos: projects -> namespace classes -> supervisor namespaces]
                           `-> [manual: JWTAuthenticator on Supervisor CP, out of scope here]
```

`module.orgs`' OIDC inputs additionally depend on `restapi_object.oauth_app` / `restapi_object.oauth_app_rotate` (orgs.tf), which depend only on `var.sso_realm_id` and the Ops API connection vars, not on anything else in this graph.

## Non-obvious conventions / gotchas

- **Region quota is deliberately not a module** (ruling that supersedes the spec's original "weak yes"). The three region-scoped data lookups (`vcfa_region_zone`, `vcfa_region_vm_class`, `vcfa_region_storage_policy`) run once at root in `region_quota.tf` and `vcfa_org_region_quota` is `for_each`'d directly over `var.orgs` filtered to `region_quota != null`. Don't reintroduce a `region-quota` module, local or registry: there's no trap to hide here, only tedium, and the tedium is already gone once the lookups are hoisted to root.
- **OIDC client secrets are minted, not carried by hand** (orgs.tf, README "How OIDC client secrets are minted"). `client_id`/`client_secret` are never fields in `var.orgs`: they come from the `restapi` provider's OAuth-app create/rotate resources. Don't add an `oidc_secrets` map variable; that was the spec's original shape and is superseded.
- **Rotation is on-demand, never on every apply.** The rotate resource's diff is keyed only on `var.orgs[*].oidc.rotation_id`. Verify with `terraform plan` twice in a row before assuming a change to this file is safe: an unchanged `rotation_id` must produce a clean, empty plan for `restapi_object.oauth_app_rotate`.
- **`org-networking`'s ordering trap**: `vcfa_org_regional_networking` (inside the module) must chain off the `vcfa_org_networking` resource id, not the org id, or `log_name` silently fails to be set. This is why `org-networking` is a module at all: don't inline its two resources here even for a "quick" change.
- **Org-region-quota-before-org-delete teardown trap.** The region quota is the `vcf_virtual_datacenter` row; an org cannot be deleted while it owns one (API returns 202, then the task fails with a raw Postgres FK error). Create order is already correct here (`region_quota.tf` depends on `module.orgs`); destroy order is the operator's responsibility: quota before org, always.
- **`vcfa_content_library` needs `org_id` + `storage_class_ids`, not a region reference.** The original design sketch used `region_ids`, which doesn't exist on the real v1.2 resource; confirmed against the published provider docs and fixed in `content_library.tf`. If you're extending this file, don't reintroduce the sketch's shape.
- **`external_scope` on `vcfa_ip_space` is deprecated** in provider v1.2. `external_connectivity.tf` uses `inbound_remote_networks` on the provider gateway instead: don't "fix" this back to `external_scope` from an older example.
- **`restapi` provider models a bare POST action as a `restapi_object`**, which is an imperfect fit: read the limitations section in README before touching `orgs.tf`'s rotate resource. In particular, never remove that resource from config or an org's `oidc` block from `var.orgs` after it's been applied; there is no supported DELETE for a rotation action.

## State & CI

- **Backend:** S3 bucket `sentania-labs-terraform-state`, key `vcfa/provider-private-cloud/lab/terraform.tfstate`, `use_lockfile = true`. **This state is credential-bearing** (every org's OIDC client secret lives in it, see README): treat access to it like access to a credential vault, not general infra read access.
- **CI:** `.github/workflows/configure-private-cloud.yml`, self-hosted `[self-hosted, terraform]` runner, two jobs. `lint` runs on every push and PR (fork-gated: `github.event.pull_request.head.repo.owner.login == 'sentania-labs'`), gets no secrets, and only does fmt-check plus a backend-less `terraform validate`. `plan-and-apply` runs only on push to `main`, is the sole place production secrets are injected, and never uploads the plan as an artifact or leaves `tfplan` on the runner: it's created and consumed in one step, and cleanup runs with `if: always()`. This split exists because this repo's plans and state are credential-bearing (see "State is credential-bearing" above); don't move credentialed steps back onto `pull_request` events even for convenience.

## Versions

Terraform `>= 1.14.0`. Providers: `vmware/vcfa ~> 1.2`, `Mastercard/restapi ~> 3.0.0`. Registry modules pinned `~> 0.1.0` (both `sentania-labs/org/vcfa` and `sentania-labs/org-networking/vcfa`); bump deliberately, not silently, since both are young enough (v0.x) that a minor bump can still be a breaking interface change.
