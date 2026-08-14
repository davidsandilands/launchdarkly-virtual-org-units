# Rendered policies

The three `brand-x` policies exactly as the Terraform module renders them with
default variables. They exist so you can read the policy without reading HCL, paste
one into the advanced editor in the LaunchDarkly UI, or `POST` one to the API.

The Terraform in `../terraform` is the source of truth. If you change one, change
both.

| File | Scoping |
| --- | --- |
| `brand-x-unit-admin.json` | namespace glob — always, this role is not parameterised |
| `brand-x-lead-developer.json` | `proj/${roleAttribute/project}` (`scoping_mode = "role_attribute"`, the default) |
| `brand-x-developer.json` | `proj/${roleAttribute/project}` |
| `variant-namespace-scoped-brand-x-lead-developer.json` | `proj/brand-x-*` |
| `variant-namespace-scoped-brand-x-developer.json` | `proj/brand-x-*` |

The two developer roles are **parameterised by default**: they name a role attribute
rather than a project, and the project is supplied per team when the role is
assigned. That is what lets one authored role serve every project the unit creates
while still confining each team to its own.

It is also why the `deny viewProject` guard at the bottom of each policy is the
central control rather than a nicety. Nothing constrains which value a unit admin
enters, so the guard is what makes a wrong one harmless — see the reading order
below.

The `variant-namespace-scoped-*` files are the fallback: the same policies with the
project scope replaced by the unit's key glob. Use them when role attributes are not
available in your account, accepting that a developer then reaches every project in
the unit. **On the account this repository was verified against, role attributes were
silently discarded** and the parameterised roles resolved to zero projects. See
[../docs/06-verification-results.md](../docs/06-verification-results.md).

## Two differences from the HCL

**Escaping.** In HCL the role attribute is written `$${roleAttribute/project}`,
because `$$` escapes Terraform's own interpolation. In raw JSON — and in the UI —
it is written `${roleAttribute/project}`. That is what appears in the variant files.
Copy the HCL form into the UI and you will create a role scoped to a project
literally named `$${roleAttribute/project}`, which will match nothing and fail
silently. (Verified: the escaping in the Terraform is correct — the stored policy
contains exactly `proj/${roleAttribute/project}`.)

**Base permissions are not in here.** A policy document carries statements only.
Base permissions are a separate field on the role, and this is the single most
dangerous default in the whole exercise:

| Where you create the role | Default base permission |
| --- | --- |
| Terraform (`launchdarkly_custom_role`) | **`reader`** |
| Newer REST API versions | `no_access` |
| UI | shown in the form; check it |

`reader` grants read access to **every project in the account**, and permissions
combine additively with the more permissive winning. A role built from
`brand-x-unit-admin.json` with base permissions left at `reader` can read every
`brand-y` project, and the `deny viewProject` statement will not save you —
that deny only overrides allows *within the same policy*, and base permissions
are not a statement in it.

Whenever you create these roles by hand, set base permissions to **No access**.
The Terraform sets `base_permissions = "no_access"` explicitly for this reason.
`tests/boundary-tests.sh` asserts it on every role in the catalogue.

## Creating a role from one of these files

```sh
curl -sS -X POST https://app.launchdarkly.com/api/v2/roles \
  -H "Authorization: $LD_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n \
        --arg key  'brand-x-developer' \
        --arg name 'Brand X :: developer' \
        --slurpfile policy brand-x-developer.json \
        '{key: $key, name: $name, basePermissions: "no_access", policy: $policy[0]}')"
```

Note `basePermissions: "no_access"` in the request body. Omitting it on an older
API version gets you `reader`.

## Which statement is doing the work

Read the policies in this order:

1. `brand-x-unit-admin.json` — the `createProject` statement on `proj/brand-x-*`
   is the only enforced creation boundary in the design. Everything else follows
   from it. Note `updateTeamDescription` and `updateTeamRoleAttributes` in the team
   statement: without them the unit can create teams but gets a 403 on the first
   *update*, so the delegation breaks later rather than immediately.
2. `brand-x-developer.json` — read the last two statements together. The final
   `deny viewProject` on `notResources: ["proj/brand-x-*"]` is **the guard**, and in
   the default parameterised mode it is load-bearing: the resource above it is a
   free-form value someone types at assignment time, and this is the only thing
   standing between a mistyped project key and access to another unit's data.

   Note what it does and does not do. A unit admin who enters `brand-y-payments`
   gets **no error** — the assignment saves, and then grants nothing, because the
   allow resolves and this deny overrides it within the same policy. Inert, not
   blocked. The production `deny` just above is the same mechanism used for a
   mundane purpose, so you can see it working somewhere less abstract.
3. `brand-x-lead-developer.json` — the same shape as the developer, minus the
   production restriction. Mostly here to show that a unit can run an internal
   hierarchy without the platform team authoring anything per team.

Notice what is absent from all three: the string `brand-y`. The other unit is not
on a deny list. It is simply never named, and therefore denied by default. A deny
list would need updating every time the other unit created something.
