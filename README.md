# provider-private-cloud

Control-plane Terraform automation for the VCFA (VMware Cloud Foundation Automation) **region layer**: region creation, external connectivity, orgs (including OIDC federation), org networking, and region quotas, plus the provider content library as a separate apply stage (`content/`, see "Content is its own stage" below). This is the top of a three-repo split; `vm-apps-private-cloud` and `all-apps-private-cloud` consume what this repo creates by name via data sources, never remote state, so each repo applies independently and no repo's state layout becomes an API for another.

Work in progress. See `docs/proposals/provider-private-cloud-spec.md` in `lab-admin` for the full design rationale; this README covers what actually shipped and what's still open.

## Structure

```
provider-private-cloud/
├── backend.tf                 # S3 remote state (key: .../lab/terraform.tfstate)
├── versions.tf                # Required providers
├── provider.tf                # vcfa + restapi provider config
├── variables.tf                # All root variables
├── locals.tf                   # local.effective_orgs (enable_orgs phase gate)
├── region.tf                   # vCenter/NSX/Supervisor data sources + vcfa_region
├── external_connectivity.tf    # IP space (fresh create) + provider gateway
├── orgs.tf                     # module.orgs + OIDC client mint/rotate (restapi provider)
├── org_networking.tf           # module.org_networking
├── region_quota.tf             # vcfa_org_region_quota, direct resource (not a module)
├── roles.tf                    # Custom roles/rights only (scaffolded, see below)
├── envs/                       # Environment tfvars (non-secret topology only)
├── content/                     # Separate root module + backend: provider content library apply stage, see "Content is its own stage" below
│   ├── backend.tf                # S3 remote state (key: .../lab/content.tfstate, own lock)
│   ├── versions.tf                # vcfa provider only
│   ├── provider.tf                # vcfa provider config
│   ├── variables.tf                # vcfa_url / vcfa_api_token / insecure / region_name / content_libraries
│   ├── content_library.tf          # data sources (org System, region by name) + vcfa_content_library(_item) + import block
│   └── envs/                       # Environment tfvars for this stage
└── .github/workflows/          # CI: lint (fmt-check + backend-less validate, no secrets) -> plan+apply (platform, push to main only, credentialed) -> content (same gating, needs platform)
```

## Content is its own stage

The provider content library used to be a resource in this root (`content_library.tf`, provider-scoped, always built regardless of `enable_orgs`). It is now `content/`, its own root module with its own S3 backend (`.../lab/content.tfstate`), applied as a separate CI job that runs after the platform stage succeeds. Two reasons, both from the same incident (CI run 30784618486):

