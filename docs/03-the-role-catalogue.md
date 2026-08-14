# The role catalogue

Three roles per unit. Deliberately few: a starting catalogue should be the
smallest set that expresses a real hierarchy, extended only on demonstrated need.
Every role in the catalogue is authored by the platform team, and the unit assigns
them without being able to change them.

| Role | Scoped by | Can create projects/teams | Production targeting |
| --- | --- | --- | --- |
| `brand-x-unit-admin` | namespace glob | yes, inside `brand-x-*` | no flag permissions at all |
| `brand-x-lead-developer` | namespace glob | no | yes |
| `brand-x-developer` | namespace glob | no | request only |

Terraform: `terraform/modules/unit-role-catalogue/main.tf`.
Rendered JSON: `policies/`.

## How the developer roles are scoped

The requirement is that the platform team must not have to author a new pair of
roles every time the unit creates a project — that would reintroduce exactly the
ticket queue this pattern exists to remove. There are two ways to satisfy it, and
the choice is `scoping_mode` on the role catalogue.

### `namespace` — the default, and the verified one

The developer roles name the unit's glob directly, `proj/brand-x-*`. One authored
role covers every project in the unit, including ones that do not exist yet. No
per-assignment configuration, therefore nothing that can be misconfigured or
silently dropped.

**Trade-off, stated plainly:** a `brand-x` developer can act on *every* `brand-x`
project, not only the one their team owns. There is no isolation between projects
inside a unit. The unit is the boundary; the project is not.

For most delegated-administration cases that is the right answer — the reason you
wanted the boundary was to separate the unit from the rest of the organisation,
not to police teams within it. If you do need per-project isolation, use the other
mode.

### `role_attribute` — per-project isolation, requires account support

The roles name `proj/${roleAttribute/project}`, a parameter supplied when the role
is assigned to a team:

```
authored once, by the platform team:
    proj/${roleAttribute/project}

assigned by the unit, per team:
    brand-x-checkout-devs   →   project = brand-x-checkout
    brand-x-search-devs     →   project = brand-x-search
```

> **Confirm this works in your account before relying on it.** On the account this
> repository was verified against, role attributes were not available and failed
> *silently*: `POST /teams` accepted the field and discarded it, the
> `updateRoleAttribute` instruction returned `200` without persisting, and
> `roleAttributes` was absent from the member schema entirely. Terraform reported
> success while both teams' roles resolved to **zero projects** — a delegation that
> looked correct in the UI and granted nobody anything. Full detail in
> [06-verification-results.md](06-verification-results.md).

This mode is also where the design is most exposed even when it does work, because
**nothing constrains which values a unit may supply.** That is what the guard is
for.

Whichever mode you choose, verify it with `tests/boundary-tests.sh` §9, which asks
LaunchDarkly what a deployed team's role actually resolves to. A non-zero project
count is the only proof that assignment took effect.

## The guard

Every role in the catalogue ends with the same statement:

```json
{
  "effect": "deny",
  "actions": ["viewProject"],
  "notResources": ["proj/brand-x-*"]
}
```

Read it as: *deny the ability to see any project that is not in this unit's
namespace.*

In `role_attribute` mode this is load-bearing. Assign `brand-x-developer` to a team
with `project = brand-y-payments` and the policy resolves to an allow on
`proj/brand-y-payments` — followed by this deny, which overrides it. Since
`viewProject` gates everything else, the net grant is nothing. Verified: a policy
resolved against another unit's project granted neither read nor write.

In `namespace` mode there is no attribute to get wrong, so the guard is
belt-and-braces: it survives someone later widening a resource specifier above
without re-reading the whole policy. Keep it — it costs nothing and it is the
statement that makes the role safe to copy as a template.

The documentation is explicit on the precedence: *"If a statement within a policy
explicitly denies access to a resource and action, access is denied. This
statement overrides any other statement in the policy that allows access."*
Statement order does not matter.

