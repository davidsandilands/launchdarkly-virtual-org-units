# Verification results

Verified 14 August 2026 against a live LaunchDarkly account, applying both
Terraform stages for real and driving the REST API directly. Terraform provider
3.1.3, Terraform 1.5.7.

Final state: **26 assertions, 26 passed, 0 failed, 0 skipped.**

The run found three defects and two behaviours worth knowing. All three defects
are fixed in this repository. This document exists so nobody has to rediscover
them.

## Verified as enforced by the platform

Each of these was exercised against the live API, not inferred from documentation.

| Claim | Evidence | Test |
| --- | --- | --- |
| Creation is confined to the key namespace | `POST /projects` with an out-of-namespace key → **403**; in-namespace key → **201** | §2 |
| Same for teams | out-of-namespace `POST /teams` → **403**; in-namespace → **201** | §3 |
| Everything unnamed is denied by default | unit token's `GET /projects` returned only its own; four unrelated pre-existing projects invisible; direct read of the other unit's project → **403**; flag write into it → **403** | §4 |
| Role authoring can be withheld | `POST /roles` as the unit → **403** | §5 |
| Deny overrides allow within one policy | policy resolved against another unit's project granted neither read nor write (**403** both) | §6 |
| Environment-scoped targeting holds | same role, same project: toggle in `development` → **200**, in `production` → **403** | §7 |
| A token cannot exceed its creator | unit-minted token requesting `admin` could not read outside the namespace (**403**) or create outside it (**403**) | §8 |
| Delegated token minting stays usable | in-namespace downstream token worked (**200**) | §8 |
| `base_permissions` writes through correctly | all three roles stored `no_access` | §1 |
| Role-attribute escaping is correct | stored policy contains exactly `proj/${roleAttribute/project}` — the `$$` HCL escape survives | manual |
| The deployed assignment resolves | both teams' attached roles resolve to real projects | §9 |

The `deny viewProject` / `notResources` guard behaves exactly as designed, and
`viewProject` does gate everything else: a policy with an explicit allow on flag
actions and a deny on `viewProject` grants nothing at all.

## Defect 1 — role attributes silently did nothing

**The most important finding.** The original design scoped the developer roles by
role attribute (`proj/${roleAttribute/project}`) and supplied the project per team
at assignment time. On this account that mechanism does not work, and it fails
**silently in both directions**:

| Attempt | Result |
| --- | --- |
| `POST /teams` with `roleAttributes` | **201** — field accepted and discarded |
| Terraform `launchdarkly_team.role_attributes` | apply succeeded, state recorded the value |
| `GET /teams/{key}?expand=roles` | `roleAttributes: null` |
| semantic patch `updateRoleAttribute` | **200** — and still not persisted |
| semantic patch `replaceRoleAttributes` | **400** `unknown field "roleAttributes"` |
| `roleAttributes` on the member schema | key **absent entirely** (`has("roleAttributes")` false) |

Tried with an owner token and the delegated token, and with
`LD-API-Version` unset, `20240415`, and `beta`. Same outcome every time. The field
being wholly absent from the member schema is the strongest signal: this is not a
syntax problem, the capability is not present on the account.

The consequence was severe and quiet. Both real teams had a role attached that
resolved to **zero projects**. Terraform reported success, the UI showed the role
attached, and any member of those teams would have had no access at all. The
first live run passed every assertion in sections 1–8 while this was true,
because those sections test policies via tokens carrying an *inline* policy —
proving the mechanism while never touching the deployed assignment.

**Fixed** by adding `scoping_mode` to the role catalogue:

- **`"namespace"` (new default, verified working)** — the developer roles name the
  unit's glob directly, `proj/brand-x-*`. One authored role still covers every
  project the unit will ever create, so the standing-delegation property is
  retained. **Trade-off:** a developer can act on every project in the unit, not
  only the one their team owns. The unit is the boundary; the project is not.
- **`"role_attribute"`** — the original behaviour, for accounts that have the
  feature. `set_role_attributes` gates writing the value and defaults to false.

**Also fixed:** added §9 to the test suite, which asks LaunchDarkly what a
deployed team's attached role actually resolves to. That assertion is what would
have caught this on the first run. Any design that depends on assignment-time
configuration needs a test that reads back the deployed state, not a simulation.