1. **Content is not platform, and must not gate identity or networking (Scott's ruling).** A content library create call is a long-running, publisher-dependent operation (see below); orgs, OIDC federation, org networking, and region quotas have no reason to wait on it, or to fail because it failed.
2. **A long-running content operation must not be able to expire the session underneath unrelated resources in the same apply.** In that run, the subscribed library's create call sat on VCFA's own sync task for 60+ minutes. The `vcfa` provider's session token expired mid-wait; the create call then errored with a 401 retrieving task status, and every downstream resource in that single apply graph (OIDC, org networking, region quotas, local admin users) never applied, purely because it shared a graph and a provider session with a slow content operation it had no actual dependency on. Splitting the stage means a content-side timeout or session expiry can no longer take down identity/networking resources it never needed to run alongside.

Each stage has its **own S3 lock** (`use_lockfile = true` on both `backend.tf`s, independent lock ids). If a stage's apply is killed or times out mid-run (the new `timeout-minutes: 30` on both CI jobs), that stage's lock can be left held. Clearing it is a manual, by-design step, not something CI automates:

```bash
# From the repo root, for the platform stage:
terraform force-unlock <lock-id>

# From content/, for the content stage:
cd content && terraform force-unlock <lock-id>
```

Run this once per stage whose lock is actually stuck; the two stages' locks are independent, clearing one has no effect on the other. `<lock-id>` is printed in the error Terraform gives when it can't acquire a held lock.

### Adopting the live library

Run 30784618486 (before this split existed) created `vcf-lab-content-library` successfully server-side (Scott confirmed in the VCFA portal) but the create call's Terraform-side 401 (see above) meant it never entered state. A naive re-apply would collide with it on name. `content/content_library.tf` has a native `import {}` block adopting it instead of recreating it, gated by `var.adopt_content_library` so it only runs when the library actually exists server-side:

```hcl
import {
  for_each = var.adopt_content_library ? { adopt = 1 } : {}
  to       = vcfa_content_library.this["provider_library"]
  id       = "System.vcf-lab-content-library"
}
```

**`adopt_content_library` is never hand-set in committed config.** An unconditional import block would fail any future fresh rebuild of this stage (importing an object that doesn't exist yet errors the plan), and a tfvars boolean a human has to remember to flip is exactly the kind of drift-prone manual step this repo avoids elsewhere. Instead:

- **In CI**, the `content` job's "Probe for existing content library" step (`.github/workflows/configure-private-cloud.yml`) runs before `Terraform Init`. It queries VCFA for a content library named `vcf-lab-content-library` under org System, using the same `TF_VAR_vcfa_api_token` the job already holds (no separate secret, no token echoed anywhere in the step), and writes `TF_VAR_adopt_content_library=true` or `=false` to `GITHUB_ENV` depending on whether it found the library. A curl failure (auth error, non-2xx, malformed response) fails the step outright under `set -e`; only a clean response is ever treated as an answer, and an empty/non-matching result set is the only thing treated as a legitimate "false".
  - Endpoint: `GET {vcfa_url}/cloudapi/vcf/contentLibraries/?filter=name==vcf-lab-content-library`, `Accept: application/json;version=40.0`. Confirmed against the `vcfa` provider's own SDK (`github.com/vmware/go-vcloud-director`): `govcd/tm_content_library.go`'s `GetContentLibraryByName` issues this same GET with the same filter syntax; `govcd/openapi_endpoints.go` maps the `vcf/contentLibraries/` endpoint to minimum API version `40.0`; `govcd/openapi.go` builds the Accept header as `application/json;version=<apiVersion>`.
  - `TF_VAR_vcfa_api_token` is a refresh token, not a bearer token: the probe step exchanges it for a bearer access token first via `POST {vcfa_url}/oauth/provider/token` (`grant_type=refresh_token`), the same exchange `govcd/api_token.go`'s `GetBearerTokenFromApiToken` performs for org System, before using it as an `Authorization: Bearer` header on the contentLibraries call.
- **Locally/manually**, an operator applying `content/` must supply `TF_VAR_adopt_content_library=true` or `=false` explicitly on the command line, after checking the VCFA portal for whether `vcf-lab-content-library` currently exists under org System. There is no default that assumes an answer for a real apply; `variables.tf`'s `default = false` only covers a bare `terraform validate` or an accidental local run with nothing supplied, and is deliberately the non-importing (create) posture, never the importing one.

The import id format is confirmed against the `vmware/terraform-provider-vcfa` `v1.2.0` docs (`docs/resources/content_library.md`, Import section, matching this repo's `versions.tf` pin of `~> 1.2`): PROVIDER-type libraries import as `"<org name>"."<library name>"` with `.` as the default separator (overridable via the provider's `import_separator` or `VCFA_IMPORT_SEPARATOR`), which resolves to the single string `System.vcf-lab-content-library` once the docs' shell-quoting is read as plain concatenation.

This session could not run `terraform plan` against real credentials or real state, so the import's post-plan cleanliness is **not confirmed by this work**, only by reading the schema and matching `content/envs/lab.tfvars`' config (name, org, storage class, subscription config, no `items`) as closely as possible to the live object. The first CI run on the PR that introduces this (a `workflow_dispatch` plan-only run against real credentials, before anyone applies) must confirm the plan is clean, and that the probe step correctly resolves `adopt_content_library` to `true` against the live library.

**Platform-root state**: removing `vcfa_content_library`/`vcfa_content_library_item` from the platform root's `.tf` files did not go through `terraform state rm` or `state mv`. Reasoning: Terraform only writes a resource into state after a successful create response, and run 30784618486's create call never reached one (it errored with a 401 while retrieving task status, before any successful create response), so the library should never have entered platform state to begin with. This is this session's best understanding from how Terraform state writes work and from the run's own error, **not confirmed by reading the actual platform state file** (no AWS credentials / backend access in this sandboxed session). Before trusting this blind, the first CI run on this PR, or a manual `terraform state list` against the platform backend if Scott wants to check first, should confirm there's genuinely nothing content-library-shaped left in platform state.

## Usage

```bash
terraform init
terraform plan  -var-file="envs/lab.tfvars"
terraform apply -var-file="envs/lab.tfvars"
```

For the content stage, the same commands from `content/`:

```bash
cd content
terraform init
terraform plan  -var-file="envs/lab.tfvars"
terraform apply -var-file="envs/lab.tfvars"
```

Credentials are supplied via `TF_VAR_*` (see "Variables not in tfvars" below), never in a committed tfvars file. The SSO realm id, the OIDC discovery URL, and the external CIDR are identifiers, not secrets, and are committed in `envs/lab.tfvars`.

## Pre-apply checklist

Read before the first real apply against the lab:

1. **`roles.tf` is still an empty scaffold.** Capturing which of the pre-teardown lab's custom roles/rights bundles were custom (versus stock) requires diffing against Scott's pre-teardown `vcfa-state.json` capture, which isn't available in this workspace. See "Open decisions" below.
2. **S3 bucket encryption-at-rest is unconfirmed.** No AWS credentials are available in this workspace to check. See "State is credential-bearing" below.
3. **Redirect/logout URLs registered on the OAuth app are best-effort**, not confirmed against a live OIDC client registration. The `/oauth/callback` suffix in particular is an unverified guess pending a first real apply. See "OAuth app redirect/logout URLs" below.
4. **`enable_orgs = true` in `envs/lab.tfvars` is the phase-2 apply.** Phase 1 (region + external IP space + provider gateway only, no orgs) is already applied on `main`. Merging the PR that flips this flag to `true` builds both orgs, their break-glass local admins, OIDC federation, org networking, and region quotas, on Scott's explicit go. See "Phased apply" below.
5. **`content/`'s `vcfa_content_library.this["provider_library"]` has a native `import {}` block adopting the live `vcf-lab-content-library`, gated by `var.adopt_content_library`.** This library was created server-side by the platform stage's own earlier apply (before the content/platform split), then never recorded in Terraform state, see "Adopting the live library" below. CI answers `adopt_content_library` per run via a probe step; a local apply must supply it explicitly. This session could not run a real plan against real state to confirm the import produces a clean diff: the first CI run on the PR that introduces this (a `workflow_dispatch` plan-only run) must confirm it before anyone applies.
6. **Two independent state locks now exist** (`.../lab/terraform.tfstate` and `.../lab/content.tfstate`), see "Content is its own stage" below. A wedged apply on either stage can leave its own S3 lock held; clearing one has no effect on the other.

## Registry modules consumed

- `sentania-labs/org/vcfa` `~> 0.1.0`: the whole org product (org, org settings, local admin, OIDC federation) in one module, because an org without its federation is not a usable org.
- `sentania-labs/org-networking/vcfa` `~> 0.1.0`: hides the ordering trap where `vcfa_org_regional_networking` must chain off the `vcfa_org_networking` resource id, not the org id, or `log_name` is silently unset.

Region quota is deliberately **not** a module: see the comment at the top of `region_quota.tf`. Its three data lookups (`vcfa_region_zone`, `vcfa_region_vm_class`, `vcfa_region_storage_policy`) are region-scoped and identical across orgs, so they're hoisted to root and `vcfa_org_region_quota` is `for_each`'d directly.

## Variables not in tfvars

Supplied via `TF_VAR_*` (see the CI workflow for the exact secret names):

- `vcfa_api_token`: VCF Admin service-account API token for the vcfa provider (org System), issued from the provider portal
- `ops_api_base_url`: base URL of the VCF Operations fleet-management IAM API
- `ops_api_token`: short-lived Ops API bearer token. Not a stored secret: CI exchanges the durable `VCF_LAB_API_TOKEN` vIDB user API token for it via the vIDB token exchange flow before any terraform step, see "Ops API auth" below
- `local_admin_passwords`: per-org break-glass local admin passwords, JSON map keyed the same as `var.orgs`. In CI this is built from the single `VCFA_FIRST_USER_DEFAULT_PASSWORD` secret (one shared password for both orgs for now), not supplied directly as a JSON secret, see "Repo secrets the workflow expects" below

`sso_realm_id`, `oidc_wellknown_endpoint`, and `external_cidr` are identifiers/URLs, not secrets, and are committed in `envs/lab.tfvars` (see their sections below for provenance).

## State is credential-bearing

**`vcfa_org_oidc` has only a plain `client_secret` argument (no write-only variant in provider v1.2), so every org's OIDC client secret is recorded in Terraform state.** Treat the S3 state object (`sentania-labs-terraform-state`, key `vcfa/provider-private-cloud/lab/terraform.tfstate`) as a credential store, not just infrastructure metadata: state access should be scoped as tightly as an IAM credential vault, not general read access to the state bucket.

S3 bucket encryption-at-rest finding: **could not check.** This environment has no AWS credentials available to run `aws s3api get-bucket-encryption --bucket sentania-labs-terraform-state`. Scott should confirm this directly; the bucket's encryption setting is not something this repo changes (evidence gathering only, never remediation, and out of reach from this session regardless).

## How OIDC client secrets are minted (not carried by hand)

`vcfa_org_oidc`'s `client_secret` is not recoverable from VCFA once set; it lives only in vIDB / the Ops locker. Rather than hand-carrying it, `orgs.tf` uses the `Mastercard/restapi` provider (`~> 2.0`) to mint and rotate a per-org OAuth App under the Ops SSO realm (`POST .../ssorealms/{ssoRealmId}/oauth-apps`, then `POST .../oauth-apps/{id}/rotate`), and feeds the response straight into `module.orgs[*].oidc.client_id` / `oidc_client_secret`.

**Rotation is on-demand, never on every apply.** Each org's `oidc.rotation_id` is a keeper: unchanged across applies, the rotate resource's `data` doesn't change, so Terraform issues no API call and the plan is clean and empty for it. Bumping `rotation_id` fires exactly one rotate call.

### restapi provider limitations (documented per the ruling that governed this build)

The `Mastercard/restapi` provider models everything as a `restapi_object` (a REST resource with GET/PUT/POST/DELETE semantics). The rotate endpoint is a bare imperative POST action, not a CRUD object, so this is an honest but imperfect fit:

- The rotate resource uses `update_method`/`update_path` overrides so a `rotation_id` change fires a POST to the rotate path instead of a PUT to a real update endpoint that doesn't exist, and `ignore_all_server_changes = true` since there's nothing meaningful to read back and diff against.
- On first apply, Terraform's CREATE call also targets the rotate path (deliberately): the org's OAuth app is rotated immediately after being minted, so the rotate resource's response is the single source of truth for "the org's current secret" in every case, not just after an explicit rotation.
- A `rotation_id` change forces a full destroy+create replace of the rotate resource (a `lifecycle.replace_triggered_by` keyed to a `terraform_data` mirror of `rotation_id`), not an in-place update: on `Mastercard/restapi` v2.0.1 the secret has to come from `create_response`, which only CREATE populates, so every rotation needs to go through CREATE. See the long comment on `oauth_app_rotate` in `orgs.tf`.
- There is no server-side DELETE for a rotation action. `destroy_method`/`destroy_path` are overridden to a harmless GET against the OAuth app's real, already-verified-working object endpoint, so the destroy half of that routine replace cycle can't fail or delete anything, rather than depending on an untested assumption about how the API responds to a DELETE against a path that was never a real object. Removing the rotate resource from config entirely, or removing an org's `oidc` block after it's been applied, is still unsupported: don't do that, see the comment block at the top of the rotate resource in `orgs.tf`.
- The well-known-URL discovery lookup is no longer a `restapi_object` data source: see "SSO realm and OIDC discovery" below for why it's now a plain committed value.

### restapi provider is pinned to 2.x, not 3.x

`Mastercard/restapi` is deliberately pinned to `~> 2.0` (`versions.tf`) and should not be bumped to a 3.x release until a fixed release addresses the empty-JSON-on-refresh bug: v3.0.0's plugin-framework rewrite fails `terraform plan`'s refresh step with `Invalid JSON String Value` on the `data` field of both `restapi_object` resources in this file, tracked upstream as Mastercard/terraform-provider-restapi#350 and #367 (the #350 reporter confirmed this persists in the v3.0.0 release itself, and there is no fixed release as of this writing). v2.0.1 (the newest 2.x release) doesn't have this bug: its `data` field is a plain string, not a JSON-typed one that validates on refresh.

The two orphaned OAuth apps left behind in vIDB under their old names (`vcf-lab-all-apps-oidc`, `vcf-lab-vm-apps-oidc`) can be deleted from the vIDB UI at leisure; they are not referenced by Terraform state or config regardless of what version of the provider is used, so there's no urgency and no automation task for it.

### Escape hatch: `terraform state rm` via workflow_dispatch

`configure-private-cloud.yml`'s `workflow_dispatch` trigger has an optional `state_rm` input: a space- or comma-separated list of Terraform state addresses to `terraform state rm` before planning. This exists for CI-native state surgery, no SSH to the runner, no local state file edits, when a provider migration (or similar) leaves state entries the new provider version can't safely refresh. It only ever runs on an explicit, manually-triggered `workflow_dispatch` run: it is never wired into the `push` trigger.

**Immediate post-merge step for this PR**: after this PR merges and before the next `plan-and-apply` run, trigger `workflow_dispatch` with `state_rm` set to:

```
restapi_object.oauth_app["all_apps"], restapi_object.oauth_app["vm_apps"]
```

so the v2 provider never tries to refresh state entries written by v3 (which is what would otherwise immediately re-trigger the same class of bug, or a different v2/v3 schema mismatch, on the very next apply). As of this writing, those are the only two `restapi_object` entries in state: the `oauth_app_rotate` resources and the org OIDC federation configs were never actually created, since the failing run never got past `terraform plan`, so there is nothing else to remove.

## Break-glass local admins and tenant CI credentials (design note, not implemented here)

Each org's `local_admin` (see `orgs.tf`'s root-level `data.vcfa_role` + `vcfa_org_local_user`, and `envs/lab.tfvars`) exists for one reason: **federated OIDC users authenticate through an interactive browser redirect and cannot mint an API token non-interactively from CI.** A local, non-federated admin account is the only way to bootstrap tenant-repo credentials headlessly.

The intended pattern for the tenant repos (`vm-apps-private-cloud`, `all-apps-private-cloud`), documented here for a future reader but **not implemented in this repo**:

1. From the tenant repo (or a one-time bootstrap step), authenticate against the `vcfa` provider as that org's local admin user (username/password).
2. That authenticated session mints a `vcfa_api_token` scoped to the local admin user. The token inherits the minting user's role/permissions (here, Organization Administrator), the provider requires `allow_token_file = true` on the resource, and the token value lands in both Terraform state and a local file, both credential-bearing artifacts needing the same handling discipline documented in "State is credential-bearing" above.
3. The minted token becomes the tenant repo's own CI secret (e.g. `TF_VAR_vcfa_api_token` in that repo's workflow), not anything stored or minted in this repo.