So the misassignment is not blocked — it is **inert**. Terraform will apply, the
UI will show the role attached, and the affected developers will simply have no
access. That is a deliberate property and it has a cost: the failure is silent.
Nobody gets an error telling them they did something wrong. Audit
role-attachment events if you want to *notice* the mistake as well as survive it.

**The critical limit.** This works only within a single policy. Across roles,
LaunchDarkly permissions are additive and the more permissive wins: *"if a member
has one role that allows access to a resource, and another role that restricts
access to a resource, the member is allowed access."* So the guard cannot defend
against a *different, broader* role being attached to the same team. It protects
against a wrong **attribute value**; it does not protect against a wrong **role**.
That case is a process control, and [04](04-enforced-vs-process.md) covers it.

## `base_permissions` must be `no_access`

The quietest way to lose the entire boundary.

Base permissions are a field on the role, separate from its policy statements. Set
to `reader`, a role grants read access to **every project in the account** — and
because permissions combine additively, the careful namespace scoping in the
policy becomes irrelevant. The `deny viewProject` guard does not save you either:
that deny overrides allows *within the same policy*, and base permissions are not
a statement in it.

The trap is that the Terraform provider defaults this field to `reader`:

> `base_permissions` — "The base permission level - either `reader` or
> `no_access`. While newer API versions default to `no_access`, this field
> defaults to `reader` in keeping with previous API versions."

Omit one line of HCL and every role in the catalogue can read every project in the
account. All three roles set it explicitly, and
`tests/boundary-tests.sh` section 1 asserts it on each.

## Members must be `no_access` too

The same trap one level up, and the one more likely to catch you out, because it
happens in the invite flow rather than in reviewed Terraform.

`launchdarkly_team_member.role` also defaults to **`reader`**. A member left at
`reader` can read **every project in the account**, regardless of which catalogue
roles they hold, because base role and custom roles combine additively and the more
permissive wins. The deny guard does not help — it overrides allows within its own
policy, and a base role is not a statement in it.

Verified against the live account: a plain `reader` identity listed all 7 projects
including the other unit's, returning `200` on `brand-y-payments` — the same
project the delegated unit token is refused with `403`.

So every member of a unit team must be created with `no_access`:

```hcl
resource "launchdarkly_team_member" "developer" {
  email = "someone@example.com"
  role  = "no_access" # never omit — the provider default is reader
}
```

```sh
curl -X POST https://app.launchdarkly.com/api/v2/members \
  -H "Authorization: $LD_ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '[{"email":"someone@example.com","role":"no_access"}]'
```

Two notes on this:

- **The provider's own docs are inconsistent here.** The `launchdarkly_team_member`
  *resource* documents `reader`, `writer`, `no_access`, `admin` — so `no_access` is
  settable. The matching *data source* documents only `owner`, `reader`, `writer`,
  `admin`. Trust the resource; `no_access` works.
- **If SCIM or an identity provider creates your members**, this becomes a mapping
  question rather than a Terraform one. Confirm what base role provisioned users
  land on before relying on any isolation claim in this repository.

`tests/boundary-tests.sh` §10 checks every member of a `brand-x-*` team and names
any that hold more than `no_access`.

## 1. Unit admin

The delegated administrator, and the identity the unit's own pipeline
authenticates as.

| Grants | On |
| --- | --- |
| `createProject`, `viewProject`, `updateProjectName`, `updateTags` | `proj/brand-x-*` |
| `createEnvironment`, `updateName`, `updateColor`, `updateTtl`, `updateTags`, `updateApprovalSettings`, `updateRequireComments`, `updateConfirmChanges`, `updateCritical`, `viewSdkKey` | `proj/brand-x-*:env/*` |
| `createTeam`, `viewTeam`, `updateTeamName`, `updateTeamMembers`, `updateTeamCustomRoles` | `team/brand-x-*` |

Note what this role does **not** have: any flag permission whatsoever. The unit
administrator can create the project and hand out access to it, and cannot change
what customers receive. Administration and delivery are separate concerns and
there is no reason to fuse them.

Also absent, and more important:

- **`createRole` and `updatePolicy`.** Role authoring is not delegated at all. See
  [04](04-enforced-vs-process.md) for why scoping `createRole` to a key namespace
  does not help.
