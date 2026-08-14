# Virtual organisational units in LaunchDarkly

**LaunchDarkly has no organisational-unit object.** No sub-accounts, no folders,
no nested tenancy — one flat namespace of projects, teams, roles and members.

But large organisations routinely have more than one group that wants to run its
own corner of the platform: a division, a subsidiary, an acquisition, a brand, a
regional engineering org. They want to create their own projects, stand up their
own teams and onboard their own developers without filing a ticket against a
central platform team every time. The central team wants exactly the same thing,
and also wants a hard guarantee that the new group cannot touch what the existing
one has built.

This repository is a documented, runnable pattern for building that boundary
inside a **single** LaunchDarkly account — and an honest account of where the
boundary is enforced by the platform and where it is only a process control.

It is a worked example with neutral naming (`brand-x`, `brand-y`), not a
customer configuration.

## The idea in one page

The pattern rests on one observation:

> **A resource key prefix is the only thing in LaunchDarkly that constrains
> creation.**

A resource that does not exist yet has no tags, no owner and no attributes to
match a policy against. The only thing it has is the key the caller proposed. So
the boundary is a key prefix, and a role policy scoped to `proj/brand-x-*` means
the API refuses any other key outright.

Three roles per unit, all authored by the platform team, none authored by the
unit:

| Role | Scoped by | Purpose |
| --- | --- | --- |
| `brand-x-unit-admin` | `proj/brand-x-*`, `team/brand-x-*` | creates projects, environments and teams; assigns catalogue roles; holds no flag permissions |
| `brand-x-lead-developer` | `project` role attribute | full flag lifecycle including production |
| `brand-x-developer` | `project` role attribute | full lifecycle in development; request-only in production |

The unit admin is scoped by the key glob. The two developer roles are
**parameterised**: they name `proj/${roleAttribute/project}` and the project is
supplied per team when the role is assigned.

```
authored once, by the platform team:   proj/${roleAttribute/project}

assigned by the unit, per team:        brand-x-checkout-devs → project = brand-x-checkout
                                       brand-x-search-devs   → project = brand-x-search
```

That gives both properties at once: one authored role covers every project the unit
will ever create, **and** each team is confined to the project it owns. Standing
delegation without handing every developer in the unit access to every project in it.

## The guard, and why it is the whole design

Parameterisation creates the risk that makes this pattern interesting. That attribute
value is **free-form text a unit admin types at assignment time.** LaunchDarkly does
not validate it, and RBAC cannot express "must start with `brand-x-`". A unit admin
can attach `brand-x-developer` to their own team with `project = brand-y-payments` —
another unit's production project.

So every role ends with this:

```json
{ "effect": "deny", "actions": ["viewProject"], "notResources": ["proj/brand-x-*"] }
```

What happens on that bad assignment:

1. The allow resolves to `proj/brand-y-payments`.
2. This deny matches, because that project is not in `proj/brand-x-*`.
3. Deny overrides allow **within the same policy**; statement order is irrelevant.
4. `viewProject` gates every other project-scoped permission, so the entire role goes
   inert — not just the read, but every flag and segment action it grants.

Net grant: nothing. Verified against a live account.

**Precisely: the assignment is not blocked, it is made inert.** It saves
successfully, with no error and no warning. Anyone told the guard "prevents" bad
assignments will expect a rejection and will not get one — what they get is a team
that can see nothing at all. A safe failure, but a silent one, so alert on
role-attachment events if you want to notice as well as survive.

If you do not need per-project isolation, `scoping_mode = "namespace"` scopes the
developer roles by the key glob instead. Simpler, one fewer thing to misconfigure,
and the guard drops to belt-and-braces because there is no value to get wrong. It is
also the fallback where role attributes are unavailable —
[which is what happened on the account this was verified against](docs/06-verification-results.md).

## Honest boundaries

| | |
| --- | --- |
| **Enforced by the platform** — all verified live | Creation confined to the key namespace. Deny-by-default invisibility of everything else. Deny overriding allow within a policy. Service tokens capped at their creator and fixed at creation. |
| **Process controls only** | Which roles a unit admin may attach to a unit team. The policy content of any role authored by a holder of `createRole`. Which values are supplied for a role attribute. Sprawl inside the namespace. Per-project isolation within a unit. |

The second column is permanent, not a backlog. Two things follow from it, and both
are worth saying to a security reviewer before they ask:

- **Role authoring is not delegated at all.** Scoping `createRole` to
  `role/brand-x-*` restricts the *label*, not the *contents* — a role named
  `brand-x-innocuous` can grant `proj/*` admin.
- **A unit admin is a trusted role.** This pattern isolates units from mistakes
  and casual overreach. It does not defend against a determined unit admin who
  knows the account layout. If that is in your threat model, use separate
  accounts and accept the loss of shared SSO and cross-unit teams.

Full detail: [docs/04-enforced-vs-process.md](docs/04-enforced-vs-process.md).

## The two traps that void everything

