# Demo walkthrough

About 20 minutes end to end. Designed to be narrated: each step has a point, and
the point is usually visible in what *fails*.

Use a demo or innovation account. This creates real projects, teams, roles and
service tokens.

## Prerequisites

- Terraform >= 1.5, `curl`, `jq`
- An admin API token for the account:
  ```sh
  export LAUNCHDARKLY_ACCESS_TOKEN=api-xxxxxxxxxxxx
  export LD_ADMIN_TOKEN=$LAUNCHDARKLY_ACCESS_TOKEN
  ```

## Step 1 — The platform team builds the guardrails

```sh
cd terraform/00-platform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

This creates, as the account owner:

- role catalogues for two units, `brand-x` and `brand-y` — three roles each
- a `brand-x-admins` and `brand-y-admins` team holding each unit's admin role
- a service token per unit, capped at that unit's admin role
- three projects belonging to the other unit: `brand-y-payments`,
  `brand-y-fulfilment`, `brand-y-loyalty`

**Talking point.** The same module produced both catalogues. Onboarding a third
unit is one map entry in `terraform.tfvars`, not a redesign.

**Talking point.** Those exist so the isolation tests have real targets. Proving you
cannot see a project that was never created proves nothing. Several rather than one
also makes step 5 land harder — there is a realistic amount to be invisible.

Look at the roles in the UI now — Organisation → Roles. Open
`brand-x-developer` and switch to the advanced editor. Point at the last
statement.

## Step 2 — Become the unit

```sh
export LD_UNIT_TOKEN=$(terraform output -json unit_automation_tokens | jq -r '."brand-x"')
```

From here on, this credential holds exactly one role: `brand-x-unit-admin`.

Worth pausing on: this token's permissions were capped at that role's permissions
the moment it was created, and are now fixed. Widening the role later will not
widen this token.

## Step 3 — The unit onboards itself

```sh
cd ../10-unit
cp terraform.tfvars.example terraform.tfvars
terraform init
LAUNCHDARKLY_ACCESS_TOKEN=$LD_UNIT_TOKEN terraform apply
```

Creates three projects — `brand-x-checkout`, `brand-x-search`, `brand-x-mobile` —
each with `development` and `production` environments, and a `-leads` and `-devs`
team per project holding a catalogue role with that project supplied as the role
attribute. Six teams from one apply.

**The talking point of the whole demo.** Nothing in step 1 was re-run. The
platform team was not involved. No role was authored — check the output:

```
roles_authored_by_this_stage = []
```

Onboarding a fourth product area is another entry in `products`, applied by the same
pipeline with the same credential. That is what standing delegation looks like: the
unit added three product areas here and the platform team was not involved in any of
them.

## Step 4 — Try to escape the namespace

Still holding only the unit token:

```sh
LAUNCHDARKLY_ACCESS_TOKEN=$LD_UNIT_TOKEN \
  terraform apply -var 'project_key_override=brand-y-sneaky'
```

Terraform's own precondition catches this first, locally, with an explanation.
That is a convenience, not the control. Prove the control by going around it:

```sh
curl -i -X POST https://app.launchdarkly.com/api/v2/projects \
  -H "Authorization: $LD_UNIT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"key":"brand-y-sneaky","name":"should not exist"}'
```

`403`. The API refuses it. Then show the same call succeeding inside the namespace,
so it is clear the refusal is about the key and not about the token being broken
in general:

```sh
curl -i -X POST https://app.launchdarkly.com/api/v2/projects \
  -H "Authorization: $LD_UNIT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"key":"brand-x-anything","name":"fine"}'
```

## Step 5 — Show the other unit is invisible

```sh
curl -s https://app.launchdarkly.com/api/v2/projects \
  -H "Authorization: $LD_UNIT_TOKEN" | jq -r '.items[].key'