- **`deleteProject`, `deleteEnvironment`, `deleteTeam`** — off by default, behind
  `allow_destructive_actions`. Terraform is declarative and therefore
  destructive: remove a resource block, change a project key, run a stray
  `destroy`, and it will attempt deletion. Withholding delete means the platform
  team is the last line of defence against a bad merge. Turning it on is
  reasonable once the unit's pipeline is trusted; it should be a decision, not a
  default.
- **`createAccessToken`** — off by default, behind `allow_token_minting`. Safe
  with respect to the namespace, since a token cannot exceed its creator, but it
  is a rotation commitment. See [04](04-enforced-vs-process.md).

`updateTeamCustomRoles` is the widest capability granted here, and the one to
understand before deploying this. It is what lets the unit attach roles to its own
teams without platform-team involvement — the whole point — and it is also the
escalation path in [04](04-enforced-vs-process.md).

## 2. Lead developer

Full flag and segment lifecycle across every environment, including production:
create and delete flags, change targeting, manage segments, and review and apply
approval requests.

Attached to the `<unit>-<product>-leads` team. Scope is every `brand-x-*` project
in `namespace` mode, or the single project named by the role attribute in
`role_attribute` mode.

## 3. Developer

The same scope, with production held back.

| | `development` | `production` |
| --- | --- | --- |
| Create flags, edit name/description/variations | yes | yes (flag config is not per-environment) |
| Change targeting — `updateOn`, `updateRules`, `updateTargets`, `updateFallthrough` | yes | **no** |
| Approval requests | n/a | may `createApprovalRequest`, may not review or apply |
| Segments | yes | no |

A developer can therefore build a flag, exercise it fully in development, and
raise a request to change production — which a lead developer holds the
permission to apply. That is a working two-tier hierarchy inside the unit, with
nothing authored per team.

The production restriction is expressed twice, which is deliberate. The targeting
allow is scoped to `env/development`, so production is already denied by default.
Then there is an explicit deny on `env/production`:

```json
{
  "effect": "deny",
  "actions": ["updateOn", "updateTargets", "updateRules", "updateFallthrough", "..."],
  "resources": ["proj/brand-x-*:env/production:flag/*"]
}
```

Strictly redundant today. It is there because it survives someone later widening
the allow from `env/development` to `env/*` without re-reading the whole policy —
and because it demonstrates deny-overriding-allow on something mundane and easy to
test, rather than only in the abstract guard at the bottom of the file.
`tests/boundary-tests.sh` section 7 exercises it: toggle in development succeeds,
toggle in production is refused, in the same project with the same role.

## Environments as a convention

The developer role names `env/development` literally. That only works because the
unit runs the same environment set in every project — which is a convention the
unit controls, and is what `terraform/modules/unit-onboarding` enforces by
creating both environments itself.

If units need per-project environment sets, either standardise the environment keys
across the unit — much simpler, and it is a convention you control — or add an
environment role attribute in `role_attribute` mode. Each additional attribute is
another free-form value at assignment time for the guard to absorb, and another
thing that fails silently if role attributes are unavailable.

## What the unit admin needs to manage its own teams

Worth calling out because getting it wrong fails late. The unit-admin role holds
`createTeam`, `viewTeam`, `updateTeamName`, `updateTeamDescription`,
`updateTeamMembers`, `updateTeamCustomRoles` and `updateTeamRoleAttributes`.

The last three matter for a specific reason: team *creation* carries description,
members, roles and role attributes in its own request body, so a role missing
`updateTeamDescription` or `updateTeamRoleAttributes` will create teams
successfully and then **403 on the first update**. The delegation appears to work
until the unit changes something it already owns. This is exactly what happened
during verification — see [06-verification-results.md](06-verification-results.md),
Defect 2.

The general lesson for any action you delegate: check whether the create path and
the update path need the same permission. They often do not.

## Read next

- [04-enforced-vs-process.md](04-enforced-vs-process.md) — where this stops being enforcement