Both are the same mistake at different levels, both default the wrong way, and
either one on its own makes the entire namespace boundary decorative. Neither is
caught by the deny guard, because that guard overrides allows *within its own
policy* and a base role is not a statement in it.

### 1. `base_permissions` on a role defaults to `reader`

In the Terraform provider, omitting `base_permissions` gives the role account-wide
read. Permissions combine additively with the more permissive winning, so a
carefully namespaced policy becomes irrelevant.

Every role here sets `base_permissions = "no_access"` explicitly.
`tests/boundary-tests.sh` §1 asserts it on all three.

### 2. A member's base role also defaults to `reader`

**This is the one people actually get wrong**, because it happens in the invite
flow rather than in reviewed Terraform. `launchdarkly_team_member.role` defaults to
`reader` too, and an account member left at `reader` can read **every project in
the account** — including the other unit's — no matter which catalogue roles they
hold.

Verified directly: a plain `reader` identity listed all 7 projects in the test
account, `brand-y-payments` included, returning `200` on a project the delegated
unit is refused with `403`.

So **every member of a unit team must be created with base role `no_access`** and
draw all of their access from catalogue roles:

```hcl
resource "launchdarkly_team_member" "developer" {
  email = "someone@example.com"
  role  = "no_access" # never omit this — the default is reader
}
```

```sh
# or via the API
curl -X POST https://app.launchdarkly.com/api/v2/members \
  -H "Authorization: $LD_ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '[{"email":"someone@example.com","role":"no_access"}]'
```

`tests/boundary-tests.sh` §10 asserts that every member of a `brand-x-*` team has
base role `no_access`, and tells you which ones do not.

If your identity provider creates members via SCIM, this is a mapping question
rather than a Terraform one: confirm what base role provisioned users land on
before you rely on any of the isolation claims above.

## Layout

```
docs/
  01-the-problem.md          why there is no OU, and why two accounts or tags are not the answer
  02-the-boundary-model.md   why a key prefix; what viewProject really gates; what the prefix cannot do
  03-the-role-catalogue.md   the three roles, how they are scoped, the guard
  04-enforced-vs-process.md  enforced vs process controls, with mitigations
  05-demo-walkthrough.md     ~20 minutes, end to end, with narration beats
  06-verification-results.md what a live run proved, what it broke, what is untested

terraform/
  00-platform/               applied by the PLATFORM TEAM with an org-admin token
  10-unit/                   applied by the UNIT with its own delegated token
  modules/
    unit-role-catalogue/     the three roles for one unit
    unit-onboarding/         project + environments + teams + role assignment

policies/                    the same policies as raw JSON, for the UI or REST API
                             plus variant-role-attribute-* for the other scoping mode
tests/
  boundary-tests.sh          11 sections; most pass by being refused
```

The Terraform is split by **who applies it**, not by resource type. That split is
the demonstration: stage 10 runs with a credential holding one role, and is never
able to do what stage 00 does.

## What the code actually demonstrates

The repository is arranged so that each claim in the docs has something you can
run that proves it. Two identities do all the work: an org-admin token and a
delegated `brand-x-unit-admin` service token that holds exactly one role.

**The delegation works.** These are the "yes it can" half, and they matter as much
as the refusals — a boundary that also blocks legitimate work is just a broken
delegation.

| Run this | You see | Which proves |
| --- | --- | --- |
| `terraform/10-unit` apply, with the *unit* token | project, 2 environments and 2 teams created; output `roles_authored_by_this_stage = []` | a unit can onboard itself with no platform-team involvement and without authoring any role |
| `POST /projects` `{"key":"brand-x-anything"}` as the unit | `201` | the namespace is a boundary, not a general block |
| tests §7 | toggle in `development` → `200` | the developer role grants real, usable access |
| tests §8 | in-namespace downstream token → `200` | delegated token minting stays usable |
| tests §9 | teams' roles resolve to real projects | the assignment actually took effect |

**The boundary holds.** Most of these pass *by being refused*, so read the output
rather than the exit code.

| Run this | You see | Which proves |
| --- | --- | --- |
| `POST /projects` `{"key":"brand-y-sneaky"}` as the unit | `403` | creation is confined to the key prefix — the one primitive that constrains creation |
| `GET /projects` as the unit | only `brand-x-*`; the other unit and every unrelated project absent | deny-by-default invisibility |
| `grep -r brand-y policies/*.json` | no matches | the other unit is *never named*, so this is not a deny-list needing maintenance |
| `POST /roles` as the unit | `403` | role authoring is withheld entirely |
| tests §6 | policy resolved against another unit's project grants nothing | `deny viewProject` overrides allow within a policy, making a misassignment inert |
| tests §7 | toggle in `production` → `403` | environment-scoped permissions, same role, same project |
| tests §8 | unit-minted token requesting `admin` still `403` outside the namespace | a token cannot exceed its creator |

**The traps.** Less common in a demo repo, and arguably the most useful part: the
code also demonstrates the ways this design silently *fails*, each found by the live
run and now guarded by a test or a default.

