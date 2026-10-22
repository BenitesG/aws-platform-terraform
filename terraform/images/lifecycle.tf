# ---------------------------------------------------------------------------
# images/lifecycle.tf
#
# Deprecation policy for the golden images.
#
# WHY THIS IS NOT OPTIONAL: each build keeps an EBS snapshot of the image's
# disk. At 20 GB, that is on the order of US$ 1/month per version. On a monthly
# rebuild, twelve months without cleanup become ~US$ 12/month of images nobody
# uses - and the cost grows silently, with no alarm at all. Same pattern as the
# forgotten EIP.
#
# There is a second reason: recipes and components cannot be deleted while an
# image that references them exists. Without deprecation, the old recipes also
# accumulate without being removable.
# ---------------------------------------------------------------------------

# The role that the lifecycle service assumes to delete the AMI and snapshot.
#
# Different from the build role: this one is assumed by the SERVICE ITSELF
# (imagebuilder.amazonaws.com), not by an EC2 instance.
resource "aws_iam_role" "lifecycle" {
  # delegated- prefix required by the DelegatedAdminBoundary.
  name = "delegated-imagebuilder-lifecycle"

  # Without the boundary the CreateRole is denied.
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "imagebuilder.amazonaws.com" }
    }]
  })

  description = "Execution role of the image deprecation policy"
}

resource "aws_iam_role_policy_attachment" "lifecycle" {
  role       = aws_iam_role.lifecycle.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/EC2ImageBuilderLifecycleExecutionPolicy"
}

# ---------------------------------------------------------------------------
# UNBLOCKED ON 2026-10-15
#
# History: the creation failed with
#   AccessDeniedException: not authorized to perform iam:PassRole on
#   role/delegated-imagebuilder-lifecycle because no permissions boundary
#   allows the iam:PassRole action
#
# Cause: the "PassRoleSomenteParaServicos" statement of the
# DelegatedAdminBoundary restricted iam:PassRole to ec2, lambda and ecs-tasks.
# The lifecycle policy passes the role to imagebuilder.amazonaws.com, which was
# not on the list.
#
# The administrator published v2 of the boundary, swapping StringEquals for
# StringLike with "lambda*", "ecs*", "ec2.*" and "image*". Confirmed by
# simulate-principal-policy, with the SAME session as before (a change to a
# policy document takes effect on the next call, it does not require a
# re-login):
#   PassRole -> imagebuilder.amazonaws.com .............. allowed
#   imagebuilder:CreateLifecyclePolicy ................... allowed
#
# RESERVATION ON RECORD: the wildcard widened the boundary more than necessary
# - "ecs*" now covers ecs.amazonaws.com, not just ecs-tasks. It is not
# blocking, but the narrow version (StringEquals with the four exact
# principals) would give the same functional result without widening anything.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ONE POLICY PER LINEAGE
#
# There used to be ONE policy selecting Application = golden-image, a value the
# three lineages shared. Two problems with that:
#
#   1. The COUNT grouping was ambiguous - did "keep the 3 most recent" apply
#      per lineage or to the whole set? With 2 builds of each, the oldest could
#      be deleted even though it was the only one of that lineage. And the base
#      x86 is the PARENT IMAGE of the container host: deleting it would break
#      the child recipe
#   2. There was no way to tell images apart in the inventory or in the Cost
#      Explorer
#
# With one policy per lineage, "the 3 most recent" is unambiguous, and adding a
# new lineage is one entry in the map.
#
# ATTENTION - THIS STILL DOES NOT WORK ON ITS OWN, and the reason is important:
#
# Tag-based selection evaluates tags on the IMAGE RESOURCE of the Image
# Builder, not on the output AMI. The AWS documentation: "tags on the Image
# Builder image resource only, not on output AMIs". And the image resource is
# born WITHOUT TAGS - it does not propagate from the pipeline nor from the
# recipe (verified in practice).
#
# So the image resource must be tagged AFTER each build:
#   aws imagebuilder tag-resource --resource-arn <image arn> \
#     --tags "acme:cost-allocation:Application=<lineage>"
#
# The image resource tagging Lambda exists to automate this - it would copy
# the recipe's tags to the image, generically. It was not implemented.
# ---------------------------------------------------------------------------

locals {
  # key   = value of the Application tag on the lineage
  # value = name of the retention policy
  #
  # The key values come from what was applied to the AMIs and from the
  # ami_tags of the distribution configurations - the two must match, or the
  # policy selects nothing.
  #
  # FOUR LINEAGES: base and container host, in x86 and arm64.
  # The arm64 container host exists because the integration worker (dataflow)
  # is t4g and had Docker installed BY HAND - without its own lineage, the
  # daemon.json with log rotation does not reach a Graviton machine.
  retention_lineages = {
    "ubuntu-2604-x86"          = "acme-swe-prod-retention-ubuntu-2604-x86"
    "ubuntu-2604-arm64"        = "acme-swe-prod-retention-ubuntu-2604-arm64"
    "docker-ubuntu-2604-x86"   = "acme-swe-prod-retention-docker-ubuntu-2604-x86"
    "docker-ubuntu-2604-arm64" = "acme-swe-prod-retention-docker-ubuntu-2604-arm64"
  }
}

