###############################################################################
# Role catalogue for one virtual organisational unit.
#
# OWNERSHIP: this module is applied by the PLATFORM TEAM with an org-admin
# identity. The delegated unit never applies it, and its admin role deliberately
# does not include `createRole` or `updatePolicy`. Role authoring is the one
# capability that cannot be safely delegated -- see docs/04-enforced-vs-process.md.
###############################################################################

locals {
  # The namespace. Every resource the unit owns matches this specifier, and
  # nothing else does. This prefix is the entire security boundary.
  ns = "${var.unit_key}-*"

  # `$${...}` escapes Terraform's own interpolation so that the literal string
  # ${roleAttribute/project} is what actually reaches the LaunchDarkly API.
  # Getting this wrong is silent: Terraform would try to resolve a variable
  # named roleAttribute and fail, or worse, render an empty resource specifier.
  #
  # Verified: this renders to exactly `proj/${roleAttribute/project}` in the
  # stored policy. The escaping is correct. Whether the ACCOUNT honours role
  # attributes is a separate question -- see var.scoping_mode.
  project_attr = "$${roleAttribute/${var.role_attribute_name}}"

  # What the developer roles are scoped to. In namespace mode this is the unit's
  # glob, which needs no per-assignment configuration and therefore cannot fail
  # silently. In role_attribute mode the project is unknown at authoring time and
  # is supplied when the role is assigned.
  dev_target = var.scoping_mode == "namespace" ? local.ns : local.project_attr

  proj_scope    = "proj/${local.dev_target}"
  all_envs      = "proj/${local.dev_target}:env/*"
  all_flags     = "proj/${local.dev_target}:env/*:flag/*"
  all_segments  = "proj/${local.dev_target}:env/*:segment/*"
  nonprod_flags = "proj/${local.dev_target}:env/${var.nonprod_environment_key}:flag/*"
  prod_flags    = "proj/${local.dev_target}:env/${var.prod_environment_key}:flag/*"
  nonprod_env   = "proj/${local.dev_target}:env/${var.nonprod_environment_key}"
  nonprod_segs  = "proj/${local.dev_target}:env/${var.nonprod_environment_key}:segment/*"

  # Flag actions that change *configuration* rather than live behaviour. Safe
  # for any developer in any environment.
  flag_authoring_actions = [
    "createFlag",
    "updateName",
    "updateDescription",
    "updateTags",
    "updateFlagVariations",
    "updateFlagDefaultVariations",
    "updateTemporary",
    "updateMaintainer",
  ]

  # Flag actions that change what end users actually receive. These are the ones
  # worth splitting by environment.
  flag_targeting_actions = [
    "updateOn",
    "updateTargets",
    "updateRules",
    "updateFallthrough",
    "updateOffVariation",
    "updatePrerequisites",
    "updateExpiringTargets",
    "updateScheduledChanges",
  ]
}

###############################################################################
# 1. UNIT ADMIN
#
# The delegated administrator of the virtual org unit. This is the identity the
# unit's own automation authenticates as. It can stand up projects, environments
# and teams inside its namespace and assign roles from this catalogue -- and it
# can do nothing else, to nothing else.
###############################################################################

