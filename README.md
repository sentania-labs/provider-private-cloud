# provider-private-cloud

Control-plane Terraform automation for the VCFA (VMware Cloud Foundation Automation) **region layer**: region creation, external connectivity, provider content library, orgs (including OIDC federation), org networking, and region quotas. This is the top of a three-repo split; `vm-apps-private-cloud` and `all-apps-private-cloud` consume what this repo creates by name via data sources, never remote state, so each repo applies independently and no repo's state layout becomes an API for another.

Work in progress. See `docs/proposals/provider-private-cloud-spec.md` in `lab-admin` for the full design rationale; this README covers what actually shipped and what's still open.

## Structure

```
provider-private-cloud/
├── backend.tf                 # S3 remote state
├── versions.tf                # Required providers
├── provider.tf                # vcfa + restapi provider config
├── variables.tf                # All root variables
├── region.tf                   # vCenter/NSX/Supervisor data sources + vcfa_region
├── external_connectivity.tf    # IP space + provider gateway (BLOCKING: external CIDR)
├── content_library.tf          # Provider content library + items
├── orgs.tf                     # module.orgs + OIDC client mint/rotate (restapi provider)
├── org_networking.tf           # module.org_networking
├── region_quota.tf             # vcfa_org_region_quota, direct resource (not a module)
├── roles.tf                    # Custom roles/rights only (scaffolded, see below)
├── envs/                       # Environment tfvars (non-secret topology only)
└── .github/workflows/          # CI: lint (fmt-check + backend-less validate, no secrets) -> plan+apply (push to main only, credentialed)
```

## Usage

```bash
terraform init
terraform plan  -var-file="envs/lab.tfvars"
terraform apply -var-file="envs/lab.tfvars"
```

All credentials, the SSO realm id, and the external CIDR are supplied via `TF_VAR_*` (see "Variables not in tfvars" below), never in a committed tfvars file.

## Registry modules consumed

- `sentania-labs/org/vcfa` `~> 0.1.0`: the whole org product (org, org settings, local admin, OIDC federation) in one module, because an org without its federation is not a usable org.
- `sentania-labs/org-networking/vcfa` `~> 0.1.0`: hides the ordering trap where `vcfa_org_regional_networking` must chain off the `vcfa_org_networking` resource id, not the org id, or `log_name` is silently unset.

Region quota is deliberately **not** a module: see the comment at the top of `region_quota.tf`. Its three data lookups (`vcfa_region_zone`, `vcfa_region_vm_class`, `vcfa_region_storage_policy`) are region-scoped and identical across orgs, so they're hoisted to root and `vcfa_org_region_quota` is `for_each`'d directly.

## Variables not in tfvars

Supplied via `TF_VAR_*` (see the CI workflow for the exact secret names):

- `vcfa_admin_username` / `vcfa_admin_password`: System-org admin auth (username/password is the verified-working path this session; the `VCFA_API_TOKEN` from the pre-teardown lab-config.json is stale)
- `ops_api_base_url` / `ops_api_token`: VCF Operations fleet-management IAM API, used only to mint/rotate OIDC client secrets (see below)
- `sso_realm_id`: supplied later, during the lab-admin phase; never defaulted or committed
- `local_admin_passwords`: per-org local admin passwords, JSON map keyed the same as `var.orgs`
- `external_cidr`: see "Blocking: external CIDR" below

## State is credential-bearing

**`vcfa_org_oidc` has only a plain `client_secret` argument (no write-only variant in provider v1.2), so every org's OIDC client secret is recorded in Terraform state.** Treat the S3 state object (`sentania-labs-terraform-state`, key `vcfa/provider-private-cloud/lab/terraform.tfstate`) as a credential store, not just infrastructure metadata: state access should be scoped as tightly as an IAM credential vault, not general read access to the state bucket.

S3 bucket encryption-at-rest finding: **could not check.** This environment has no AWS credentials available to run `aws s3api get-bucket-encryption --bucket sentania-labs-terraform-state`. Scott should confirm this directly; the bucket's encryption setting is not something this repo changes (evidence gathering only, never remediation, and out of reach from this session regardless).

## How OIDC client secrets are minted (not carried by hand)

