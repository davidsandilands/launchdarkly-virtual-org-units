# What the platform enforces, and what stays a process control

The most useful document here. A delegation design that overstates its own
guarantees is worse than one with known gaps, because the gaps get planned around
and the overstatements get relied upon.

Everything in the "Enforced" section below was exercised against a live account on
14 August 2026. Results by scoping mode, plus the four defects that
run exposed, are in [06-verification-results.md](06-verification-results.md).

## Enforced by LaunchDarkly

These hold regardless of who is careless. They are properties of the platform, not
of your process.

### Creation is confined to the key namespace

`createProject` scoped to `proj/brand-x-*` means a project with a
non-matching key is refused by the API. Same for `createTeam` on `team/brand-x-*`.
This is the only primitive available that constrains creation, and it is real
enforcement.

*Verified by:* `tests/boundary-tests.sh` §2, §3.

### Everything unnamed is denied by default

The other unit's resources are not on a deny list — they are simply never named in
the acting unit's policy, and are therefore invisible: absent from list responses,
refused on direct access. No maintenance, no window of exposure as the other unit
grows.

*Verified by:* `tests/boundary-tests.sh` §4.

### Deny overrides allow within a policy

> "If a statement within a policy explicitly denies access to a resource and
> action, access is denied. This statement overrides any other statement in the
> policy that allows access."

Statement order does not matter. This is what makes the `deny viewProject`
guard work, and it is the only reason parameterised roles are safe to delegate.

*Verified by:* `tests/boundary-tests.sh` §6, §7.

### A service token can never exceed its creator

Token permissions are capped at those of the creating identity and are **fixed at
creation**. If the unit admin role is granted `createAccessToken`, every token the
unit's automation mints for its own pipelines is structurally confined to the
namespace — whatever the unit asks for, whatever it later becomes.

This is the strongest guarantee in the design, and it is worth noticing that it
works in your favour: delegating token creation does not widen the boundary.

**Verified, with a sting.** A token minted by the unit requesting `{"role":
"admin"}` returns `201`, and reading it back reports `role: "admin"`. It is not an
admin token — it could not read outside the namespace or create outside it. Capping
is enforced on the *permissions*, not on the request and not on the metadata.

So a token inventory will show an `admin` service token that is not one. Anyone
auditing by listing tokens, or by watching token-creation events, will read this
wrong. **Do not treat the `role` field on a token as evidence of effective
permission.** Test the token instead.

The flip side is lifecycle. Permissions frozen at creation means a token does not
pick up a later narrowing of its role — you cannot revoke by editing the role, you
have to revoke the token. Combined with the absence of expiry on access tokens,
tokens need owned rotation with a named owner and a schedule. That is why
`allow_token_minting` defaults to `false` in this repository: not because it is
unsafe with respect to the namespace, but because it is an operational commitment.

> Access token expiry and notification has been active product work. Check current
> status before designing around its absence.

## Not enforced — process controls

Each of these is a real gap. For each: why it cannot be closed with RBAC, and what
to do instead.

### 1. The content of a role cannot be constrained

You can scope `createRole` to a key namespace — `role/brand-x-*` — so a unit could
only create roles with matching keys. **This buys you nothing.** Nothing constrains
the policy *inside* the role. A role innocuously named `brand-x-helper` can grant
`proj/*` admin. The key namespace restricts the label, not the contents.

There is no mechanism in LaunchDarkly RBAC to restrict what a policy statement may
contain.

**Mitigation:** do not delegate role authoring at all. The platform team authors
every role, including each unit's admin role. The unit assigns roles and never
writes them. `createRole` and `updatePolicy` are absent from the unit admin policy
in this repository, and `tests/boundary-tests.sh` §5 asserts that a role-creation
attempt is refused.

This is the single most important design decision in the pattern, and it is the
one that costs the unit the most autonomy. Accept it.

### 2. Which roles reach which teams cannot be constrained

`updateTeamCustomRoles` on `team/brand-x-*` lets the unit admin attach **any role
in the account** to their own teams — including an account-admin-equivalent role,
if one exists and they know its key.

RBAC has no way to express "may attach only roles matching `role/brand-x-*`". The
permission is attach-any-role or attach-no-role.

And the guard does not help here, because it only operates within one policy:
permissions across roles are additive and the more permissive wins. A team holding
both `brand-x-developer` (with its deny) and some broad role will get the broad
role's access. The deny in one role cannot cancel an allow in another.

**Mitigation, and it is honestly a weak one:**

- Keep the catalogue small and the set of broad roles in the account smaller.
- Subscribe to the audit log for role-attachment and team-permission changes, and
  alert on any attachment of a role outside the unit's catalogue. Detection, not
  prevention.
- Recognise that a unit admin is a trusted role. This pattern isolates units from
  *mistakes* and from *casual overreach*. It does not defend against a determined
  unit admin who knows the account layout. If your threat model includes that, you
  need separate accounts and should accept the costs in
  [01-the-problem.md](01-the-problem.md).

Say this part out loud when presenting the design. It is the question a good
security reviewer will ask second, right after they ask about creation.

### 3. Role attribute values are free-form — and may not work at all

**This is the one the whole design is built around**, because parameterised roles are
the default and this is their exposure. Two separate problems.

**They are unvalidated.** When a parameterised role is assigned, the attribute
value is arbitrary text typed by whoever holds `updateTeamRoleAttributes` on the
team — i.e. the unit admin. Nothing stops another unit's project key being entered.
Prefixing the attribute inside the resource specifier — hoping
`proj/brand-x-${roleAttribute/project}` would force the value to stay in-namespace
— does not work.