resource "launchdarkly_custom_role" "unit_admin" {
  key  = "${var.unit_key}-unit-admin"
  name = "${var.unit_name} :: unit admin"

  description = join(" ", [
    "Delegated administrator for the ${var.unit_key}-* namespace.",
    "Creates and manages projects, environments and teams whose keys begin with",
    "${var.unit_key}-. Cannot author roles, and cannot see anything outside the namespace.",
  ])

  # MUST be set explicitly. The provider defaults this field to `reader`, which
  # grants account-wide read access that is ADDITIVE with the policy below --
  # silently defeating the entire boundary. Never omit this.
  base_permissions = "no_access"

  policy_statements = concat(
    [
      # -- Projects inside the namespace -----------------------------------
      # createProject on a key glob is the single primitive in LaunchDarkly that
      # constrains creation. A project whose key does not match is rejected by
      # the API, not merely hidden.
      {
        effect        = "allow"
        actions       = ["createProject", "viewProject", "updateProjectName", "updateTags"]
        resources     = ["proj/${local.ns}"]
        not_actions   = null
        not_resources = null
      },

      # -- Environments within those projects ------------------------------
      {
        effect = "allow"
        actions = [
          "createEnvironment",
          "updateName",
          "updateColor",
          "updateTtl",
          "updateTags",
          "updateApprovalSettings",
          "updateRequireComments",
          "updateConfirmChanges",
          "updateCritical",
          "viewSdkKey",
        ]
        resources     = ["proj/${local.ns}:env/*"]
        not_actions   = null
        not_resources = null
      },

      # -- Teams inside the namespace --------------------------------------
      # updateTeamCustomRoles is what lets the unit attach catalogue roles to its
      # own teams without platform-team involvement. It is also the widest
      # capability granted here: see the escalation note in
      # docs/04-enforced-vs-process.md before assuming it is contained.
      # updateTeamDescription and updateTeamRoleAttributes are both required for
      # the unit to be able to UPDATE a team it created, not merely create one.
      # Omitting them produces a 403 on the second apply only -- the first apply
      # succeeds because create carries these fields in its own request body.
      # That is a nasty failure mode: the delegation appears to work until the
      # unit changes something.
      {
        effect = "allow"
        actions = [
          "createTeam",
          "viewTeam",
          "updateTeamName",
          "updateTeamDescription",
          "updateTeamMembers",
          "updateTeamCustomRoles",
          "updateTeamRoleAttributes",
        ]
        resources     = ["team/${local.ns}"]
        not_actions   = null
        not_resources = null
      },

      # -- The guard -------------------------------------------------------
      # Belt-and-braces on this role: deny-by-default already excludes every
      # project outside the namespace, because no statement above names one.
      # It is included for uniformity with the parameterised roles below, where
      # the same statement is genuinely load-bearing.
      #
      # Consequence worth knowing: if the unit is ever meant to read a shared
      # project outside its namespace, this statement will block it and the
      # failure will look like a missing permission rather than a deny.
      {
        effect        = "deny"
        actions       = ["viewProject"]
        resources     = null
        not_actions   = null
        not_resources = ["proj/${local.ns}"]
      },
    ],

    # -- Optional: destructive actions ------------------------------------
    var.allow_destructive_actions ? [
      {
        effect        = "allow"
        actions       = ["deleteProject"]
        resources     = ["proj/${local.ns}"]
        not_actions   = null
        not_resources = null
      },
      {
        effect        = "allow"
        actions       = ["deleteEnvironment"]
        resources     = ["proj/${local.ns}:env/*"]
        not_actions   = null
        not_resources = null
      },
      {
        effect        = "allow"
        actions       = ["deleteTeam"]
        resources     = ["team/${local.ns}"]
        not_actions   = null
        not_resources = null
      },
    ] : [],

    # -- Optional: service token minting ----------------------------------
    # A token's permissions are capped at those of the identity that created it
    # and are fixed at creation. Any token minted by this role is therefore
    # structurally confined to the namespace, whatever the unit asks for.
    var.allow_token_minting ? [
      {
        effect        = "allow"
        actions       = ["createAccessToken", "resetAccessToken", "deleteAccessToken"]
        resources     = ["service-token/*"]
        not_actions   = null
        not_resources = null
      },
    ] : [],
  )
}

###############################################################################
# 2. LEAD DEVELOPER
#
# Full flag lifecycle in every environment, including production.
#
# In the default "namespace" mode the scope is the unit's key glob, so one
# authored role covers every project the unit will ever create -- which is the
# property that makes the delegation standing rather than a ticket queue.
# In "role_attribute" mode the project is supplied per team at assignment time.
###############################################################################