resource "aws_imagebuilder_lifecycle_policy" "golden_images" {
  for_each = local.retention_lineages

  name           = each.value
  description    = "Keeps the 2 most recent versions of the ${each.key} lineage"
  execution_role = aws_iam_role.lifecycle.arn
  resource_type  = "AMI_IMAGE"
  status         = "ENABLED"

  policy_detail {
    action {
      type = "DELETE"

      # snapshots = true is the central point: deregistering the AMI without
      # deleting the snapshot frees no cost at all, because the storage is in
      # the snapshot, not in the AMI.
      #
      # containers = false MUST BE DECLARED, even though it is the default.
      #
      # Without this line the apply fails with "Provider produced inconsistent
      # result after apply": the provider plans containers as UNKNOWN, the API
      # returns false, and since policy_detail is a SET the planned element
      # does not correlate with the returned one. The resource does get created
      # in AWS, but the apply aborts.
      include_resources {
        amis       = true
        snapshots  = true
        containers = false
      }
    }

    # COUNT = keep the N most recent. The alternative would be AGE (by age),
    # which is worse here: if no one builds an image for months, AGE would
    # delete the only one that exists.
    #
    # With ONE POLICY PER LINEAGE the grouping is unambiguous: it is the N most
    # recent OF THIS lineage.
    #
    # COUNT 2, lowered from 3. The reason is the CEILING, not the present:
    #
    #   4 lineages x 3 versions = up to 300 GB  ~US$ 15.00/month
    #   4 lineages x 2 versions = up to 200 GB  ~US$ 10.00/month
    #
    # Two versions is the MINIMUM that preserves rollback: "the current and the
    # previous". If a new build comes out defective, you can go back. The third
    # one kept solves nothing the second does not already solve.
    #
    # COUNT 1 was discarded: it would delete exactly the version that worked at
    # the moment the new one came in, leaving the account with no way back.
    filter {
      type  = "COUNT"
      value = 2
    }

    # Safety net: does not delete an AMI used to launch an instance in the last
    # 30 days, even if it falls outside the 3 most recent.
    #
    # Deleting the AMI does not bring down an already-running instance - it has
    # its own volume. What is lost is the ability to launch ANOTHER identical
    # instance, and that is exactly what this rule protects.
    #
    # It PARTIALLY protects the base AMI: the container host build launches an
    # instance from it, which updates the last_launched. But if no one builds
    # the container host for more than 30 days, that protection expires.
    exclusion_rules {
      amis {
        # is_public = false MUST BE DECLARED, even though it is the default -
        # same trap as containers above.
        #
        # The API returns is_public = false; without declaring it, the set
        # element of policy_detail differs from what is in the state and the
        # plan ends up with a PERPETUAL DIFF: every run shows policy_detail
        # being removed and recreated, and "No changes" never shows up again.
        #
        # Our AMIs are never public (the account's public access block
        # prevents it), so false is also the correct value by design: the rule
        # "do not delete a public AMI" has no effect here.
        is_public = false

        last_launched {
          unit  = "DAYS"
          value = 30
        }
      }
    }
  }

  # Selection by LINEAGE TAG, not by recipe: this way the policy follows the
  # future versions of the same lineage without being edited.
  #
  # REMEMBER: this evaluates tags on the IMAGE RESOURCE of the Image Builder,
  # NOT on the output AMI. And the image resource is born without tags - it
  # must be tagged after each build, by hand or by the tagging Lambda. See the
  # note at the top.
  resource_selection {
    tag_map = {
      "acme:cost-allocation:Application" = each.key
    }
  }

  # Ensures the managed policy is attached before the service tries to use the
  # role.
  depends_on = [aws_iam_role_policy_attachment.lifecycle]
}

output "lifecycle_policy_arns" {
  description = "ARNs of the retention policies, one per lineage"
  value       = { for k, v in aws_imagebuilder_lifecycle_policy.golden_images : k => v.arn }
}

# ---------------------------------------------------------------------------
# WHAT IS MISSING FOR RETENTION TO ACTUALLY WORK
#
# The policies are ENABLED and correct, but they do NOT SELECT ANYTHING yet,
# because the IMAGE resource of the Image Builder is born without tags.
#
# The three resource layers and who reads what:
#
#   Image Builder IMAGE resource  -> NO tags  -> THIS is what retention reads
#   output AMI                    -> tagged   -> not read by retention
#   snapshot                      -> tagged   -> not read by retention
#
# The AMI and snapshot tags serve for INVENTORY and the Cost Explorer, and for
# that they are useful: they let you separate snapshot cost by lineage. But the
# policy's selection evaluates only the image resource.
#
# FOR EACH BUILD, tag the image resource:
#
#   aws imagebuilder tag-resource `
#     --resource-arn "arn:aws:imagebuilder:us-west-2:111122223333:image/<name>/<version>/1" `
#     --tags "acme:cost-allocation:Application=<lineage>" `
#     --profile acme-swe-prod
#
# Valid lineages, which must match the keys of retention_lineages:
#   ubuntu-2604-x86 . ubuntu-2604-arm64 . docker-ubuntu-2604-x86
#
# The image resource tagging Lambda automates this generically: it reads the
# image's recipe (image.imageRecipe.arn), takes its tags - which Terraform
# already creates complete - and copies them to the image. It needs no lineage
# table, and any future image works on its own. It was not implemented: with
# manual triggering and few images, tagging by hand is more honest than keeping
# code around.
#
# HOW TO CHECK after a policy's first run:
#   aws imagebuilder list-lifecycle-execution-resources \
#     --lifecycle-execution-id <id>
# It shows exactly what it marked. Worth looking BEFORE trusting it with
# several accumulated versions.
# ---------------------------------------------------------------------------
