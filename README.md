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
├── external_connectivity.tf    # IP space (imported, not created) + provider gateway
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

Credentials are supplied via `TF_VAR_*` (see "Variables not in tfvars" below), never in a committed tfvars file. The SSO realm id, the OIDC discovery URL, and the external CIDR are identifiers, not secrets, and are committed in `envs/lab.tfvars`.

## Pre-apply checklist

Read before the first real apply against the lab:

1. **`vcenter_name` is a genuine placeholder** (`envs/lab.tfvars`). VCFA is currently torn down, so the registered display name can't be verified against a live instance. Checked again on 2026-08-02 for a pre-teardown state capture (`docs/state-captures/2026-08-01-vcfa-pre-teardown/` in `lab-admin`) that might record the registered name: that directory is not present on disk in that workspace, so the placeholder stays as-is. Confirm it against the live vCenter before applying.
2. **External IP space is imported, not created; the imported quota fields are unverified.** See "External CIDR" below: `vcfa_ip_space.ext` now carries an `import {}` block that adopts the teardown-surviving `vcf-lab-region01-default-ip-space` block instead of creating a second one over `172.17.0.0/16`. What's still open is whether `default_quota_max_subnet_size` / `default_quota_max_cidr_count` / `default_quota_max_ip_count` as configured match the live block's actual settings; a plan immediately after import that wants to change any of those three fields means they don't. Run the `workflow_dispatch` plan-only dry run first (see "Dry run before merge" below) and read that resource's plan carefully.
3. **Redirect/logout URLs registered on the OAuth app are best-effort**, not confirmed against a live OIDC client registration. See "OAuth app redirect/logout URLs" below.

## Registry modules consumed

- `sentania-labs/org/vcfa` `~> 0.1.0`: the whole org product (org, org settings, local admin, OIDC federation) in one module, because an org without its federation is not a usable org.
- `sentania-labs/org-networking/vcfa` `~> 0.1.0`: hides the ordering trap where `vcfa_org_regional_networking` must chain off the `vcfa_org_networking` resource id, not the org id, or `log_name` is silently unset.

Region quota is deliberately **not** a module: see the comment at the top of `region_quota.tf`. Its three data lookups (`vcfa_region_zone`, `vcfa_region_vm_class`, `vcfa_region_storage_policy`) are region-scoped and identical across orgs, so they're hoisted to root and `vcfa_org_region_quota` is `for_each`'d directly.

## Variables not in tfvars

Supplied via `TF_VAR_*` (see the CI workflow for the exact secret names):

- `vcfa_api_token`: VCF Admin service-account API token for the vcfa provider (org System), issued from the provider portal
- `ops_api_base_url`: base URL of the VCF Operations fleet-management IAM API
- `ops_api_token`: short-lived Ops API token. Not a stored secret: CI acquires it at runtime from `VCF_LAB_OPS_USER` / `VCF_LAB_OPS_PASSWORD` before any terraform step, see "Ops API auth" below
- `local_admin_passwords`: per-org local admin passwords, JSON map keyed the same as `var.orgs`

`sso_realm_id`, `oidc_wellknown_endpoint`, and `external_cidr` are identifiers/URLs, not secrets, and are committed in `envs/lab.tfvars` (see their sections below for provenance).

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
- The well-known-URL discovery lookup is no longer a `restapi_object` data source: see "SSO realm and OIDC discovery" below for why it's now a plain committed value.

## External CIDR

`var.external_cidr` = `172.17.0.0/16`, set in `envs/lab.tfvars`. This was previously believed to collide with the supervisor's default connectivity profile and was left unset (BLOCKING). That was backwards: live vCenter evidence (wld01-cl01-supervisor > Configure > Network > Workload Networks) shows a single External IP Block named `vcf-lab-region01-default-ip-space`, whose name is derived from this repo's region name (`vcf-lab-region01`). This IS the region's own external IP space, not a foreign allocation to avoid. It survived the VCFA teardown and still exists on the supervisor under that name. `172.18.0.0/16`, seen in older docs, was a reservation for a second supervisor (`wld01-cl02-supervisor`) that was never built and doesn't exist; that value is stale.

