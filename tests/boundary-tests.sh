#!/usr/bin/env bash
#
# Boundary tests for the virtual-organisational-unit pattern.
#
# These are negative tests. Most of them pass by being REFUSED. A suite where
# everything succeeds has proved nothing, so read the output, not just the exit
# code.
#
# What each test establishes is stated in its own header. The distinction that
# matters throughout: some of these boundaries are enforced by LaunchDarkly, and
# some of the things you might expect to be enforced are not. See
# ../docs/04-enforced-vs-process.md.
#
# Requires: bash 3.2+, curl, jq.

# Deliberately not `set -u`: macOS ships bash 3.2, where referencing an empty
# array under `set -u` is an unbound-variable error. Every variable below has an
# explicit default or a `:?` guard instead.
set -o pipefail

LD_API="${LD_API:-https://app.launchdarkly.com/api/v2}"

UNIT_KEY="${UNIT_KEY:-brand-x}"
OTHER_UNIT_KEY="${OTHER_UNIT_KEY:-brand-y}"

# A project the other unit owns. Must already exist -- stage 00 creates it. If it
# did not exist, "cannot see it" would be indistinguishable from "it is not there".
OTHER_PROJECT_KEY="${OTHER_PROJECT_KEY:-${OTHER_UNIT_KEY}-payments}"

# A project the acting unit owns, created by stage 10.
UNIT_PROJECT_KEY="${UNIT_PROJECT_KEY:-${UNIT_KEY}-checkout}"

NONPROD_ENV="${NONPROD_ENV:-development}"
PROD_ENV="${PROD_ENV:-production}"

# Scratch keys. Suffixed per run so a failed run does not block the next one.
RUN_ID="$$"
SCRATCH_IN_NS="${UNIT_KEY}-boundarytest-${RUN_ID}"
SCRATCH_OUT_NS="${OTHER_UNIT_KEY}-boundarytest-${RUN_ID}"
SCRATCH_TEAM_IN_NS="${UNIT_KEY}-boundarytest-team-${RUN_ID}"
SCRATCH_TEAM_OUT_NS="${OTHER_UNIT_KEY}-boundarytest-team-${RUN_ID}"

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

# Resources to remove on exit, as "kind:key" pairs. Cleanup uses the admin token,
# because the unit admin role deliberately has no delete permissions.
CLEANUP=()

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
grey()  { printf '\033[90m%s\033[0m\n' "$*"; }

pass() { PASS=$((PASS + 1)); green "  PASS  $*"; }
skip() { SKIP=$((SKIP + 1)); grey "  SKIP  $*"; }

# fail <short-name> <message...>
fail() {
  local name="$1"; shift
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$name")
  red "  FAIL  $*"
}

