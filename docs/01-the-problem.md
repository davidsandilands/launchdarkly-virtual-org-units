# The problem: there is no organisational unit in LaunchDarkly

## What people are actually asking for

A large organisation has more than one group that wants to run its own corner of
a tooling platform. Not a different company — a different division, a subsidiary,
an acquisition, a brand, a regional engineering org. They want to create their
own projects, stand up their own teams, and onboard their own developers, on
their own schedule, without filing a ticket against a central platform team every
time.

The central team wants the same thing, from the other direction: they do not want
to be the bottleneck on every new team, and they very much do not want the new
division to be able to touch resources built up over years by the existing one.

In AWS this has a name and an object: an organisational unit. You create the OU,
you delegate administration under it, and the boundary is a first-class thing the
platform understands and enforces.

**LaunchDarkly has no equivalent object.** There is no OU, no sub-account, no
folder, no nested tenancy. An account has projects, teams, roles and members, all
in one flat namespace.

## The two obvious answers, and why they are wrong

**"Use two LaunchDarkly accounts."** This makes the boundary absolute, and pays
for it with everything else. Two SSO integrations to maintain. Two sets of
account-level configuration to keep in step. Contract and commercial
consequences. And critically: no cross-unit teams. If a developer from one unit
and a developer from another work on the same product — increasingly the norm in
merged or federated engineering orgs — two accounts means two identities, two
sets of flags, and no shared view of anything. The organisational boundary you
wanted to draw around *administration* ends up drawn around *collaboration*
instead.

**"Use tags."** Tag a resource with the unit that owns it, and scope roles by
tag. This fails for a reason that is structural rather than incidental: a
resource has no tags until after it exists. A `createProject` rule scoped to a
tag gates nothing at all, because at the moment of creation there is no tag to
match. Tags are also mutable by anyone holding `updateTags`, so even for existing
resources the boundary is only ever as strong as your control over tag edits.
Tags are genuinely useful — for inventory, filtering, reporting, cost attribution
— and genuinely unsuitable as an isolation mechanism.

## What this repository is

A worked pattern for building a **virtual** organisational unit inside a single
LaunchDarkly account: one org, one SSO integration, cross-unit teams possible,
and a delegated administration boundary that is enforced where the platform can
enforce it and honestly labelled where it cannot.

The pattern rests on one observation: **a resource key prefix is the only thing in
LaunchDarkly that constrains creation.** Everything else follows from that.

```
                    LaunchDarkly account
                    (one org, one SSO integration)
    ┌───────────────────────────────────────────────────────────┐
    │                                                           │
    │  PLATFORM TEAM                                            │
    │    · account-level configuration, SAML/SCIM               │
    │    · authors every custom role, for every unit            │
    │    · owns the namespace naming contract                   │
    │    · audits role-attachment events                        │
    │                                                           │
    │  ┌─────────────────────────┐ ┌─────────────────────────┐  │
    │  │  virtual unit: brand-x  │ │  virtual unit: brand-y  │  │
    │  │                         │ │                         │  │
    │  │  proj/brand-x-*         │ │  proj/brand-y-*         │  │
    │  │  team/brand-x-*         │ │  team/brand-y-*         │  │
    │  │                         │ │                         │  │
    │  │  creates its own        │ │  invisible to brand-x:  │  │
    │  │  projects and teams,    │ │  never named in         │  │
    │  │  assigns catalogue      │ │  brand-x's policy,      │  │
    │  │  roles, no ticket       │ │  therefore denied       │  │
    │  │  required               │ │  by default             │  │
    │  └─────────────────────────┘ └─────────────────────────┘  │
    └───────────────────────────────────────────────────────────┘
```

## What is enforced and what is not

The honest summary, before you invest in the pattern:

| | |
| --- | --- |
| **Enforced by the platform** | Creation confined to a key namespace. Deny-by-default invisibility of everything outside it. Service tokens capped at their creator's permissions. A deny statement overriding allows within the same policy. |
| **Not enforced — process controls** | Which roles a unit admin may attach to a unit team. The policy content of any role authored by someone holding `createRole`. Which values are supplied for a role attribute. Isolation between projects inside a single unit. |

Everything in the first column has been verified against a live account —
[06-verification-results.md](06-verification-results.md) has the evidence, and the
three defects that run exposed.

The second column is not a gap to be worked around later. It is a permanent
property of the design, and the pattern is built so that landing in the second
column is survivable rather than catastrophic. That is what
[04-enforced-vs-process.md](04-enforced-vs-process.md) is about, and it is the
document to read before deciding whether this is good enough for your
organisation.

## Read next

- [02-the-boundary-model.md](02-the-boundary-model.md) — why a key prefix, and what it does and does not control
- [03-the-role-catalogue.md](03-the-role-catalogue.md) — the three roles and what each is for
- [04-enforced-vs-process.md](04-enforced-vs-process.md) — the honest limits
- [05-demo-walkthrough.md](05-demo-walkthrough.md) — stand it up and try to break it
- [06-verification-results.md](06-verification-results.md) — what a live run proved, and what it broke