Minting itself belongs in the tenant repos or a small bootstrap script/workflow that lives alongside them, not here.

## External CIDR

`var.external_cidr` = `172.18.0.0/16`, set in `envs/lab.tfvars`, confirmed live and free in NSX (a full ip-blocks listing and a Policy API search both show 5 live blocks total, none matching 172.18.0.0/16 or anything close to it).

**This is a fresh create, not an adopt.** `external_connectivity.tf`'s `vcfa_ip_space.ext` creates a brand-new IP space on this CIDR. There is no `import {}` block, no name reuse, and no quota comparison against anything existing: zero contact with 172.17.0.0/16 in any form. This is an additive second entry on the Default VPC Connectivity Profile: the profile's `external_ip_blocks` field is an array (`maxItems: 5`, confirmed against the live schema), and only 1 of 5 slots is currently used, by the untouched 172.17.0.0/16 block.

`172.17.0.0/16` is a default block from initial vCenter+NSX onboarding. It stays untouched and unmanaged by this repo, permanently: not a hazard to route around, not something the supervisor "owns" in a way this repo needs to avoid, just intentionally out of scope. It was also renamed live (from `vcf-lab-region01-default-ip-space` to `vcf-lab-wld01-default-ip-space`) and had its `vcfa/tenant-manager` NSX tag stripped during an unrelated Supervisor decommission/rebuild cycle; neither its old nor new name is something this repo references or adopts.