note() { grey "        $*"; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { red "missing required tool: $tool"; exit 2; }
done

# Optional local credentials file, so tokens never have to appear on a command
# line or in shell history. Gitignored. Expected format:
#
#   LD_ADMIN_TOKEN=api-xxxx
#   LD_UNIT_TOKEN=api-yyyy
#
# Override the location with LD_ENV_FILE. Values already exported win.
LD_ENV_FILE="${LD_ENV_FILE:-$(dirname "$0")/.env}"
if [ -f "$LD_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$LD_ENV_FILE"
fi

: "${LD_ADMIN_TOKEN:?set LD_ADMIN_TOKEN to an org-admin token (used to inspect roles and to clean up)}"
: "${LD_UNIT_TOKEN:?set LD_UNIT_TOKEN to the delegated-admin service token for the acting unit}"

if [ "$LD_ADMIN_TOKEN" = "$LD_UNIT_TOKEN" ]; then
  red "LD_ADMIN_TOKEN and LD_UNIT_TOKEN are the same value."
  red "Every test below would pass for the wrong reason. Refusing to run."
  exit 2
fi

# status <token> <method> <path> [body]  -> prints HTTP status code, or 000 if
# the request never completed. Transport errors are swallowed here because the
# code is the assertion; use body() when you need to see why something failed.
status() {
  local token="$1" method="$2" path="$3" body="${4:-}"
  if [ -n "$body" ]; then
    curl -sS -o /dev/null -w '%{http_code}' -X "$method" "${LD_API}${path}" \
      -H "Authorization: ${token}" -H 'Content-Type: application/json' -d "$body" 2>/dev/null
  else
    curl -sS -o /dev/null -w '%{http_code}' -X "$method" "${LD_API}${path}" \
      -H "Authorization: ${token}" 2>/dev/null
  fi
}

# body <token> <method> <path> [body] -> prints response body
body() {
  local token="$1" method="$2" path="$3" payload="${4:-}"
  if [ -n "$payload" ]; then
    curl -sS -X "$method" "${LD_API}${path}" \
      -H "Authorization: ${token}" -H 'Content-Type: application/json' -d "$payload"
  else
    curl -sS -X "$method" "${LD_API}${path}" -H "Authorization: ${token}"
  fi
}

is_denied() { [ "$1" = "401" ] || [ "$1" = "403" ] || [ "$1" = "404" ]; }
is_ok()     { [ "$1" = "200" ] || [ "$1" = "201" ]; }

cleanup() {
  local entry kind key
  [ ${#CLEANUP[@]} -eq 0 ] && return 0
  echo
  grey "cleaning up ${#CLEANUP[@]} scratch resource(s) with the admin token"
  for entry in "${CLEANUP[@]}"; do
    kind="${entry%%:*}"
    key="${entry#*:}"
    case "$kind" in
      project) status "$LD_ADMIN_TOKEN" DELETE "/projects/${key}" >/dev/null ;;
      team)    status "$LD_ADMIN_TOKEN" DELETE "/teams/${key}" >/dev/null ;;
      token)   status "$LD_ADMIN_TOKEN" DELETE "/tokens/${key}" >/dev/null ;;
      flag)    status "$LD_ADMIN_TOKEN" DELETE "/flags/${key}" >/dev/null ;;
    esac
  done
}
trap cleanup EXIT

echo
bold "Boundary tests: ${UNIT_KEY}-* namespace"
grey "api          ${LD_API}"
grey "acting unit  ${UNIT_KEY} (via LD_UNIT_TOKEN)"
grey "other unit   ${OTHER_UNIT_KEY}, target project ${OTHER_PROJECT_KEY}"
echo

# ---------------------------------------------------------------------------
bold "0. Preflight"
# ---------------------------------------------------------------------------
# Establishes that the fixtures the rest of the suite depends on are real.

code=$(status "$LD_ADMIN_TOKEN" GET "/projects/${OTHER_PROJECT_KEY}")
if is_ok "$code"; then
  pass "other unit's project ${OTHER_PROJECT_KEY} exists (admin can see it)"
else
  fail "preflight-other-project" "other unit's project ${OTHER_PROJECT_KEY} not found (HTTP ${code})"
  note "run terraform/00-platform first, or set OTHER_PROJECT_KEY"
  note "without a real target, every isolation test below would pass vacuously"
  exit 1
fi

code=$(status "$LD_ADMIN_TOKEN" GET "/projects/${UNIT_PROJECT_KEY}")
if is_ok "$code"; then
  pass "acting unit's project ${UNIT_PROJECT_KEY} exists"
  UNIT_PROJECT_PRESENT=1
else
  skip "acting unit's project ${UNIT_PROJECT_KEY} not found (HTTP ${code}); env-split tests will be skipped"
  note "run terraform/10-unit to create it"
  UNIT_PROJECT_PRESENT=0
fi

# ---------------------------------------------------------------------------
bold "1. Base permissions are no_access on every catalogue role"
# ---------------------------------------------------------------------------
# The quietest way to lose this entire boundary. A role whose base permission is
# `reader` grants account-wide read regardless of its statements, because
# permissions combine additively and the more permissive wins. The `deny
# viewProject` statement does NOT cancel it -- a deny only overrides allows
# within the same policy, and base permissions are not a statement in it.
#
# The Terraform provider defaults this field to `reader`. This test exists
# because that default is easy to inherit by omission.

