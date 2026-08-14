# The boundary model: a key prefix is the security model

## Resource specifiers

LaunchDarkly role policies match resources by key, and the specifiers accept
globs:

```
proj/brand-x-*                        every project whose key starts with brand-x-
proj/brand-x-*:env/*                  every environment in those projects
proj/brand-x-*:env/production:flag/*  every flag, in production, in those projects
team/brand-x-*                        every team whose key starts with brand-x-
```

A statement grants an action on a set of resources matched this way. That is the
whole vocabulary available for expressing a boundary.

## Why the prefix, specifically

Most permission systems let you restrict what someone can *see* and what they can
*change*. The hard part of delegated administration is restricting what someone
can **create** — because a resource that does not exist yet has no properties to
match on. No tags, no owner, no parent, no attributes. The only thing it has is
the key the caller proposed.

So the question "how do I stop this unit creating things outside its area?"
reduces to "what can I match on at creation time?", and the answer is: the key.

```
createProject on proj/brand-x-*
    → POST /projects {"key": "brand-x-checkout"}   201 Created
    → POST /projects {"key": "brand-y-sneaky"}     403 Forbidden
```

The second call is rejected by the API. Not hidden from the UI, not caught by a
reviewer — refused. This is the one enforced creation control in the design, and
everything else in this repository is arranged around it.

`tests/boundary-tests.sh` section 2 asserts both halves of that: the out-of-namespace
create is refused, and the in-namespace create succeeds. Both matter — a boundary
that also blocks legitimate work is just a broken delegation.

## Invisibility is the same mechanism

Anything a policy does not name is denied by default. The acting unit's policy
never mentions `brand-y`, so `brand-y` resources are not merely read-only or
greyed out — they are absent. They do not appear in `GET /projects`. A direct
`GET /projects/brand-y-payments` returns a refusal.

This is worth being precise about, because it is better than the alternative
people usually reach for. **The other unit is not on a deny list.** A deny list
would have to be maintained forever: every new project the other unit creates
would be a gap until someone remembered to add it. Deny-by-default has no such
maintenance burden, and no window of exposure.

Search `policies/` for the string `brand-y`. It appears nowhere. That absence is
the control.

## What `viewProject` really is

One detail does more work than anything else in this design.

`viewProject` is not just "can see the project in a list". It is the gate through
which every other project-scoped permission resolves. Without `viewProject` on a
project, no other permission on anything inside that project functions —
`createFlag`, `updateOn`, `updateRules`, all of it becomes inert. You can hold an
explicit allow for every flag action in a project and still be able to do nothing,
if `viewProject` is missing.

In everyday role authoring this is the classic mistake: someone writes a careful
flag policy, forgets `viewProject`, and cannot understand why the role does
nothing.

Turned around, it becomes the strongest tool available:

**One `deny viewProject` statement can neutralise an entire role.**

That is the basis of the guard described in
[03-the-role-catalogue.md](03-the-role-catalogue.md) and
[04-enforced-vs-process.md](04-enforced-vs-process.md).

## What the prefix does not control

Three limits, stated plainly.

**It controls namespace, not sprawl.** Nothing stops `brand-x-anything` being
created, in any quantity. The prefix says where the unit may build, not how much
or how sensibly. Governance of what gets created inside the namespace belongs to
the unit's own automation and review process — which is the correct place for it,
but it is a real cost of delegation, not something the boundary handles for you.

**It cannot express exceptions.** A shared project that both units should read has
no natural home. The moment you add one, you either weaken the glob or start
maintaining a list, and the `deny viewProject / notResources` guard will actively
block it — the failure will present as a mysterious missing permission rather
than an obvious deny. Decide up front whether shared resources are in scope. This
repository assumes they are not.

**The naming contract becomes load-bearing.** Because the boundary *is* the key
prefix, a typo in a project key is a security event rather than a cosmetic
problem. `brandx-checkout` is outside the `brand-x-*` namespace and will simply be
refused; that is the safe failure. The unsafe direction is the platform team
later creating a project called `brand-x-shared` for its own purposes, which the
unit will then have full administrative rights over. Own the naming contract as
policy, and keep the platform team out of every unit's namespace.

The Terraform in this repository defends against the ordinary version of this by
deriving project keys as `"${unit_key}-${product_key}"` rather than accepting them
as input. An operator cannot fat-finger their way out of the namespace, because
the namespace is not a field they can fill in. That is a convenience, not the
control: `tests/boundary-tests.sh` proves the API refuses the call even when the
convenience is bypassed.

## A note on views

LaunchDarkly has a newer scoping construct called **views**, and the current
documentation steers role scoping toward views rather than tags. Views are worth
knowing about, and the Terraform provider supports them
(`launchdarkly_view`).

They are not used in this pattern, for the same reason tags are not: a view is a
property of resources that already exist, so it cannot gate creation. Views are a
better answer than tags for scoping *access to existing resources*, and if your
requirement is "these people should only work on these things" rather than "this
unit must administer its own area", look at views before reaching for this
pattern.

## Read next

- [03-the-role-catalogue.md](03-the-role-catalogue.md) — the three roles built on this model