| The trap | How the code demonstrates it |
| --- | --- |
| `base_permissions` defaults to `reader` in the provider, granting account-wide read and voiding the whole boundary | every role sets `no_access` explicitly; tests §1 asserts it on all three |
| Role attributes can be silently unavailable — roles resolve to zero projects while Terraform reports success | `scoping_mode` defaults to the key glob; tests §9 reads back the resolved project count |
| Create and update need different permissions — teams can be created but not updated | `updateTeamDescription` and `updateTeamRoleAttributes` are in the unit-admin role, with a comment explaining why the first apply passes and the second 403s |
| A test suite of simulations can be green against a system that grants nobody anything | tests §9 exists precisely because §§1–8 once all passed while the deployment was broken |
| Terraform is destructive; a removed block deletes a project | `allow_destructive_actions` defaults to false, `archive_flags_on_destroy = true`, project keys derived not supplied |

What the code deliberately does **not** demonstrate, because it is not enforceable:
restricting which roles a unit admin may attach to its own teams. See
[docs/04-enforced-vs-process.md](docs/04-enforced-vs-process.md).

## Quickstart

Use a demo or innovation account — this creates real resources.

```sh
export LAUNCHDARKLY_ACCESS_TOKEN=api-xxxxxxxxxxxx
export LD_ADMIN_TOKEN=$LAUNCHDARKLY_ACCESS_TOKEN

# 1. Platform team builds the guardrails
cd terraform/00-platform
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply

# 2. Become the unit — one role, nothing else
export LD_UNIT_TOKEN=$(terraform output -json unit_automation_tokens | jq -r '."brand-x"')

# 3. The unit onboards itself. No platform involvement, no role authored.
cd ../10-unit
cp terraform.tfvars.example terraform.tfvars
terraform init && LAUNCHDARKLY_ACCESS_TOKEN=$LD_UNIT_TOKEN terraform apply

# 4. Prove the boundary
cd ../../tests && ./boundary-tests.sh
```

The suite needs `LD_ADMIN_TOKEN` and `LD_UNIT_TOKEN`. Both are exported above, or
put them in a gitignored `tests/.env` to keep them out of your shell history. It
refuses to run if the two are the same value, because every assertion would then
pass for the wrong reason.

Then read [docs/05-demo-walkthrough.md](docs/05-demo-walkthrough.md) for the
version with the failures in it, which is the interesting part.

## Adapting this

- **Rename the units.** `brand-x` is a placeholder. Edit `units` in
  `terraform/00-platform/terraform.tfvars`; a third unit is one more map entry.
- **Add a unit.** One map entry. No module changes.
- **Onboard another product area.** One entry in `products` in
  `terraform/10-unit/terraform.tfvars`, applied by the unit.
- **Change the role catalogue.** `terraform/modules/unit-role-catalogue/main.tf`,
  and keep `policies/*.json` in step. Start from the smallest set that expresses a
  real hierarchy and extend on demonstrated need.
- **Per-project environment sets.** Prefer standardising environment keys across
  the unit — the roles name `env/development` literally, and the key set is a
  convention you control. Only reach for an environment role attribute if you
  genuinely cannot, and note the caveat above about role attribute support.
- **Per-project isolation inside a unit.** Set `scoping_mode = "role_attribute"` on
  the unit, and `set_role_attributes = true` in stage 10. Verify with
  `tests/boundary-tests.sh` §9 before believing it worked.

## Verified against

Applied for real against a live LaunchDarkly account on **14 August 2026**.
Provider **3.1.3**, Terraform **1.5.7**. Final result on that account: **27 passed,
0 failed, 1 skipped** across 11 sections. The skip is §11, which needs role
attributes; see below.

Full results, including the three defects that run exposed and fixed, are in
[docs/06-verification-results.md](docs/06-verification-results.md). The headlines:

- **Role attributes did not work on the test account, and failed silently** — both
  teams' roles resolved to zero projects while Terraform reported success. Default
  scoping changed to the key glob as a result.
- **The unit could create teams but not update them** — `updateTeamDescription` and
  `updateTeamRoleAttributes` were missing, so the first apply succeeded and the
  second returned 403.
- **A test suite built only from simulations passed while the deployment was
  broken** — §9 now reads back what a deployed team's role actually resolves to.
- **Token capping is real but its metadata lies** — a unit-minted token requesting
  `admin` reports `role: "admin"` and has none of the access. Don't audit by that
  field.

Still unverified: observing a real member's session under a misassigned role (the
test account has one member, an owner), role attributes end to end, SSO/SCIM, and
`allow_destructive_actions = true`.

## Licence and status

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

This is an independent worked example, not an official LaunchDarkly product and not
supported by LaunchDarkly. The platform behaviours recorded in
[docs/06-verification-results.md](docs/06-verification-results.md) reflect one
account and provider 3.1.3 at one point in time — some of them may since have
changed. Verify against your own account before relying on any of it; that is what
`tests/boundary-tests.sh` is for.