roles_json=$(body "$LD_ADMIN_TOKEN" GET "/roles?limit=100")
for role in "${UNIT_KEY}-unit-admin" "${UNIT_KEY}-lead-developer" "${UNIT_KEY}-developer"; do
  base=$(echo "$roles_json" | jq -r --arg k "$role" '.items[]? | select(.key == $k) | .basePermissions // "reader"')
  if [ -z "$base" ]; then
    skip "role ${role} not found in account"
  elif [ "$base" = "no_access" ]; then
    pass "${role} has basePermissions=no_access"
  else
    fail "base-permissions-${role}" "${role} has basePermissions=${base}, expected no_access"
    note "this role can read every project in the account; the namespace boundary is void"
  fi
done

# ---------------------------------------------------------------------------
bold "2. Creation is constrained to the namespace"
# ---------------------------------------------------------------------------
# The core enforced control. createProject scoped to proj/<unit>-* means a key
# that does not match is rejected by the API. This is the only primitive in
# LaunchDarkly that constrains creation rather than merely visibility.

code=$(status "$LD_UNIT_TOKEN" POST "/projects" \
  "$(jq -n --arg k "$SCRATCH_OUT_NS" '{key: $k, name: "should not exist"}')")
if is_denied "$code"; then
  pass "creating project ${SCRATCH_OUT_NS} outside the namespace was refused (HTTP ${code})"
else
  fail "create-outside-namespace" "creating ${SCRATCH_OUT_NS} returned HTTP ${code}, expected 403"
  is_ok "$code" && CLEANUP+=("project:${SCRATCH_OUT_NS}")
  note "the namespace is not being enforced; check the createProject resource specifier"
fi

code=$(status "$LD_UNIT_TOKEN" POST "/projects" \
  "$(jq -n --arg k "$SCRATCH_IN_NS" '{key: $k, name: "boundary test scratch"}')")
if is_ok "$code"; then
  pass "creating project ${SCRATCH_IN_NS} inside the namespace succeeded (HTTP ${code})"
  CLEANUP+=("project:${SCRATCH_IN_NS}")
else
  fail "create-inside-namespace" "creating ${SCRATCH_IN_NS} returned HTTP ${code}, expected 201"
  note "the unit cannot provision itself; delegation is not working at all"
fi

# ---------------------------------------------------------------------------
bold "3. Team creation is constrained to the namespace"
# ---------------------------------------------------------------------------
# Same primitive, applied to teams. Without this the unit could create a team
# outside its namespace and attach roles to it.

code=$(status "$LD_UNIT_TOKEN" POST "/teams" \
  "$(jq -n --arg k "$SCRATCH_TEAM_OUT_NS" '{key: $k, name: "should not exist"}')")
if is_denied "$code"; then
  pass "creating team ${SCRATCH_TEAM_OUT_NS} outside the namespace was refused (HTTP ${code})"
else
  fail "create-team-outside" "creating team ${SCRATCH_TEAM_OUT_NS} returned HTTP ${code}, expected 403"
  is_ok "$code" && CLEANUP+=("team:${SCRATCH_TEAM_OUT_NS}")
fi

code=$(status "$LD_UNIT_TOKEN" POST "/teams" \
  "$(jq -n --arg k "$SCRATCH_TEAM_IN_NS" '{key: $k, name: "boundary test scratch team"}')")
if is_ok "$code"; then
  pass "creating team ${SCRATCH_TEAM_IN_NS} inside the namespace succeeded (HTTP ${code})"
  CLEANUP+=("team:${SCRATCH_TEAM_IN_NS}")
else
  fail "create-team-inside" "creating team ${SCRATCH_TEAM_IN_NS} returned HTTP ${code}, expected 201"
fi

# ---------------------------------------------------------------------------
bold "4. The other unit is invisible, not merely off-limits"
# ---------------------------------------------------------------------------
# Deny-by-default. The other unit's key appears nowhere in the acting unit's
# policy, so it is not on a deny list that has to be maintained -- it is simply
# never named.

