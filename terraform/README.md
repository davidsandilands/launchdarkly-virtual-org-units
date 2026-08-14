# Terraform

Split by **who applies it**, not by resource type. That split is the whole
demonstration: stage 10 runs with a credential holding exactly one role and is
structurally unable to do what stage 00 does.

| | Applied by | Identity | Frequency |
| --- | --- | --- | --- |
| `00-platform/` | platform team | org admin | once, plus when the catalogue changes |
| `10-unit/` | the delegated unit | its own `<unit>-unit-admin` service token | every time the unit onboards anything |

Running stage 10 with the admin token makes the exercise meaningless — everything
succeeds, including what is meant to fail.

## Modules

**`modules/unit-role-catalogue`** — the three roles for one unit. Applied once per
unit by the platform team. The unit never applies this and its admin role has no
`createRole`.

**`modules/unit-onboarding`** — project, environments, both teams, and role
assignment with the role attribute set. This is the unit's self-service surface.
Note that it creates no roles: it *assigns* two that already exist.

## Things in here that will bite you

These are not hypothetical. Every one of them either bit during live verification
or was the reason a design decision went the way it did. See
[../docs/06-verification-results.md](../docs/06-verification-results.md).

**Role attributes may be silently unavailable.** `launchdarkly_team.role_attributes`
applies without error, records the value in state, and the API may store nothing.
The result is a role that resolves to zero projects while everything reports
success. `scoping_mode` defaults to `"namespace"` for this reason, and
`set_role_attributes` defaults to false. Verify with `../tests/boundary-tests.sh` §9,
which reads back the resolved project count.

**Create and update need different permissions.** The unit-admin role must hold
`updateTeamDescription` and `updateTeamRoleAttributes`, not just `createTeam` and
`updateTeamCustomRoles`. Team creation carries those fields in its own request body,
so a role missing them creates teams fine and then 403s on the next apply.


**`base_permissions` defaults to `reader`.** Not `no_access`. From the provider:

> "While newer API versions default to `no_access`, this field defaults to
> `reader` in keeping with previous API versions."

`reader` grants read on every project in the account, permissions are additive with
the more permissive winning, and the `deny viewProject` guard does not cancel it.
All three roles set `no_access` explicitly. Never omit it. The same default applies
to `launchdarkly_team_member.role`.

**Role attributes need `$$`.** In HCL, write `$${roleAttribute/project}` — `$$`
escapes Terraform's own interpolation so the literal `${roleAttribute/project}`
reaches the API. Write it with a single `$` and Terraform tries to resolve a
variable called `roleAttribute`. Copy the HCL form into the UI and you get a role
scoped to a project literally named `$${roleAttribute/project}`, which matches
nothing and fails silently. `policies/*.json` carries the single-`$` form for that
reason.

**`launchdarkly_project.environments` is authoritative.** It is a required map, and
an environment absent from it is **deleted on apply**, taking its SDK keys and all
flag targeting with it. Changing an environment's map key destroys and recreates
that environment — irreversible.

**`custom_roles` on an access token takes role keys.** Despite the field
description saying "custom role IDs". `launchdarkly_custom_role.id` is the key
anyway, so either reads correctly.

**Terraform is destructive.** `allow_destructive_actions` defaults to `false`, so
the unit's own credential cannot delete projects, environments or teams at all. A
bad merge that removes a resource block then fails at apply rather than deleting a
production project. `archive_flags_on_destroy = true` is set on both providers as a
second layer.

**Team membership has one authority.** If SCIM or IdP-managed team sync populates
a team, do not also manage `member_ids` in Terraform — they will overwrite each
other on every apply. Leave `lead_member_emails` and `developer_member_emails`
empty when an identity provider owns membership. `launchdarkly_team_role_mapping`
exists for exactly this case: it manages role attachment separately from the team,
so Terraform can own the roles while the IdP owns the members.

## Validation without an account

Both stages validate with no credentials:

```sh
cd 00-platform && terraform init && terraform validate
cd ../10-unit  && terraform init && terraform validate
terraform fmt -recursive -check
```

`validate` checks syntax, types and references. It does **not** check action names
or resource specifiers — those are opaque strings until the API sees them. Action
names here were verified against the LaunchDarkly role actions reference by hand;
`../tests/boundary-tests.sh` is what confirms the policies behave as intended.

## Escape hatches for the demo

`project_key_override` on stage 10 bypasses the derived `<unit>-<product>` project
key so you can watch the API refuse an out-of-namespace creation:

```sh
LAUNCHDARKLY_ACCESS_TOKEN=$LD_UNIT_TOKEN \
  terraform apply -var 'project_key_override=brand-y-sneaky'
```

Terraform's own precondition catches it locally first, with an explanation. That is
a convenience, not the control — the control is the `createProject` resource
specifier, and the way to see it is the raw `curl` in step 4 of
[../docs/05-demo-walkthrough.md](../docs/05-demo-walkthrough.md).

## State

Local state, no backend configured — this is a demo. Stage 00 writes service
tokens into state in plaintext. For anything real, configure a remote backend with
encryption, or set `create_unit_service_tokens = false` and create the tokens in
the UI against the same role.