The `default_quota_max_subnet_size = 24`, `default_quota_max_cidr_count = -1`, `default_quota_max_ip_count = -1` fields on `vcfa_ip_space.ext` are the operator's chosen defaults for this brand-new IP space, not something being matched against a live block: there's no live block here to match against.

## VCFA provider auth

The vcfa provider (`provider.tf`) uses `api_token` auth against org `System`, fed from `TF_VAR_vcfa_api_token` (CI: `secrets.VCF_LAB_PROVIDER_REFRESH_KEY`), the same pattern the sibling repos use for their own vcfa provider blocks (`api_token = var.vcfa_refresh_token`, `auth_type = "api_token"`). The earlier username/password path (`admin@system`) is retired: the pre-teardown token was stale, this is a freshly issued VCF Admin service-account token from the provider portal.

## Ops API auth

The suite-api username/password acquire endpoint (`/suite-api/api/auth/token/acquire`) cannot be used here: the CI account (`vcf@int.sentania.net`) is vIDB/SSO-backed, and that endpoint rejects SSO-backed accounts outright, proven live with 401s even with `authSource: "VCF SSO"` set. The fix is the officially documented vIDB **token exchange** flow instead, which produces a standard Bearer token suite-api accepts (confirmed working in the lab, documented in Broadcom techdocs "Token Exchange").