```

Only `brand-x-*` keys. None of the three `brand-y-*` projects appear, and neither do
any unrelated pre-existing projects in the account. They are not listed as forbidden
— they are simply not there.

```sh
curl -i https://app.launchdarkly.com/api/v2/projects/brand-y-payments \
  -H "Authorization: $LD_UNIT_TOKEN"
```

Refused. Now the point that lands with security reviewers:

```sh
grep -r 'brand-y' ../../policies/*.json
```

No matches. The other unit is not on a deny list that someone has to keep
updating. It is denied because it was never mentioned.

(Scope the grep to `*.json` — `policies/README.md` discusses `brand-y` in prose, and
matching that would spoil the point.)

## Step 6 — Try to escalate

```sh
curl -i -X POST https://app.launchdarkly.com/api/v2/roles \
  -H "Authorization: $LD_UNIT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"key":"brand-x-innocuous","name":"innocuous",
       "basePermissions":"no_access",
       "policy":[{"effect":"allow","actions":["*"],"resources":["proj/*"]}]}'
```

`403`. Explain why this capability is withheld entirely rather than scoped:
`createRole` can be restricted to `role/brand-x-*` keys, but nothing constrains
the policy *content*. A role called `brand-x-innocuous` can grant `proj/*` admin.
Restricting the key restricts the label, not the contents. So role authoring stays
with the platform team.

## Step 7 — Run the boundary tests

```sh
cd ../../tests
./boundary-tests.sh
```

Eleven sections, mostly passing by being refused. It also checks the
three things that are easy to get wrong and invisible when you do:

- every catalogue role has `basePermissions: no_access` — the provider defaults
  this to `reader`, which would grant account-wide read and silently void the
  whole boundary
- the developer role can toggle in `development` and cannot in `production`, in
  the same project with the same role
- the deployed team assignments actually resolve (§9) — exactly one project each in
  `role_attribute` mode. This is the assertion that caught a silent, total failure
  during verification, and it is the one to watch: **zero means role attributes are
  not taking effect in your account**, and step 8 below will not be demonstrable
- the guard holds on the live assignment path (§11), by making a bad assignment and
  proving it grants nothing

It cleans up its scratch resources with the admin token, because the unit admin
role deliberately cannot delete anything.

## Step 8 — The misassignment

**The money shot.** Everything so far shows the boundary refusing things. This shows
what happens when a unit admin does something that *isn't* refused — and it is the
question a security reviewer will actually ask: "what stops them pointing that role
at my project?"

Set up the problem out loud first. The developer role names
`proj/${roleAttribute/project}`. The unit admin supplies that value themselves, it is
free-form text, and RBAC has no way to require it start with `brand-x-`. So what
stops them typing `brand-y-payments`?

Requires `scoping_mode = "role_attribute"` (the default) and an account where role
attributes take effect — check with §9 first, and see the note at the end of this
step if they do not.

1. In the UI, open the `brand-x-checkout-devs` team.
2. Change the role attribute value on `brand-x-developer` from
   `brand-x-checkout` to `brand-y-payments`.
3. Save. **It saves.** No error, no warning. LaunchDarkly does not validate role
   attribute values.
4. Sign in as a member of that team. They can see nothing. Not `brand-y-payments`,
   which the allow named, and not `brand-x-checkout` either, since the attribute
   no longer points there.

The misassignment was not blocked. It was made **inert**. Walk the mechanism:

1. The allow resolved to `proj/brand-y-payments`.
2. The guard's deny matched, because that project is not in `proj/brand-x-*`.
3. Deny beats allow within one policy, order irrelevant.
4. `viewProject` gates everything else, so the whole role died — not just the read.

Then say the part that matters: **nobody was told.** No error, no warning, nothing in
the UI marking it wrong. That is a safe failure but a silent one, so if you want to
*notice* it rather than merely survive it, alert on role-attachment and
role-attribute events in the audit log.

Be careful with the word "prevents" here. It doesn't prevent — it neutralises. If you
say prevents, your audience expects a rejection and you'll be contradicted by the
next demo.

Set the attribute back to `brand-x-checkout` and confirm access returns.

> **If §9 reported 0 projects**, role attributes are not taking effect in your account
> and this step cannot be demonstrated on the live assignment path. Use
> `scoping_mode = "namespace"` so the rest of the demo works, and show the guard via
> test §6 instead, which proves the same deny-beats-allow mechanism using a token
> carrying the resolved policy. Say which one you are showing — the mechanism is
> identical, the delivery path is not.

> This step needs a second, non-owner account member — an owner's base role grants
> everything regardless, and access tokens cannot carry role attributes, which is
> why the test suite simulates it instead. It is the one claim in this repository
> that a live run could not verify.
>
> **That member must have base role `no_access`.** At the default of `reader` they
> would see every project in the account and the demo would show the opposite of
> what you intend. Create them with:
>
> ```sh
> curl -X POST https://app.launchdarkly.com/api/v2/members \
>   -H "Authorization: $LD_ADMIN_TOKEN" -H 'Content-Type: application/json' \
>   -d '[{"email":"you+brandxdev@example.com","role":"no_access"}]'
> ```
>
> Then add them to `brand-x-checkout-devs`. Gmail-style `+suffix` addresses work
> well for this — one mailbox, several distinct members.

## Step 8b — Prove the assignment actually took effect

Do this one in **every** mode. It takes one command and it is the check that
matters most, because an assignment that silently grants nothing looks identical to
one that works:

```sh
curl -s "https://app.launchdarkly.com/api/v2/teams/brand-x-checkout-devs?expand=roles" \
  -H "Authorization: $LD_ADMIN_TOKEN" \
  | jq '.roles.items[] | {role: .key, resolves_to: (.projects.items | map(.key))}'
```

A non-empty `resolves_to` is the proof. During verification of this repository that
array was empty on both teams while every other test passed and Terraform reported
success — see [06-verification-results.md](06-verification-results.md). Test suite
§9 automates exactly this.

## Step 9 — State the limits

Do not end on the successes. The credibility of the design comes from this part.

- **Attaching a broad role to a unit team is not prevented.**
  `updateTeamCustomRoles` on `team/brand-x-*` lets the unit admin attach *any*
  role in the account to their own teams. RBAC cannot express "only roles matching
  `role/brand-x-*`". And the guard does not help: across roles, permissions are
  additive and the more permissive wins, so a deny in one role cannot cancel an
  allow in another. Mitigation is catalogue discipline plus audit alerting —
  detection, not prevention.
- **A unit admin is a trusted role.** This isolates units from mistakes and casual
  overreach. It does not defend against a determined unit admin who knows the
  account layout. If that is in your threat model, you need separate accounts.
- **Tags are not a boundary** — they cannot gate creation and they are mutable.
- **Terraform is destructive.** `allow_destructive_actions` is false by default for
  that reason.

Full detail: [04-enforced-vs-process.md](04-enforced-vs-process.md).

## Teardown

```sh
cd terraform/10-unit && LAUNCHDARKLY_ACCESS_TOKEN=$LD_ADMIN_TOKEN terraform destroy
cd ../00-platform && terraform destroy
```

Destroy with the **admin** token: the unit's own credential cannot delete
projects, which is the point of `allow_destructive_actions = false`. Any project
created by hand during steps 4–5 needs removing manually.

## Suggested narration order

If you are recording this, the beats that carry the story:

1. There is no organisational unit object in LaunchDarkly (step 1)
2. The unit onboards itself with no ticket and authors no roles (step 3)
3. The API refuses an out-of-namespace key (step 4)
4. The other unit is invisible, and is not on a deny list (step 5)
5. Role authoring is withheld, and here is why scoping it would not help (step 6)
6. **A wrong assignment saves successfully and grants nothing** — the guard (step 8)
7. The assignment demonstrably resolves, and here is how it can silently not
   (step 8b)
8. Here is what this does not protect you from (step 9)