resource "launchdarkly_custom_role" "lead_developer" {
  key  = "${var.unit_key}-lead-developer"
  name = "${var.unit_name} :: lead developer"

  description = join(" ", [
    "Full flag and segment lifecycle in all environments of",
    var.scoping_mode == "namespace" ? "every ${var.unit_key}-* project." : "the project named by the '${var.role_attribute_name}' role attribute.",
    "Carries a deny guard against anything outside the ${var.unit_key}-* namespace.",
  ])

  base_permissions = "no_access"

  policy_statements = [
    # Without viewProject nothing else in LaunchDarkly resolves, so this is the
    # foundation of the role -- and the reason the deny at the bottom is able to
    # neutralise the whole thing.
    {
      effect        = "allow"
      actions       = ["viewProject"]
      resources     = [local.proj_scope]
      not_actions   = null
      not_resources = null
    },
    {
      effect        = "allow"
      actions       = ["viewSdkKey"]
      resources     = [local.all_envs]
      not_actions   = null
      not_resources = null
    },
    {
      effect        = "allow"
      actions       = concat(local.flag_authoring_actions, local.flag_targeting_actions, ["deleteFlag"])
      resources     = [local.all_flags]
      not_actions   = null
      not_resources = null
    },
    {
      effect        = "allow"
      actions       = ["createApprovalRequest", "reviewApprovalRequest", "applyApprovalRequest"]
      resources     = [local.all_flags]
      not_actions   = null
      not_resources = null
    },
    {
      effect = "allow"
      actions = [
        "createSegment",
        "deleteSegment",
        "updateName",
        "updateDescription",
        "updateTags",
        "updateIncluded",
        "updateExcluded",
        "updateRules",
        "updateExpiringTargets",
      ]
      resources     = [local.all_segments]
      not_actions   = null
      not_resources = null
    },

    # -- The guard -------------------------------------------------------
    # In "role_attribute" mode this is load-bearing: nothing in LaunchDarkly RBAC
    # constrains which values may be supplied for a role attribute, so someone
    # with updateTeamCustomRoles could assign this role with another unit's
    # project key. This statement makes that assignment inert rather than
    # blocking it -- the allow resolves, this deny overrides it within the same
    # policy, and the net grant is nothing. Verified: deny beats allow inside one
    # policy, and statement order is irrelevant.
    #
    # In "namespace" mode there is no attribute to get wrong, so this is
    # belt-and-braces: it survives someone later widening a resource specifier
    # above without re-reading the whole policy.
    #
    # LIMIT in both modes: this holds only within THIS role. Permissions across
    # roles are additive and the more permissive wins, so it cannot defend
    # against a *different*, broader role being attached to the same team.
    {
      effect        = "deny"
      actions       = ["viewProject"]
      resources     = null
      not_actions   = null
      not_resources = ["proj/${local.ns}"]
    },
  ]
}

###############################################################################
# 3. DEVELOPER
#
# Same scope as the lead, but production targeting is request-only. This split is
# what demonstrates that a delegated unit can run a real internal permission
# hierarchy without the platform team authoring anything per team.
###############################################################################

resource "launchdarkly_custom_role" "developer" {
  key  = "${var.unit_key}-developer"
  name = "${var.unit_name} :: developer"

  description = join(" ", [
    "Flag authoring plus targeting in ${var.nonprod_environment_key} for",
    var.scoping_mode == "namespace" ? "every ${var.unit_key}-* project." : "the project named by the '${var.role_attribute_name}' role attribute.",
    "In ${var.prod_environment_key} may request changes but not apply them.",
    "Carries the same deny guard as the lead role.",
  ])

  base_permissions = "no_access"

  policy_statements = [
    {
      effect        = "allow"
      actions       = ["viewProject"]
      resources     = [local.proj_scope]
      not_actions   = null
      not_resources = null
    },
    {
      effect        = "allow"
      actions       = ["viewSdkKey"]
      resources     = [local.nonprod_env]
      not_actions   = null
      not_resources = null
    },

    # Flag *configuration* is not environment-specific, so authoring is allowed
    # across environments.
    {
      effect        = "allow"
      actions       = local.flag_authoring_actions
      resources     = [local.all_flags]
      not_actions   = null
      not_resources = null
    },

    # Live targeting: non-production only.
    {
      effect        = "allow"
      actions       = local.flag_targeting_actions
      resources     = [local.nonprod_flags]
      not_actions   = null
      not_resources = null
    },

    # In production, a developer can open an approval request but not review or
    # apply their own. The lead developer role above holds applyApprovalRequest.
    {
      effect        = "allow"
      actions       = ["createApprovalRequest"]
      resources     = [local.prod_flags]
      not_actions   = null
      not_resources = null
    },

    # Segments in non-production only.
    {
      effect        = "allow"
      actions       = ["createSegment", "updateName", "updateDescription", "updateTags", "updateIncluded", "updateExcluded", "updateRules"]
      resources     = [local.nonprod_segs]
      not_actions   = null
      not_resources = null
    },

    # -- Explicit production deny ----------------------------------------
    # Strictly redundant: the targeting allow above is already scoped to
    # ${var.nonprod_environment_key}, and anything unnamed is denied by default.
    # It is here because it survives someone later widening that allow to
    # `env/*` without re-reading the whole policy -- and because it is the
    # clearest in-repo demonstration that deny overrides allow within a policy.
    {
      effect        = "deny"
      actions       = concat(local.flag_targeting_actions, ["applyApprovalRequest", "reviewApprovalRequest"])
      resources     = [local.prod_flags]
      not_actions   = null
      not_resources = null
    },

    # -- The guard (load-bearing here) -----------------------------------
    {
      effect        = "deny"
      actions       = ["viewProject"]
      resources     = null
      not_actions   = null
      not_resources = ["proj/${local.ns}"]
    },
  ]
}