1. **Stored secret**: `VCF_LAB_API_TOKEN`, a durable vIDB user API token for `vcf@int.sentania.net` (VCF Admin role, 180-day expiry), not a username/password pair and not the token actually used against suite-api.
2. **Token exchange**: the `plan-and-apply` job's "Exchange vIDB API token for Ops API bearer token" step runs *before any terraform step*, `POST`s to `https://vcf-lab-idb.int.sentania.net/acs/t/CUSTOMER/token` (same host+tenant path as `oidc_wellknown_endpoint` in `envs/lab.tfvars`) with `Content-Type: application/x-www-form-urlencoded` and body `grant_type=urn:custom:vcf:params:oauth:grant-type:api-token`, `api_token=<VCF_LAB_API_TOKEN>`, parses `.access_token` out of the JSON response with `curl` + `jq`, masks it with `::add-mask::`, and exports it as `TF_VAR_ops_api_token` via `GITHUB_ENV` for every step after it. This ordering dependency (token acquired outside Terraform, must run before `init`/`plan`/`apply`) is load-bearing: don't reorder the workflow steps.
3. **Scheme**: the exchanged bearer token is presented to the `restapi` provider's `Authorization` header as `"Bearer <token>"`, not the old `"OpsToken <token>"` scheme (that scheme was specific to the retired suite-api acquire flow).
4. **Lifetimes**: `VCF_LAB_API_TOKEN` itself is durable (180-day expiry, created 2026-08-03, due for regeneration around 2027-01-30); the bearer token it exchanges for is short-lived, roughly 30 minutes, which is why the exchange runs fresh on every CI invocation rather than being cached.

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

