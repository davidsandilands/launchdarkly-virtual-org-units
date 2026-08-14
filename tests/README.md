# Boundary tests

`boundary-tests.sh` is a negative test suite. **Most assertions pass by being
refused.** A run where everything succeeded would mean the boundary had
collapsed, so read the output rather than only the exit code.

## Running

```sh
export LD_ADMIN_TOKEN=api-xxxx    # org admin: inspects roles, mints simulation tokens, cleans up
export LD_UNIT_TOKEN=api-yyyy     # the unit's delegated-admin service token
./boundary-tests.sh
```

Or put both in a gitignored `tests/.env` and just run `./boundary-tests.sh`, which
keeps tokens out of your shell history:

```
LD_ADMIN_TOKEN=api-xxxx
LD_UNIT_TOKEN=api-yyyy
```

Override the location with `LD_ENV_FILE`. Exported values take precedence.

Get `LD_UNIT_TOKEN` from stage 00:

```sh
cd ../terraform/00-platform
export LD_UNIT_TOKEN=$(terraform output -json unit_automation_tokens | jq -r '."brand-x"')
```

The script refuses to run if the two tokens are identical — every assertion would
pass for the wrong reason.

### Configuration

All optional, with defaults matching the repository:

| Variable | Default |
| --- | --- |
| `LD_API` | `https://app.launchdarkly.com/api/v2` |
| `UNIT_KEY` | `brand-x` |
| `OTHER_UNIT_KEY` | `brand-y` |
| `OTHER_PROJECT_KEY` | `brand-y-payments` |
| `UNIT_PROJECT_KEY` | `brand-x-checkout` |
| `NONPROD_ENV` | `development` |
| `PROD_ENV` | `production` |

Requires `bash`, `curl`, `jq`. Exits non-zero on any failure.

## What each section establishes

| § | Assertion | Why it matters |
| --- | --- | --- |
| 0 | Both fixture projects exist | Proving you cannot see a project that was never created proves nothing. Aborts if the target is missing. |
| 1 | Every catalogue role has `basePermissions: no_access` | The provider defaults this to `reader`, which grants account-wide read and silently voids the whole boundary. |
| 2 | Out-of-namespace project create refused; in-namespace succeeds | The only enforced creation control. Both halves matter — a boundary that blocks legitimate work is a broken delegation. |
| 3 | Same for teams | Otherwise the unit could create a team outside its namespace and attach roles to it. |
| 4 | Other unit absent from list; direct read refused; write refused | Deny-by-default, not a deny list. |
| 5 | Role authoring refused | `createRole` scoped to a key namespace restricts the label, not the policy content. So it is withheld entirely. |
| 6 | A role resolved against the other unit's project grants nothing | The guard. Deny beats allow within one policy, and `viewProject` gates everything else. |
| 7 | Developer can toggle in development, cannot in production | Confirms the role grants real access where it should — a suite of pure refusals cannot tell you whether the role works at all. |
| 8 | A unit-minted token cannot exceed the unit | The strongest guarantee in the design. Requires `allow_token_minting = true`; skips cleanly otherwise. Asserts the *effect*, not the mechanism, because the mint request may succeed and be capped silently. |
| 9 | The deployed team assignments resolve to real projects | Reads back what LaunchDarkly says the attached role covers. Sections 1–8 all passed once while both teams resolved to **zero** projects, because they test policies via inline-role tokens rather than the deployment. |
| 10 | Every member of a unit team has base role `no_access` | The base-permissions trap at the human level. A member left at the default `reader` reads every project in the account regardless of their catalogue roles, and the deny guard cannot cancel it. Skips with a note if no members are in unit teams yet. |

## What section 6 does and does not do

Section 6 is the most important test and the one with a caveat.

**What it does:** mints a service token whose inline policy is the developer policy
with the role attribute *already resolved* to the other unit's project — exactly
the policy a misassignment produces — and asserts the resulting access is nil.
This covers the mechanism the guard depends on: a deny overriding an allow within
one policy.

**What it does not do:** exercise the assignment path itself. Role attributes are
supplied on a team or member assignment, and access tokens cannot carry them, so
the script cannot make the real path happen. Do that once by hand — step 8 of
[../docs/05-demo-walkthrough.md](../docs/05-demo-walkthrough.md) — because seeing
the wrong assignment *save successfully* and grant nothing is the most convincing
part of the demo.

## Not covered, because it is not enforceable

These are absent from the suite deliberately. They are process controls, not
platform guarantees, and a passing test would be misleading:

- **Which roles a unit admin may attach to a unit team.** RBAC cannot express
  "only roles matching `role/brand-x-*`". Across roles permissions are additive
  and the more permissive wins, so the guard cannot help either. Mitigation is
  catalogue discipline plus audit-log alerting — detection, not prevention.
- **The policy content of a role authored by anyone holding `createRole`.**
- **Tag drift**, if you ever scope a policy by tag. Don't.
- **Sprawl inside the namespace.**

See [../docs/04-enforced-vs-process.md](../docs/04-enforced-vs-process.md).

## Side effects

The script creates scratch projects, teams and simulation tokens, and removes them
on exit via a trap — using the **admin** token, because the unit admin role
deliberately holds no delete permissions.

Scratch keys are suffixed with the process ID so a failed run does not block the
next one. If a run is killed hard enough to skip the trap, look for keys
containing `boundarytest` and remove them by hand.

Section 7 creates and deletes a flag in the unit's project. It does not touch any
flag it did not create.