There is no RBAC construct that constrains which values reach which teams. It is not
a matter of finding the right action to withhold; the capability is all-or-nothing.

**They may be unavailable, and fail silently.** On the account this repository was
verified against, role attributes did not function in any path tried: the field was
accepted and discarded on team create (including when the attached role genuinely
referenced the attribute), `updateRoleAttribute` returned `200` without persisting,
`replaceRoleAttributes` returned `400 unknown field` for every documented field name,
and a `PATCH /members` that successfully wrote `customRoles` silently dropped
`roleAttributes` in the same request. Terraform reported success while both teams'
roles resolved to **zero projects**.

`scoping_mode = "namespace"` is the fallback for this: it scopes the developer roles
by the unit's key glob and needs no per-assignment configuration at all. The cost is
that developers reach every project in their unit rather than one, and the guard
drops from load-bearing to belt-and-braces. See
[03-the-role-catalogue.md](03-the-role-catalogue.md) for the trade-off and
[06-verification-results.md](06-verification-results.md) for the evidence.

**Mitigation for the first problem:** the guard. `deny viewProject` on
`notResources: ["proj/brand-x-*"]` inside the role means a wrong value grants
nothing. The allow resolves, the deny overrides it, and since `viewProject` gates
everything else the whole role goes inert. Verified working.

**Mitigation for the second:** `scoping_mode = "namespace"`, plus
`tests/boundary-tests.sh` §9, which reads back what a deployed team's role actually
resolves to. A non-zero project count is the only proof that assignment took
effect — Terraform reporting success is not.

Note the shape of this mitigation: it does not prevent the wrong assignment, it
makes it **harmless**. The assignment succeeds and silently grants nothing. Nobody
is told they made a mistake. Audit if you want to notice; the boundary holds
either way.

*Verified by:* `tests/boundary-tests.sh` §6.

### 4. Tags are not a boundary

Tag-based resource specifiers exist (`proj/*;owner=brand-x`), so tags are more
than inert metadata. They are still wrong for this job, for four independent
reasons:

1. **They cannot gate creation.** A resource has no tags until it exists, so a
   `createProject` rule scoped to a tag gates nothing.
2. **They are mutable.** Anyone with `updateTags` moves a resource across a
   tag-defined line. The boundary is only as strong as your control over tag edits
   — and `updateTags` is a permission units usually want.
3. **Tooling is limited.** Tag scope needs the advanced editor and the REST API,
   and does not combine with role attributes.
4. **Support is not uniform** across resource types, and current LaunchDarkly
   documentation steers role scoping toward views rather than tags.

**Use tags for** inventory, filtering, reporting, cost attribution. This
repository tags projects `owner-brand-x` / `managed-by-unit` and references those
tags in no policy anywhere.

### 5. Sprawl inside the namespace

The prefix says where the unit may build, not how much. Nothing limits the number
of `brand-x-*` projects. Governance of what gets created inside the namespace
belongs to the unit's own pipeline and review process. That is the right owner,
but it is a genuine cost of delegation rather than something the boundary handles.

### 6. Terraform is destructive

Not a LaunchDarkly limitation, but the failure mode most likely to actually hurt
you. Terraform's model is convergence to declared state, so removing a resource
block means deletion. In this provider:

- `launchdarkly_project.environments` is the **authoritative** set. An environment
  absent from the map is deleted on apply, along with its SDK keys and all flag
  targeting.
- Changing an environment's map key **destroys and recreates** it. Irreversible.
- Changing a project key forces replacement of the project.

**Mitigations in this repository:** `allow_destructive_actions` defaults to false,
so the unit's own credential cannot delete projects, environments or teams at all;
`archive_flags_on_destroy = true` is set on the provider; and project keys are
derived rather than accepted as input, so they cannot drift by accident.

For anything beyond a demo, also consider a separate non-production account to
develop automation against. That is available by exception and has to be worked
out contractually, since it is effectively a second organisation.

## Summary table

| Concern | Enforced? | Verified | Mechanism / mitigation |
| --- | --- | --- | --- |
| Create outside namespace | **Yes** | §2, §3 | `createProject` / `createTeam` on key glob |
| See other unit's resources | **Yes** | §4 | deny-by-default; never named in policy |
| Wrong role-attribute value | **Yes**, made inert | §6 | in-policy `deny viewProject` guard |
| Token exceeding its creator | **Yes** | §8 | capped and fixed at creation — but metadata lies, see above |
| Production targeting by developers | **Yes** | §7 | environment-scoped allow + explicit deny |
| Base permissions granting org-wide read | **Yes**, if set | §1 | `no_access` explicitly; provider defaults to `reader` |
| A member's base role granting org-wide read | **Yes**, if set | §10 | members created `no_access`; provider defaults to `reader`, and a reader sees every project |
| Assignment actually taking effect | n/a | §9 | read back the resolved project count; do not trust apply success |
| Unit authoring its own roles | No | §5 | not delegated; `createRole` withheld |
| Attaching a broad role to a unit team | **No** | — | catalogue discipline + audit log alerting |
| Role attributes available at all | **No** | §9 | verify resolution; `scoping_mode = "namespace"` is the fallback |
| Per-project isolation inside a unit | **Yes** in the default role_attribute mode | §9 | one project per team via the attribute; lost in namespace mode |
| Sprawl within the namespace | No | — | unit's own pipeline governance |
| Tag drift | No | — | do not scope policies by tag |
| Destructive Terraform | No | — | withhold deletes; archive on destroy; derive keys |

Section numbers refer to `tests/boundary-tests.sh`.

## Read next

- [05-demo-walkthrough.md](05-demo-walkthrough.md) — stand it up and try to break it