listed=$(body "$LD_UNIT_TOKEN" GET "/projects?limit=100")
if echo "$listed" | jq -e '.items' >/dev/null 2>&1; then
  visible_other=$(echo "$listed" | jq -r --arg p "$OTHER_UNIT_KEY-" '[.items[].key | select(startswith($p))] | length')
  visible_own=$(echo "$listed" | jq -r --arg p "$UNIT_KEY-" '[.items[].key | select(startswith($p))] | length')
  off_namespace=$(echo "$listed" | jq -r --arg p "$UNIT_KEY-" '[.items[].key | select(startswith($p) | not)] | length')

  if [ "$visible_other" = "0" ]; then
    pass "project list contains no ${OTHER_UNIT_KEY}-* projects"
  else
    fail "list-leaks-other-unit" "project list contains ${visible_other} ${OTHER_UNIT_KEY}-* project(s)"
  fi

  if [ "$off_namespace" = "0" ]; then
    pass "project list contains nothing outside ${UNIT_KEY}-* (${visible_own} own project(s) visible)"
  else
    fail "list-leaks-off-namespace" "${off_namespace} project(s) outside the namespace are visible"
    note "$(echo "$listed" | jq -r --arg p "$UNIT_KEY-" '[.items[].key | select(startswith($p) | not)] | join(", ")')"
  fi
else
  skip "could not list projects with the unit token: $(echo "$listed" | jq -rc '.message? // .' 2>/dev/null | head -c 120)"
fi

code=$(status "$LD_UNIT_TOKEN" GET "/projects/${OTHER_PROJECT_KEY}")
if is_denied "$code"; then
  pass "direct read of ${OTHER_PROJECT_KEY} was refused (HTTP ${code})"
else
  fail "direct-read-other-project" "direct read of ${OTHER_PROJECT_KEY} returned HTTP ${code}, expected 403/404"
fi

code=$(status "$LD_UNIT_TOKEN" POST "/flags/${OTHER_PROJECT_KEY}" \
  '{"key":"boundary-test-should-fail","name":"should not exist","variations":[{"value":true},{"value":false}]}')
if is_denied "$code"; then
  pass "writing a flag into ${OTHER_PROJECT_KEY} was refused (HTTP ${code})"
else
  fail "write-other-project" "creating a flag in ${OTHER_PROJECT_KEY} returned HTTP ${code}, expected 403"
fi

# ---------------------------------------------------------------------------
bold "5. Role authoring is withheld"
# ---------------------------------------------------------------------------
# createRole can be scoped to a key namespace, but nothing constrains the POLICY
# CONTENT of a role someone creates. A role named brand-x-innocuous could grant
# proj/* admin. So the capability is not delegated at all, and this test asserts
# that decision is actually reflected in the role.

code=$(status "$LD_UNIT_TOKEN" POST "/roles" \
  "$(jq -n --arg k "${UNIT_KEY}-boundarytest-escalation-${RUN_ID}" \
     '{key: $k, name: "escalation attempt", basePermissions: "no_access",
       policy: [{effect: "allow", actions: ["*"], resources: ["proj/*"]}]}')")
if is_denied "$code"; then
  pass "authoring a new role was refused (HTTP ${code})"
else
  fail "role-authoring-not-withheld" "creating a role returned HTTP ${code}, expected 403"
  note "the unit can author a role granting proj/* admin; the boundary is decorative"
  note "remove createRole and updatePolicy from the unit-admin policy"
fi

# ---------------------------------------------------------------------------
bold "6. The deny guard neutralises a wrong role-attribute value"
# ---------------------------------------------------------------------------
# THE KEY TEST, and the one to read the caveat on.
#
# Nothing in LaunchDarkly RBAC constrains which values may be supplied for a role
# attribute. Someone holding updateTeamCustomRoles on a unit team can assign the
# developer role with ANOTHER unit's project key. The guard inside the role makes
# that assignment inert rather than blocking it.
#
# WHAT THIS TEST ACTUALLY DOES: it mints a token whose inline policy is the
# developer policy with the role attribute already resolved to the other unit's
# project -- exactly the policy that a misassignment produces. It then checks the
# resulting access is nil.
#
# WHAT IT DOES NOT DO: exercise the assignment path itself (team + role attribute
# + member), which needs a real member and a UI or SCIM round trip. Do that once
# by hand; see ../docs/05-demo-walkthrough.md. This test covers the mechanism the
# guard relies on: deny beats allow within one policy.