`vcfa_org_oidc`'s `client_secret` is not recoverable from VCFA once set; it lives only in vIDB / the Ops locker. Rather than hand-carrying it, `orgs.tf` uses the `Mastercard/restapi` provider (`~> 3.0.0`) to mint and rotate a per-org OAuth App under the Ops SSO realm (`POST .../ssorealms/{ssoRealmId}/oauth-apps`, then `POST .../oauth-apps/{id}/rotate`), and feeds the response straight into `module.orgs[*].oidc.client_id` / `oidc_client_secret`.

**Rotation is on-demand, never on every apply.** Each org's `oidc.rotation_id` is a keeper: unchanged across applies, the rotate resource's `data` doesn't change, so Terraform issues no API call and the plan is clean and empty for it. Bumping `rotation_id` fires exactly one rotate call.

### restapi provider limitations (documented per the ruling that governed this build)

The `Mastercard/restapi` provider models everything as a `restapi_object` (a REST resource with GET/PUT/POST/DELETE semantics). The rotate endpoint is a bare imperative POST action, not a CRUD object, so this is an honest but imperfect fit:

- The rotate resource uses `update_method`/`update_path` overrides so a `rotation_id` change fires a POST to the rotate path instead of a PUT to a real update endpoint that doesn't exist, and `ignore_all_server_changes = true` since there's nothing meaningful to read back and diff against.
- On first apply, Terraform's CREATE call also targets the rotate path (deliberately): the org's OAuth app is rotated immediately after being minted, so the rotate resource's response is the single source of truth for "the org's current secret" in every case, not just after an explicit rotation.
- There is no server-side DELETE for a rotation action. Removing the rotate resource from config, or removing an org's `oidc` block after it's been applied, would issue a DELETE the API almost certainly doesn't support. Don't do that: see the comment block at the top of the rotate resource in `orgs.tf`.
- The unauthenticated well-known-URL discovery lookup (`data.restapi_object.vidb_wellknown` in `orgs.tf`) uses the provider's data source, which is built for list-search responses (`search_key`/`search_value`/`results_key`). The spec describes this endpoint as returning a single object, not an array. **This is not verified against a live Ops instance** and may need `results_key` adjustment once confirmed.

## Blocking: external CIDR

`var.external_cidr` (`external_connectivity.tf`, `envs/lab.tfvars`) has **no default on purpose**. 9.0.2 recorded `172.18.0.0/16`; the block found live during teardown is `172.17.0.0/16` and is in use by the supervisor's default connectivity profile, so it was spared and must not be reused. The new IP space needs a range that is routed to the T0 and doesn't collide with `172.17.0.0/16`: this needs a router-side answer (confirm against the T0's BGP neighbours and advertised prefixes) before a first apply.

## Open decisions carried over from the spec

1. **External CIDR**: blocking, see above.
2. **Custom roles/rights capture** (`roles.tf`): left as an empty/scaffolded file. Capturing which of the pre-teardown lab's 5 global roles, 28 rights bundles, and 6 provider roles were custom (versus stock, which should not be redeclared) requires diffing against Scott's pre-teardown `vcfa-state.json` capture, which isn't available in this workspace.
3. **SupervisorNamespaceClasses module placement**: not built here (out of scope for this repo per spec 3.9). Open: module lives here, or in the org tenant repos (`vm-apps-private-cloud` / `all-apps-private-cloud`)?
4. **`hol-scitech` ownership**: does it live in `var.orgs` here, or get created by the hand-off python so the pod maintainer sees the whole flow end to end? Not included in `envs/lab.tfvars` pending this answer.
5. **CI auth**: this workflow uses repo secrets (`TF_VAR_*` env vars), matching the sibling repos' pattern, rather than `workflow_dispatch` inputs, since `push`-to-`main` applies need credentials without a human present to supply them. Revisit if that assumption is wrong for this repo's operational model. Unlike the sibling repos, those secrets are scoped to a push-to-`main`-only job: because this repo's state and plans are credential-bearing (VCFA admin password, Ops API token, minted OIDC client secrets), `pull_request` runs only get a secret-free fmt-check and backend-less validate, never a real plan.

## License

MIT