1. **Custom roles/rights capture** (`roles.tf`): left as an empty/scaffolded file. Capturing which of the pre-teardown lab's 5 global roles, 28 rights bundles, and 6 provider roles were custom (versus stock, which should not be redeclared) requires diffing against Scott's pre-teardown `vcfa-state.json` capture. Checked again on 2026-08-02 for `docs/state-captures/2026-08-01-vcfa-pre-teardown/` in `lab-admin`: still not present on disk in that workspace, so this stays scaffolded, not guessed.
2. **SupervisorNamespaceClasses module placement**: not built here (out of scope for this repo per spec 3.9). Open: module lives here, or in the org tenant repos (`vm-apps-private-cloud` / `all-apps-private-cloud`)?
3. **`hol-scitech` ownership**: does it live in `var.orgs` here, or get created by the hand-off python so the pod maintainer sees the whole flow end to end? Not included in `envs/lab.tfvars` pending this answer.
4. **OAuth app redirect URL**: guessed, see "OAuth app redirect/logout URLs" above, needs reconciling against `module.orgs[*].oidc_redirect_uri` after a first apply.

## Repo secrets the workflow expects

Check these against the repo's actual Settings > Secrets > Actions page:

- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`: S3 backend (both stages: platform's `terraform.tfstate` and content's `content.tfstate`)
- `VCF_LAB_PROVIDER_REFRESH_KEY`: vcfa provider api_token (VCF Admin service account). Used by both the platform stage and the `content` job: content library operations are org System, PROVIDER-scoped, same auth as the platform root.
- `VCF_LAB_API_TOKEN`: durable vIDB user API token for the `vcf@int.sentania.net` service account (VCF Admin role, 180-day expiry, created 2026-08-03, due for regeneration around 2027-01-30). Exchanged at CI runtime for a short-lived (~30 minute) Ops API bearer token, see "Ops API auth" above
- `VCFA_FIRST_USER_DEFAULT_PASSWORD`: single shared password for both orgs' break-glass local admin users. The "Build local admin passwords" step turns it into the `map(string)` JSON `TF_VAR_local_admin_passwords` wants (keyed `all_apps`/`vm_apps`) via `jq -nc --arg`, reading the value from an env var rather than interpolating it into a shell command string, so it never lands in a logged command line.

`ops_api_base_url` is no longer a repo secret: it's a known lab hostname (`https://vcf-lab-operations.int.sentania.net`), set as a plain `TF_VAR_ops_api_base_url` workflow env in `plan-and-apply`'s job-level env block.