misassigned_policy=$(jq -n --arg proj "$OTHER_PROJECT_KEY" --arg ns "proj/${UNIT_KEY}-*" '
  [
    {effect: "allow", actions: ["viewProject"],  resources: [("proj/" + $proj)]},
    {effect: "allow", actions: ["createFlag", "updateOn", "updateRules", "updateTargets"],
     resources: [("proj/" + $proj + ":env/*:flag/*")]},
    {effect: "deny",  actions: ["viewProject"],  notResources: [$ns]}
  ]')

tok_resp=$(body "$LD_ADMIN_TOKEN" POST "/tokens" \
  "$(jq -n --arg n "boundary-test-misassigned-${RUN_ID}" --argjson p "$misassigned_policy" \
     '{name: $n, serviceToken: true, inlineRole: $p}')")
misassigned_token=$(echo "$tok_resp" | jq -r '.token // empty')
misassigned_id=$(echo "$tok_resp" | jq -r '._id // empty')

if [ -z "$misassigned_token" ]; then
  skip "could not mint the simulation token: $(echo "$tok_resp" | jq -rc '.message? // .' | head -c 200)"
  note "verify this case by hand in the UI instead -- see docs/05-demo-walkthrough.md"
else
  [ -n "$misassigned_id" ] && CLEANUP+=("token:${misassigned_id}")

  code=$(status "$misassigned_token" GET "/projects/${OTHER_PROJECT_KEY}")
  if is_denied "$code"; then
    pass "role resolved against ${OTHER_PROJECT_KEY} grants no read (HTTP ${code})"
    note "the allow resolved, the in-policy deny overrode it, net access is nothing"
  else
    fail "poison-pill-read" "misassigned role could read ${OTHER_PROJECT_KEY} (HTTP ${code})"
    note "the deny guard is not holding; nothing protects role-attribute assignment"
  fi

  code=$(status "$misassigned_token" POST "/flags/${OTHER_PROJECT_KEY}" \
    '{"key":"boundary-test-poison","name":"should not exist","variations":[{"value":true},{"value":false}]}')
  if is_denied "$code"; then
    pass "role resolved against ${OTHER_PROJECT_KEY} grants no write (HTTP ${code})"
    note "without viewProject nothing else in LaunchDarkly resolves, which is why one deny is enough"
  else
    fail "poison-pill-write" "misassigned role could write to ${OTHER_PROJECT_KEY} (HTTP ${code})"
  fi
fi

# ---------------------------------------------------------------------------
bold "7. The developer role's production split holds"
# ---------------------------------------------------------------------------
# Same simulation technique, resolved correctly this time, to show the role does
# grant real access where it should -- a suite of refusals alone cannot tell you
# whether the role works at all.

if [ "$UNIT_PROJECT_PRESENT" != "1" ]; then
  skip "no ${UNIT_PROJECT_KEY} project; run terraform/10-unit first"
else
  flag_key="boundary-test-envsplit-${RUN_ID}"
  code=$(status "$LD_ADMIN_TOKEN" POST "/flags/${UNIT_PROJECT_KEY}" \
    "$(jq -n --arg k "$flag_key" '{key: $k, name: "boundary test env split",
        variations: [{value: true}, {value: false}]}')")
  if ! is_ok "$code"; then
    skip "could not create a test flag in ${UNIT_PROJECT_KEY} (HTTP ${code})"
  else
    CLEANUP+=("flag:${UNIT_PROJECT_KEY}/${flag_key}")

    dev_policy=$(jq -n --arg proj "$UNIT_PROJECT_KEY" --arg ns "proj/${UNIT_KEY}-*" \
      --arg np "$NONPROD_ENV" --arg pr "$PROD_ENV" '
      [
        {effect: "allow", actions: ["viewProject"], resources: [("proj/" + $proj)]},
        {effect: "allow", actions: ["createFlag", "updateName", "updateFlagVariations"],
         resources: [("proj/" + $proj + ":env/*:flag/*")]},
        {effect: "allow", actions: ["updateOn", "updateTargets", "updateRules", "updateFallthrough"],
         resources: [("proj/" + $proj + ":env/" + $np + ":flag/*")]},
        {effect: "deny",  actions: ["updateOn", "updateTargets", "updateRules", "updateFallthrough"],
         resources: [("proj/" + $proj + ":env/" + $pr + ":flag/*")]},
        {effect: "deny",  actions: ["viewProject"], notResources: [$ns]}
      ]')

    tok_resp=$(body "$LD_ADMIN_TOKEN" POST "/tokens" \
      "$(jq -n --arg n "boundary-test-developer-${RUN_ID}" --argjson p "$dev_policy" \
         '{name: $n, serviceToken: true, inlineRole: $p}')")
    dev_token=$(echo "$tok_resp" | jq -r '.token // empty')
    dev_id=$(echo "$tok_resp" | jq -r '._id // empty')

    if [ -z "$dev_token" ]; then
      skip "could not mint the developer simulation token"
    else
      [ -n "$dev_id" ] && CLEANUP+=("token:${dev_id}")

      code=$(status "$dev_token" GET "/projects/${UNIT_PROJECT_KEY}")
      if is_ok "$code"; then
        pass "developer role can read its own project ${UNIT_PROJECT_KEY}"
      else
        fail "developer-own-project" "developer role cannot read ${UNIT_PROJECT_KEY} (HTTP ${code})"
      fi

      code=$(status "$dev_token" PATCH "/flags/${UNIT_PROJECT_KEY}/${flag_key}" \
        "$(jq -n --arg e "$NONPROD_ENV" '[{op: "replace", path: ("/environments/" + $e + "/on"), value: true}]')")
      if is_ok "$code"; then
        pass "developer can toggle in ${NONPROD_ENV} (HTTP ${code})"
      else
        fail "developer-nonprod-toggle" "developer could not toggle in ${NONPROD_ENV} (HTTP ${code})"
      fi

      code=$(status "$dev_token" PATCH "/flags/${UNIT_PROJECT_KEY}/${flag_key}" \
        "$(jq -n --arg e "$PROD_ENV" '[{op: "replace", path: ("/environments/" + $e + "/on"), value: true}]')")
      if is_denied "$code"; then
        pass "developer cannot toggle in ${PROD_ENV} (HTTP ${code})"
      else
        fail "developer-prod-toggle" "developer toggled ${PROD_ENV}, returned HTTP ${code}"
        note "the environment split is not holding; check the production deny statement"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
bold "8. A token cannot exceed the identity that created it"
# ---------------------------------------------------------------------------
# The strongest claim in docs/04-enforced-vs-process.md: token permissions are
# capped at the creating identity's permissions and fixed at creation. If that
# holds, delegating token minting to a unit does not widen the boundary, which is
# what makes it safe to let a unit issue credentials to its own pipelines.
#
# This section requires allow_token_minting = true on the unit admin role. It
# skips cleanly otherwise, so the suite still works with the shipped defaults.
#
# The escalation attempt below asks for the built-in `admin` role using the unit's
# delegated credential. There are two acceptable outcomes and the test does not
# presume which: the request is refused outright, or it succeeds and the resulting
# token is still confined to the namespace. Either proves capping. What would
# disprove it is a token that comes back able to reach outside.

esc_resp=$(body "$LD_UNIT_TOKEN" POST "/tokens" \
  "$(jq -n --arg n "boundary-test-escalation-${RUN_ID}" '{name: $n, serviceToken: true, role: "admin"}')")
esc_token=$(echo "$esc_resp" | jq -r '.token // empty')
esc_id=$(echo "$esc_resp" | jq -r '._id // empty')

if [ -z "$esc_token" ]; then
  msg=$(echo "$esc_resp" | jq -rc '.message? // .code? // .' 2>/dev/null | head -c 160)
  if echo "$msg" | grep -qiE 'forbid|denied|permission|unauthor|not allowed|invalid'; then
    pass "minting an admin-role token as the unit was refused"
    note "capping enforced by refusal: ${msg}"
  else
    skip "could not mint a token as the unit: ${msg}"
    note "if allow_token_minting is false this is expected; set it true to exercise this section"
  fi
else
  [ -n "$esc_id" ] && CLEANUP+=("token:${esc_id}")
  note "the mint request succeeded; checking whether the resulting token is actually capped"

  code=$(status "$esc_token" GET "/projects/${OTHER_PROJECT_KEY}")
  if is_denied "$code"; then
    pass "downstream token requesting admin cannot read ${OTHER_PROJECT_KEY} (HTTP ${code})"
    note "capping enforced silently: the request was granted but the permissions were not"
  else
    fail "token-capping-read" "downstream token read ${OTHER_PROJECT_KEY} (HTTP ${code})"
    note "PRIVILEGE ESCALATION: a unit minted a token wider than itself"
    note "revoke allow_token_minting and correct docs/04-enforced-vs-process.md"
  fi

  code=$(status "$esc_token" POST "/projects" \
    "$(jq -n --arg k "${OTHER_UNIT_KEY}-viatoken-${RUN_ID}" '{key: $k, name: "should not exist"}')")
  if is_denied "$code"; then
    pass "downstream token cannot create outside the namespace (HTTP ${code})"
  else
    fail "token-capping-create" "downstream token created an out-of-namespace project (HTTP ${code})"
    is_ok "$code" && CLEANUP+=("project:${OTHER_UNIT_KEY}-viatoken-${RUN_ID}")
  fi
fi

# A downstream token minted for a legitimate purpose must still work, or the
# capping is just breakage.
pipe_policy=$(jq -n --arg ns "proj/${UNIT_KEY}-*" \
  '[{effect: "allow", actions: ["viewProject"], resources: [$ns]}]')
pipe_resp=$(body "$LD_UNIT_TOKEN" POST "/tokens" \
  "$(jq -n --arg n "boundary-test-pipeline-${RUN_ID}" --argjson p "$pipe_policy" \
     '{name: $n, serviceToken: true, inlineRole: $p}')")
pipe_token=$(echo "$pipe_resp" | jq -r '.token // empty')
pipe_id=$(echo "$pipe_resp" | jq -r '._id // empty')

if [ -z "$pipe_token" ]; then
  skip "could not mint an in-namespace pipeline token: $(echo "$pipe_resp" | jq -rc '.message? // .' | head -c 140)"
else
  [ -n "$pipe_id" ] && CLEANUP+=("token:${pipe_id}")
  if [ "$UNIT_PROJECT_PRESENT" = "1" ]; then
    code=$(status "$pipe_token" GET "/projects/${UNIT_PROJECT_KEY}")
    if is_ok "$code"; then
      pass "downstream token scoped inside the namespace works (HTTP ${code})"
    else
      fail "token-inside-namespace" "in-namespace downstream token cannot read ${UNIT_PROJECT_KEY} (HTTP ${code})"
      note "delegated token minting is unusable; capping has become breakage"
    fi
  else
    skip "no ${UNIT_PROJECT_KEY} to read with the downstream token"
  fi
fi

# ---------------------------------------------------------------------------
bold "9. The deployed team assignment actually resolves"
# ---------------------------------------------------------------------------
# This section exists because its absence hid a real defect.
#
# Sections 6 and 7 test roles via tokens carrying an inline policy, which proves
# the policy MECHANISM but says nothing about whether the deployed team-to-role
# assignment took effect. The first live run passed all of 1-8 while both real
# teams had roles that resolved to zero projects: the role attribute value was
# accepted by the API and silently discarded.
#
# LaunchDarkly reports what a team's attached role resolves to, so ask it
# directly rather than inferring from a simulation.

for team_pair in "${UNIT_KEY}-checkout-leads:${UNIT_KEY}-lead-developer" \
                 "${UNIT_KEY}-checkout-devs:${UNIT_KEY}-developer"; do
  team="${team_pair%%:*}"
  want_role="${team_pair#*:}"

  resp=$(body "$LD_ADMIN_TOKEN" GET "/teams/${team}?expand=roles")
  if ! echo "$resp" | jq -e '.key' >/dev/null 2>&1; then
    skip "team ${team} not found; run terraform/10-unit"
    continue
  fi

  attached=$(echo "$resp" | jq -r --arg r "$want_role" '[.roles.items[]? | select(.key == $r)] | length')
  if [ "$attached" = "1" ]; then
    pass "${team} has ${want_role} attached"
  else
    fail "role-not-attached-${team}" "${team} does not have ${want_role} attached"
    continue
  fi

  # The decisive assertion: how many projects does the role actually reach?
  n=$(echo "$resp" | jq -r --arg r "$want_role" '[.roles.items[]? | select(.key == $r)] | .[0].projects.totalCount // 0')
  if [ "$n" -gt 0 ]; then
    pass "${want_role} on ${team} resolves to ${n} project(s)"
    note "$(echo "$resp" | jq -r --arg r "$want_role" '[.roles.items[]? | select(.key==$r)] | .[0].projects.items // [] | map(.key) | join(", ")')"
  else
    fail "role-resolves-to-nothing-${team}" "${want_role} on ${team} resolves to 0 projects"
    note "the assignment looks correct in the UI and grants nothing"
    note "if scoping_mode is role_attribute, your account may not support role attributes"
    note "see docs/06-verification-results.md"
  fi
done

# ---------------------------------------------------------------------------
bold "10. Members of unit teams hold no base-role access of their own"
# ---------------------------------------------------------------------------
# The other half of the base-permissions trap, and the one that bites humans
# rather than roles.
#
# An account member's BASE role is additive with whatever custom roles they hold,
# and the more permissive of the two wins. A member left at the provider's default
# of `reader` can read EVERY project in the account. Verified directly against the
# live account: a plain reader identity listed all 7 projects, including the other
# unit's.
#
# The deny guard cannot rescue this. It overrides allows within its own policy, and
# a base role is not a statement in that policy. Nor does the namespace apply to it.
#
# So every member of a unit team must be created with base role `no_access` and
# draw all of their access from catalogue roles.

members=$(body "$LD_ADMIN_TOKEN" GET "/members?limit=100&expand=teams")

if ! echo "$members" | jq -e '.items' >/dev/null 2>&1; then
  skip "could not list account members: $(echo "$members" | jq -rc '.message? // .' | head -c 120)"
else
  note "account members: $(echo "$members" | jq -r '[.items[] | "\(.email)=\(.role)"] | join("  ")')"

  in_unit=$(echo "$members" | jq -r --arg ns "${UNIT_KEY}-" \
    '[.items[] | select([(.teams // [])[].key // ""] | any(startswith($ns)))] | length')

  if [ "$in_unit" = "0" ]; then
    skip "no account members belong to ${UNIT_KEY}-* teams yet"
    note "this assertion only becomes meaningful once real people are added to unit teams"
  else
    offenders=$(echo "$members" | jq -r --arg ns "${UNIT_KEY}-" \
      '[.items[]
        | select([(.teams // [])[].key // ""] | any(startswith($ns)))
        | select(.role != "no_access")
        | "\(.email) (base role=\(.role))"] | join("; ")')

    if [ -z "$offenders" ]; then
      pass "all ${in_unit} member(s) of ${UNIT_KEY}-* teams have base role no_access"
    else
      fail "member-base-role" "unit-team member(s) hold a base role above no_access: ${offenders}"
      note "a base role of reader grants read on EVERY project in the account"
      note "the namespace does not constrain it and the deny guard cannot cancel it"
      note "set the member's role to no_access; their access should come only from catalogue roles"
    fi
  fi
fi

# ---------------------------------------------------------------------------
echo
bold "Summary"
echo "  passed  ${PASS}"
echo "  failed  ${FAIL}"
echo "  skipped ${SKIP}"

if [ "$FAIL" -gt 0 ]; then
  echo
  red "failing: ${FAILED_NAMES[*]}"
  echo
  grey "A failure here is a finding, not a flaky test. Each one corresponds to a"
  grey "specific claim in docs/04-enforced-vs-process.md."
  exit 1
fi

echo
green "All executed assertions held."
echo
grey "Not covered by this suite, and not enforceable by LaunchDarkly:"
grey "  - which roles a unit admin may attach to a unit team (process control)"
grey "  - the content of any role authored by someone who holds createRole"
grey "  - tag drift, if you ever scope a policy by tag"
grey "See docs/04-enforced-vs-process.md."
