# The role catalogue

Three roles per unit. Deliberately few: a starting catalogue should be the
smallest set that expresses a real hierarchy, extended only on demonstrated need.
Every role in the catalogue is authored by the platform team, and the unit assigns
them without being able to change them.

| Role | Scoped by | Can create projects/teams | Production targeting |
| --- | --- | --- | --- |
| `brand-x-unit-admin` | namespace glob | yes, inside `brand-x-*` | no flag permissions at all |
| `brand-x-lead-developer` | `project` role attribute | no | yes |
| `brand-x-developer` | `project` role attribute | no | request only |

Terraform: `terraform/modules/unit-role-catalogue/main.tf`.
Rendered JSON: `policies/`.

## How the developer roles are scoped

The platform team must not have to author a new pair of roles every time the unit
creates a project — that would reintroduce exactly the ticket queue this pattern
exists to remove. `scoping_mode` on the role catalogue picks how that is achieved.

### `role_attribute` — the default

The roles name `proj/${roleAttribute/project}`, a parameter whose value is supplied
when the role is assigned to a team:

```
authored once, by the platform team:
    proj/${roleAttribute/project}

assigned by the unit, per team:
    brand-x-checkout-devs   →   project = brand-x-checkout
    brand-x-search-devs     →   project = brand-x-search
```

One authored role serves every project the unit will ever create, **and** each team
is confined to the project it owns. That combination is the whole point: standing
delegation without giving every developer in the unit access to every project in it.

This is also the mode the deny guard exists for, and the reason the guard is the
central control in this design rather than a detail. The value above is free-form
text a unit admin types at assignment time. LaunchDarkly does not validate it, and
RBAC has no way to require it start with `brand-x-`. Read the next section before
deploying this.

### `namespace` — the fallback

The roles name the unit's glob directly, `proj/brand-x-*`. One fewer moving part,
and nothing to misconfigure at assignment time.

**Trade-off:** a `brand-x` developer can act on *every* `brand-x` project, not only
the one their team owns. There is no isolation between projects inside a unit.

Two reasons to choose it: you genuinely do not need per-project isolation, or role
attributes are not working in your account. In this mode the guard becomes
belt-and-braces rather than load-bearing, because there is no attribute value to get
wrong.

> **Role attributes were not available on the account this repository was verified
> against**, and failed *silently* in every path tried: `POST /teams` accepted the
> field and discarded it, `updateRoleAttribute` returned `200` without persisting,
> `replaceRoleAttributes` returned `400 unknown field` for every documented field
> name, and a `PATCH /members` that successfully wrote `customRoles` dropped
> `roleAttributes` on the same request. Terraform reported success while both teams'
> roles resolved to **zero projects** — a delegation that looked correct in the UI
> and granted nobody anything. Full detail in
> [06-verification-results.md](06-verification-results.md).

Whichever mode you use, verify it with `tests/boundary-tests.sh` §9, which asks
LaunchDarkly what a deployed team's role actually resolves to. In
`role_attribute` mode it must resolve to **exactly one** project. Zero means the
attribute never took effect.

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

**In the default `role_attribute` mode this is the control that makes the whole
design safe to delegate.** Here is the problem it solves.

A unit admin holds `updateTeamCustomRoles` and `updateTeamRoleAttributes` on
`team/brand-x-*`, which is what lets them onboard their own teams without a ticket.
Nothing in LaunchDarkly RBAC can express "the attribute value must start with
`brand-x-`". So a unit admin can attach `brand-x-developer` to one of their teams
with `project = brand-y-payments` — another unit's production project.

What happens then:

1. The allow resolves to `proj/brand-y-payments`. So far this looks like a breach.
2. This deny statement matches, because `brand-y-payments` is not in
   `notResources: ["proj/brand-x-*"]`.
3. Deny overrides allow **within the same policy**, and statement order is
   irrelevant.
4. `viewProject` gates every other project-scoped permission, so with it denied the
   entire role is inert — not just the read, but every flag and segment action it
   grants.

Net effect: nothing. Verified live — a policy resolved against another unit's project
granted neither read nor write.

**Say this part precisely: the assignment is not blocked, it is made inert.** It
saves successfully. There is no error, no warning, and nothing in the UI marks it as
wrong. A customer told the guard "prevents" bad assignments will expect a rejection
and will not get one. What they get is a team whose members can see nothing at all —
which is a safe failure, but a silent one. If you want to *notice* the mistake as
well as survive it, alert on role-attachment and role-attribute events in the audit
log.

The guard is also the reason the mistake is *contained* rather than *catastrophic*.
Compare the alternative: without it, a mistyped attribute value hands a team full
flag lifecycle on another unit's production project, and nothing about the
assignment looks unusual.

**The limit, in both modes.** This holds only within *this* role. Permissions across
roles are additive and the more permissive wins, so the guard cannot defend against
a *different*, broader role being attached to the same team. That case is a process
control — see [04-enforced-vs-process.md](04-enforced-vs-process.md).

In `namespace` mode there is no attribute to get wrong, so the guard is
belt-and-braces: it survives someone later widening a resource specifier above
without re-reading the whole policy. Keep it — it costs nothing and it is the
statement that makes the role safe to copy as a template.

The documentation is explicit on the precedence, in both directions:

- Within one policy: *"If a statement within a policy explicitly denies access to a
  resource and action, access is denied. This statement overrides any other statement
  in the policy that allows access."*
- Across roles: *"if a member has one role that allows access to a resource, and
  another role that restricts access to a resource, the member is allowed access."*

That asymmetry is the whole reason the guard has to live **inside** each catalogue
role rather than in a separate "deny everything else" role. A separate deny role
would be overridden by the very allow it was meant to restrain.

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

Verified against the live account: a plain `reader` identity listed **every project
in the account**, including the other unit's, returning `200` on `brand-y-payments` —
the same project the delegated unit token is refused with `403`.

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

Attached to the `<unit>-<product>-leads` team. Scope is the single project named by
the role attribute — or every `brand-x-*` project in `namespace` mode.

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