**Resolved: the block is imported, not created.** Because `vcf-lab-region01-default-ip-space` already exists (a teardown survivor), `external_connectivity.tf` carries an `import {}` block adopting it into `vcfa_ip_space.ext` rather than declaring a fresh `vcfa_ip_space` over the same CIDR, which is the actual collision this repo would otherwise hit on a first apply (not a hypothetical: the block is confirmed live, so a plain `create` here would either 409 against NSX or silently produce a second block over `172.17.0.0/16`, neither of which is wanted). Confirmed against the published `vmware/vcfa` provider docs (`docs/resources/ip_space.md`, fetched from `github.com/vmware/terraform-provider-vcfa` at the `main` branch on 2026-08-02):

- The resource exports `is_imported_ip_block`, an explicit signal that adoption of a pre-existing NSX IP Block is a supported, intended posture for this resource, not just a recovery mechanism.
- The documented import ID format is `<region-name>.<ip-space-name>` (a literal `.`-separated path, configurable via the provider's `import_separator`), which is what the `import {}` block's `id` argument uses here: `"${var.region_name}.${var.region_name}-default-ip-space"`.
- The resource's `name` argument was changed from the old placeholder computed name (`"${var.region_name}-ipspace01"`) to `"${var.region_name}-default-ip-space"`, matching the live block's actual name, so config and live reality agree post-import.

**Still open: whether the declared quota fields match the live block.** `default_quota_max_subnet_size = 24`, `default_quota_max_cidr_count = -1`, `default_quota_max_ip_count = -1` are the values carried over from the original sketch, not confirmed against the live block's actual configuration: this workspace has no API access to read it back. An import followed by a plan that immediately wants to change any of these three fields is not a clean adoption, it's a disguised recreate-in-place; read that resource's plan carefully on the first `terraform plan` after this merges (see pre-apply checklist above).

## VCFA provider auth

The vcfa provider (`provider.tf`) uses `api_token` auth against org `System`, fed from `TF_VAR_vcfa_api_token` (CI: `secrets.VCF_LAB_PROVIDER_REFRESH_KEY`), the same pattern the sibling repos use for their own vcfa provider blocks (`api_token = var.vcfa_refresh_token`, `auth_type = "api_token"`). The earlier username/password path (`admin@system`) is retired: the pre-teardown token was stale, this is a freshly issued VCF Admin service-account token from the provider portal.

## Ops API auth

Two things changed here from the original build:

1. **Scheme**: the `restapi` provider's `Authorization` header is `"OpsToken <token>"`, not `"Bearer <token>"`. Confirmed against live-appliance recon documented in `lab-admin`'s `docs/sops/vcfa-ops-orphan-component-removal.md`.
2. **Token acquisition**: Ops tokens are short-lived and acquired via a login round-trip, not stored. Scott's created secrets are `VCF_LAB_OPS_USER` / `VCF_LAB_OPS_PASSWORD` (username/password), not a token. The `plan-and-apply` job's "Acquire Ops API token" step runs *before any terraform step*, `POST`s to `<ops_api_base_url>/suite-api/api/auth/token/acquire` with `{"username", "password"}`, parses the token out of the JSON response with `curl` + `jq`, masks it with `::add-mask::`, and exports it as `TF_VAR_ops_api_token` via `GITHUB_ENV` for every step after it. This ordering dependency (token acquired outside Terraform, must run before `init`/`plan`/`apply`) is load-bearing: don't reorder the workflow steps.

The self-hosted runner needs `curl` and `jq` available; not verified from this workspace.

## SSO realm and OIDC discovery

- `sso_realm_id` = `83369e94-bcad-4674-ba0d-e4b8b70730ee`, realm "VCF Lab", the only realm on the appliance (Ops 9.1.0.0 build 25541561). An identifier, not a secret: committed in `envs/lab.tfvars` instead of hand-supplied via TF_VAR, per the standing rule that a working system ships with reasonable defaults, no hand-population required to run.
- `oidc_wellknown_endpoint` = `https://vcf-lab-idb.int.sentania.net/acs/t/CUSTOMER/.well-known/openid-configuration`, confirmed live. Also committed in `envs/lab.tfvars`.
- The previous build used a `data.restapi_object` lookup against `/suite-api/api/auth/sources/vidb/well-known-url` to resolve this URL dynamically. That data source is deleted: `restapi_object`'s data-source semantics (`search_key`/`search_value`/`results_key`) are built for list-search responses, and this endpoint returns a single object, not an array. Shipping something that fails or silently mis-parses on first apply is worse than a static, live-validated value, so `oidc_wellknown_endpoint` is now a plain committed variable instead.

## OAuth app redirect/logout URLs

`orgs.tf`'s OAuth app create payload uses `clientName` (not `name`) per the VCF Operations fleet-management IAM OAuthApp schema, plus `redirectUrls` and `logoutUrls`, both derived per org from `var.vcfa_url` and the org name via `format()` patterns (`var.oauth_app_redirect_url_pattern` / `var.oauth_app_logout_url_pattern`, `variables.tf`) rather than hard-coded per org.

- **Logout URL** (`"%s/tenant/%s"`): returns to the tenant sign-in page per Scott's ruling. This is VCFA's confirmed tenant context URL convention.
- **Redirect URL** (`"%s/tenant/%s/oauth/callback"`): the `/oauth/callback` suffix is a **guess**, not confirmed against a live OIDC client registration. `vcfa_org_oidc` computes its own true redirect URI as an exported attribute (`oidc_redirect_uri`, surfaced by `module.orgs`) only *after* the org's OIDC federation is created, which happens strictly after this OAuth app resource on first apply, so the real value can't be known at the point this payload is built. After a first apply, compare `module.orgs[*].oidc_redirect_uri` against what got registered here; if they differ, the OAuth app's `redirectUrls` needs a follow-up update (override `var.oauth_app_redirect_url_pattern` or patch by hand in the Ops portal).

## Group to role mappings

`envs/lab.tfvars`' `orgs.*.oidc.groups` now reflects the confirmed mapping instead of the all-orgs-get-`labadmins`-only placeholder:

- **Both orgs**: `labadmins@int.sentania.net` gets the fullest available administrator role set ("super duper admin" per Scott): `Organization Administrator`, `Service Broker Admin`, `Assembler`.
- **`vm_apps` only** (these groups don't exist on `all_apps`): `self-service-user@int.sentania.net` gets `Organization Member`, `Service Broker User`, `approver`; `self-service-admin@int.sentania.net` gets `Organization Member`, `Service Broker User` (explicitly not `Service Broker Admin`), `Assembler`.

All identity strings are lowercase (LDAP-aligned; the sibling repo `vm-apps-private-cloud` still writes `labAdmins@int.sentania.net` in camelCase, this repo deliberately doesn't match that, per Scott).

**Role cardinality**: the org module's `oidc.groups[].role` (and the underlying `variables.tf`'s `orgs.*.oidc.groups[].role`) is a single string, confirmed against the `sentania-labs/org/vcfa` module source (`variables.tf`: `groups = optional(list(object({ name = string, role = string })), [])`, no set/list type for `role`). Since it's a list of entries, a group that needs multiple roles gets multiple list entries with the same `name` and a different `role` each, rather than widening the type. Not changing the module's field shape keeps this repo aligned with what's actually published at `~> 0.1.0`.

**Manual step this still requires**: the org module records this group-to-role mapping in Terraform config, but there is no `vcfa` provider resource for the actual group-to-role binding (no group-import CRUD surface in provider v1.2). Creating the binding itself remains a one-time manual portal step per org after apply. `module.orgs[*].oidc_group_role_map` output exists for reference but isn't wired to any resource.

## Region quota

Both orgs are entitled to the **whole region, no ceiling** (Scott's ruling): whichever org fills the region's capacity first takes it, the other fails to provision. This is a deliberate choice, not an oversight, and it's easy to tighten later since region quota is a root-level resource (`region_quota.tf`), not deeply coupled to anything else in the graph.

No true "unlimited" sentinel is documented for `vcfa_org_region_quota`'s `cpu_limit_mhz` / `memory_limit_mib` / storage `limit_mib` fields in the published provider docs (the storage field documents a minimum of `0`, nothing about a max or an unlimited value like `-1`). Rather than guess a sentinel that might get rejected by the API or silently misinterpreted, `envs/lab.tfvars` uses `999999999` as a large-but-finite proxy for "no meaningful ceiling" on all three limit fields, for both orgs. This wasn't sized against the region's actual measured capacity: that data wasn't available to this session. If the region's real full capacity turns out to be smaller than this number, the practical effect is identical (no ceiling below the region's real limit); if larger, it's still effectively unlimited for any realistic workload. Reservations stay at `0` (no guaranteed floor per org), unchanged from before.

## Open decisions carried over from the spec

1. **External IP space quota fields**: unverified against the live block, see "External CIDR" above. The collision itself is resolved (import, not create).
2. **Custom roles/rights capture** (`roles.tf`): left as an empty/scaffolded file. Capturing which of the pre-teardown lab's 5 global roles, 28 rights bundles, and 6 provider roles were custom (versus stock, which should not be redeclared) requires diffing against Scott's pre-teardown `vcfa-state.json` capture. Checked again on 2026-08-02 for `docs/state-captures/2026-08-01-vcfa-pre-teardown/` in `lab-admin`: still not present on disk in that workspace, so this stays scaffolded, not guessed.
3. **SupervisorNamespaceClasses module placement**: not built here (out of scope for this repo per spec 3.9). Open: module lives here, or in the org tenant repos (`vm-apps-private-cloud` / `all-apps-private-cloud`)?
4. **`hol-scitech` ownership**: does it live in `var.orgs` here, or get created by the hand-off python so the pod maintainer sees the whole flow end to end? Not included in `envs/lab.tfvars` pending this answer.
5. **OAuth app redirect URL**: guessed, see "OAuth app redirect/logout URLs" above, needs reconciling against `module.orgs[*].oidc_redirect_uri` after a first apply.
6. **`VCF_OPS_API_BASE_URL` secret**: referenced by the workflow (`TF_VAR_ops_api_base_url`) but not in the list of secrets Scott confirmed as created. UNRESOLVED whether it already exists under this name in the repo's Settings > Secrets: if not, it needs creating before the credentialed job can run.

## Repo secrets the workflow expects

Check these against the repo's actual Settings > Secrets > Actions page:

- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`: S3 backend
- `VCF_LAB_PROVIDER_REFRESH_KEY`: vcfa provider api_token (VCF Admin service account)
- `VCF_LAB_OPS_USER`, `VCF_LAB_OPS_PASSWORD`: exchanged at CI runtime for a short-lived Ops API token, see "Ops API auth" above
- `VCF_OPS_API_BASE_URL`: base URL of the VCF Operations API. Existence unconfirmed, see "Open decisions" above.
- `VCF_LAB_ORG_LOCAL_ADMIN_PASSWORDS` (optional): per-org local admin passwords map, falls back to `{}` if unset

No other secrets should be referenced anywhere in the workflow. In particular `VCF_LAB_SYSTEM_ADMIN_USERNAME`, `VCF_LAB_SYSTEM_ADMIN_PASSWORD`, `VCF_OPS_API_TOKEN`, `VCF_OPS_SSO_REALM_ID`, and `VCF_LAB_EXTERNAL_CIDR` (referenced by an earlier build of this workflow) are gone: superseded by `vcfa_api_token`, the Ops token-acquire step, and the committed `sso_realm_id` / `external_cidr` values respectively.

## Dry run before merge

Merging to `main` triggers `plan-and-apply` with `-auto-approve` against the real lab; there's no separate deploy step. `workflow_dispatch` now runs the same credentialed job as a **plan-only dry run by default** (an `apply` boolean input, default `false`): init + plan against real credentials, plan printed to the log, nothing applied. Set `apply: true` on the manual run to also apply. `push` to `main` keeps applying unconditionally, unaffected by the new input. This matters concretely for this repo: `vcenter_name` is an unverified placeholder and the external CIDR's collision posture is unresolved (see "Pre-apply checklist" above) — a plan-only dry run is how those get caught before a half-built region, instead of the first real plan being the one that's already applying.

Security posture unchanged: `lint`'s fork-gating on `pull_request` is untouched, no secrets are ever exposed on `pull_request` events, no plan file is ever uploaded as a workflow artifact (including the new plan-only path), and the unconditional workspace cleanup step still runs after the credentialed job regardless of outcome.

## `terraform init -migrate-state`

The previous workflow used `terraform init -migrate-state -input=false` for `plan-and-apply`. `-migrate-state` is for migrating between backend *configurations* (e.g. changing `backend.tf`'s bucket or key) and reusing existing remote state under the new config; it isn't the right flag for this repo's very first apply, where the remote state object doesn't exist yet. It's not simply a harmless no-op either: it's a signal that doesn't match what's happening here. Changed to a plain `terraform init -input=false`, which still creates the state object on first run and is the correct flag going forward (revisit only if `backend.tf` itself changes).

## License

MIT
