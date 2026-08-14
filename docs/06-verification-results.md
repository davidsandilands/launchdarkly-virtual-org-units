# Verification results

Verified 14 August 2026 against a live LaunchDarkly account, applying both
Terraform stages for real and driving the REST API directly. Terraform provider
3.1.3, Terraform 1.5.7.

Final state on the verification account: **27 passed, 0 failed, 1 skipped** across 11
sections. The skip is §11, which needs role attributes — see Defect 1 and the
re-probe below.

The runs found **four defects and three behaviours** worth knowing. All four defects
are fixed in this repository. This document exists so nobody has to rediscover them.

> **On the default scoping mode.** The repository ships
> `scoping_mode = "role_attribute"`, because parameterised roles are the correct
> pattern and the deny guard exists precisely to make them safe. Role attributes do
> **not** work on the account verified here, so its local (gitignored)
> `terraform.tfvars` overrides to `"namespace"`. The committed defaults and the local
> deployment therefore differ on purpose, and that is stated in the tfvars file
> itself rather than left to be discovered.

## Verified as enforced by the platform

Each of these was exercised against the live API, not inferred from documentation.

| Claim | Evidence | Test |
| --- | --- | --- |
| Creation is confined to the key namespace | `POST /projects` with an out-of-namespace key → **403**; in-namespace key → **201** | §2 |
| Same for teams | out-of-namespace `POST /teams` → **403**; in-namespace → **201** | §3 |
| Everything unnamed is denied by default | unit token's `GET /projects` returned only its own; every unrelated pre-existing project invisible; direct read of the other unit's project → **403**; flag write into it → **403** | §4 |
| Role authoring can be withheld | `POST /roles` as the unit → **403** | §5 |
| Deny overrides allow within one policy | policy resolved against another unit's project granted neither read nor write (**403** both) | §6 |
| Environment-scoped targeting holds | same role, same project: toggle in `development` → **200**, in `production` → **403** | §7 |
| A token cannot exceed its creator | unit-minted token requesting `admin` could not read outside the namespace (**403**) or create outside it (**403**) | §8 |
| Delegated token minting stays usable | in-namespace downstream token worked (**200**) | §8 |
| `base_permissions` writes through correctly | all three roles stored `no_access` | §1 |
| A `reader` base role really does see everything | a plain reader identity listed **all 7 projects** in the account, and returned `200` on the other unit's project — which the delegated token is refused with `403` | §10 |
| Unit-team members carry no base access | both unit members hold `no_access`; access comes only from catalogue roles | §10 |
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

Confirm role attributes exist in your account before relying on
`scoping_mode = "role_attribute"`.

### Re-probe, same day, after the default was changed back to `role_attribute`

The default was later flipped back to `role_attribute` on the grounds that it is the
correct pattern and the one the guard exists for. That prompted a proper re-probe,
including the leading hypothesis that LaunchDarkly might discard attribute values
whose key no attached role references — the roles having been namespace-scoped at the
time of the original test.

**Hypothesis disproven. Role attributes do not work on this account, in any path:**

| Attempt (role now genuinely names `${roleAttribute/project}`) | Result |
| --- | --- |
| `POST /teams` with `roleAttributes` | **201** — `roleAttributes: null`, resolves to 0 projects |
| semantic patch `updateRoleAttribute {key, values}` | **200** — still null, still 0 |
| semantic patch `replaceRoleAttributes`, field `roleAttributes` | **400** unknown field |
| ...field `values` / `attributes` / `roleAttribute` | **400** unknown field, all three |
| `PATCH /members/{id}` writing `customRoles` **and** `roleAttributes` together | **200** — `customRoles` persisted, `roleAttributes` silently dropped |

That last row is the clearest evidence: the same request wrote one field and
discarded the other. This is not a request-shape problem.

LaunchDarkly documents no gate beyond Enterprise, and Enterprise custom roles
demonstrably work on this account, so this looks like a product-side gap rather than
a plan limitation. Worth raising with LaunchDarkly before designing a customer
rollout around parameterised roles.

**What §9 and §11 do about it.** §9 asserts the deployed role resolves to exactly one
project in `role_attribute` mode, and it caught this cleanly — two failures naming
the cause. §11, which exercises the guard on the live assignment path, skips with an
explanation rather than passing vacuously. Both behaved correctly, which is the point
of having them.

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

## Defect 4 — Terraform stripped team members added outside it

Found by §10 reporting one fewer member than the previous run. The onboarding module
set:

```hcl
member_ids = try(data.launchdarkly_team_members.developers[0].team_members[*].id, [])
```

With no emails supplied that evaluates to `[]`, which is not "don't manage members" —
it is "this team should have **no** members". So every apply removed anyone added by
hand or by an identity provider. A member added to `brand-x-checkout-devs` in the UI
was silently deleted from the team on the next `terraform apply`.

The irony is that the variable's own documentation warned about exactly this — only
one system should own team membership — while the code enforced the opposite.

Note the contrast that made it obvious: `brand-x-admins`, created in stage 00, kept
its manually-added member, because that resource never sets `member_ids` at all.

**Fixed:** supply `null` rather than `[]` when no emails are given, which leaves the
attribute unmanaged and lets LaunchDarkly keep whatever is there:

```hcl
member_ids = length(var.developer_member_emails) > 0 ? data.launchdarkly_team_members.developers[0].team_members[*].id : null
```

The general lesson for any Terraform provider: for a computed-and-optional collection,
`[]` and `null` mean opposite things. `[]` asserts emptiness; `null` declines to
manage. Reaching for `try(..., [])` to avoid an index error quietly chooses the
destructive one.

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

## Behaviour 2 — a `reader` base role defeats the whole boundary

Worth separating out because it applies to **members**, not roles, and so is
reached through the invite flow rather than through reviewed Terraform.

A plain `reader` identity was able to list every project in the account — all 7,
including the other unit's `brand-y-payments`, which it read with `200` while the
delegated unit token gets `403` on the same project.

Base role and custom roles combine additively and the more permissive wins, so a
member left at `reader` has account-wide read no matter which catalogue roles they
hold. The deny guard cannot cancel it: that guard overrides allows within its own
policy, and a base role is not a statement in it.

`launchdarkly_team_member.role` defaults to `reader`, exactly as
`base_permissions` does on a role. Members of unit teams must be created with
`no_access`.

Note also a documentation inconsistency in the provider: the
`launchdarkly_team_member` *resource* lists `reader`, `writer`, `no_access`,
`admin`, while the matching *data source* lists only `owner`, `reader`, `writer`,
`admin`. The resource is correct — `no_access` is settable and works.

**Covered by §10**, which names any member of a `<unit>-*` team holding more than
`no_access`.

## Behaviour 3 — `check` blocks warn, they do not block

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