Confirm role attributes exist in your account before choosing
`scoping_mode = "role_attribute"`.

## Defect 2 — the unit could create teams but not update them

The unit-admin role held `createTeam`, `viewTeam`, `updateTeamName`,
`updateTeamMembers` and `updateTeamCustomRoles`. The first apply succeeded. The
second apply failed:

```
Error: failed to update team "brand-x-checkout-devs"
403 Forbidden: {"code":"forbidden","message":"Access to the requested resource was denied"}
```

Two actions were missing: **`updateTeamDescription`** and
**`updateTeamRoleAttributes`**. Team *creation* carries description and role
attributes in its own request body, so create works without them; only updates
fail.

That is a genuinely nasty failure mode for delegated administration — the
delegation appears to work, and breaks the first time the unit changes something
it already owns. Worth checking for on every action you grant: does the create
path and the update path need the same permission?

**Fixed:** both actions added to the unit-admin role and to
`policies/brand-x-unit-admin.json`.

## Defect 3 — the suite could pass while the deployment was broken

Covered above, and worth stating on its own because it is the methodological
lesson. Sections 6 and 7 verify policy behaviour using tokens with inline
policies. That is a legitimate technique — it is the only way to observe a
resolved policy without a second account member — but it tests the *mechanism*,
not the *deployment*. A suite built entirely from simulations can be fully green
against a system that grants nobody anything.

**Fixed:** §9 reads back deployed state and asserts a non-zero resolved project
count.

## Behaviour 1 — token capping is real but invisible in metadata

`POST /tokens` as the unit requesting `{"role": "admin"}` returns **201**, and
reading the token back reports `role: "admin"`. It is not actually an admin token:

```
stated role:  admin
effective:    GET /projects/brand-y-payments  -> 403
effective:    GET /projects                   -> 1 project visible
```

Capping is enforced on the permissions, not on the request, and not on the
metadata. This cuts both ways. Reassuring: delegating `createAccessToken` cannot
widen the boundary, whatever the unit asks for. Concerning: **a token inventory
will show an `admin` service token that is not one.** Anyone auditing token
creation events or listing tokens by role will read this wrong. Do not treat the
`role` field on a token as evidence of effective permission.

## Behaviour 2 — `check` blocks warn, they do not block

Terraform `check` blocks in stage 00 validate that the acting and other unit keys
are declared and distinct. They passed, so this was not exercised in anger, but
worth restating: `check` produces a **warning**, not an error. A misconfiguration
there will not stop an apply.

## Not verified

Stated plainly rather than left to inference.

- **Observing a real member's session under a misassigned role.** The account has
  one member, an owner, whose base role grants everything regardless, and access
  tokens cannot carry role attributes. §6 proves the policy mechanism; it does not
  watch a human hit the wall. Step 8 of
  [05-demo-walkthrough.md](05-demo-walkthrough.md) is still a manual step.
- **Attaching a broader role to a unit team.** Not enforceable, so not tested —
  see [04-enforced-vs-process.md](04-enforced-vs-process.md). Permissions across
  roles are additive and the more permissive wins, so the in-role guard cannot
  help here. Catalogue discipline plus audit alerting, i.e. detection rather than
  prevention.
- **Role attributes end to end**, for the reason in Defect 1.
- **SSO, SCIM and IdP team sync.** No identity provider in the test account.
- **`allow_destructive_actions = true`.** Left off; the delete actions were never
  granted, so their scoping is unverified.

## Reproducing

```sh
cd terraform/00-platform && terraform apply
export LD_UNIT_TOKEN=$(terraform output -json unit_automation_tokens | jq -r '."brand-x"')
cd ../10-unit && LAUNCHDARKLY_ACCESS_TOKEN=$LD_UNIT_TOKEN terraform apply
cd ../../tests && ./boundary-tests.sh
```

The suite needs `LD_ADMIN_TOKEN` and `LD_UNIT_TOKEN`, either exported or placed in
a gitignored `tests/.env`. It refuses to run if the two are identical, because
every assertion would then pass for the wrong reason.
