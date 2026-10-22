# ---------------------------------------------------------------------------
# modules/distribution/main.tf
#
# Where the AMI goes and HOW IT IS TAGGED.
#
# THIS MODULE DOES NOT EXIST in the team's reference repository, and the
# example there does not pass distribution_arn to the pipeline. The
# consequence is concrete:
#
#   - the AMI and the snapshot are born WITHOUT the standard tags
#   - and the image retention policy stops working, because it selects by tag
#     (resource_selection.tag_map Application = golden-image). An image without
#     the tag falls outside the policy and accumulates without limit, silently
#
# ami_tags is the ONLY place that tags the AMI and the snapshot. The provider's
# default_tags reaches neither of them, because the Image Builder is the one
# that creates them during the build, not Terraform.
#
# VERIFIED IN PRACTICE: the ami_tags tags propagate ALSO to the EBS snapshot -
# confirmed on a snapshot (snap-0123456789abcdef0), which came with all
# thirteen tags. No extra handling is needed for the snapshot, and the earlier
# documentation that said otherwise was wrong.
# ---------------------------------------------------------------------------

# A CHILD module declares the constraint of the provider it uses, but never a
# provider block: the configuration - region, profile, default_tags - is
# inherited from the root. Without this declaration the module carries no
# compatibility contract of its own, and the constraint that applies is
# whatever the caller happens to have. It must match the root: a divergence
# here fails at init, on the caller's side, with a message that names the
# module and not the cause.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_imagebuilder_distribution_configuration" "this" {
  name        = var.name
  description = var.description

  distribution {
    region = var.region

    ami_distribution_configuration {
      # {{ imagebuilder:buildDate }} is substituted by the service at build
      # time, so each AMI comes out with a unique name.
      name = "${var.name}-{{ imagebuilder:buildDate }}"

      # Standard tags plus traceability.
      #
      # RecipeVersion and ParentImage answer "where did this AMI come from",
      # which is the question of any future diagnosis. In the case of the
      # stacked image, ParentImage is the AMI of our own base image - and that
      # is how the chain becomes auditable.
      ami_tags = merge(
        var.common_tags,
        {
          Name          = var.name
          RecipeVersion = var.recipe_version
          ParentImage   = var.parent_image
        },
        var.extra_ami_tags
      )

      # Who the AMI is shared with. Empty = this account only.
      #
      # Sharing across accounts would require a CMK: a snapshot encrypted with
      # the aws/ebs managed key is NOT shareable. That is what will be needed
      # when the images move to the future shared-services account - building
      # here is provisional.
      target_account_ids = length(var.target_account_ids) > 0 ? var.target_account_ids : null
    }
  }
}