No other secrets should be referenced anywhere in the workflow. In particular `VCF_LAB_SYSTEM_ADMIN_USERNAME`, `VCF_LAB_SYSTEM_ADMIN_PASSWORD`, `VCF_OPS_API_TOKEN`, `VCF_OPS_SSO_REALM_ID`, `VCF_LAB_EXTERNAL_CIDR`, `VCF_LAB_ORG_LOCAL_ADMIN_PASSWORDS`, and (as of the vIDB token exchange switch) `VCF_LAB_OPS_USER` / `VCF_LAB_OPS_PASSWORD` are gone: superseded by `vcfa_api_token`, the vIDB token exchange step, the committed `sso_realm_id` / `external_cidr` values, `VCFA_FIRST_USER_DEFAULT_PASSWORD`, and `VCF_LAB_API_TOKEN` respectively.

## Dry run before merge

Merging to `main` triggers `plan-and-apply` with `-auto-approve` against the real lab; there's no separate deploy step. `workflow_dispatch` now runs the same credentialed job as a **plan-only dry run by default** (an `apply` boolean input, default `false`): init + plan against real credentials, plan printed to the log, nothing applied. Set `apply: true` on the manual run to also apply. `push` to `main` keeps applying unconditionally, unaffected by the new input. This matters concretely for this repo: the items in "Pre-apply checklist" above are still genuinely open. A plan-only dry run is how those get caught before a half-built region, instead of the first real plan being the one that's already applying.

## Phased apply

`var.enable_orgs` (`variables.tf`, gated through `local.effective_orgs` in `locals.tf`) lets Scott apply this repo in two phases instead of all at once:

- **Phase 1** (`enable_orgs = false`): region, external IP space, and provider gateway only. No orgs, no org networking, no region quotas, no OIDC/OAuth client minting. Already applied on `main`. (Historical: phase 1 also built the content library, back when it was a resource in this root; the content library is now `content/`'s own stage, unaffected by this flag, see "Content is its own stage" above.)
- **Phase 2** (`enable_orgs = true`, the current committed value in `envs/lab.tfvars`): everything in phase 1, plus `module.orgs`, break-glass local admin users, `module.org_networking`, `vcfa_org_region_quota`, and the OAuth app mint/rotate resources, for every org in `var.orgs`. Merging the `feat/local-admin-break-glass` PR that set this flag to `true` **is** the phase-2 apply, on Scott's explicit go given during that PR's development, not a future separate commit.

`var.orgs` itself is never emptied or hand-edited to move between phases: the full org config stays committed and ready in `envs/lab.tfvars`, and `enable_orgs` alone decides whether it gets built.

**Known watch item for this phase-2 apply**: post-phase-1 verification found the new `172.18.0.0/16` external IP block (see "External CIDR" above) is not yet attached to the Default VPC Connectivity Profile in NSX. If org networking fails on external connectivity during the phase-2 apply, that non-attachment is the first suspect. This is an NSX-side fix, out of scope for this repo and this session: do not attempt to attach it from here.

Security posture unchanged: `lint`'s fork-gating on `pull_request` is untouched, no secrets are ever exposed on `pull_request` events, no plan file is ever uploaded as a workflow artifact (including the new plan-only path), and the unconditional workspace cleanup step still runs after the credentialed job regardless of outcome.

## `terraform init -migrate-state`

The previous workflow used `terraform init -migrate-state -input=false` for `plan-and-apply`. `-migrate-state` is for migrating between backend *configurations* (e.g. changing `backend.tf`'s bucket or key) and reusing existing remote state under the new config; it isn't the right flag for this repo's very first apply, where the remote state object doesn't exist yet. It's not simply a harmless no-op either: it's a signal that doesn't match what's happening here. Changed to a plain `terraform init -input=false`, which still creates the state object on first run and is the correct flag going forward (revisit only if `backend.tf` itself changes).

## License

MIT
