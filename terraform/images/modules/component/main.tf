# ---------------------------------------------------------------------------
# modules/component/main.tf
#
# ONE AWSTOE component from a YAML document.
#
# A component is IMMUTABLE: the ARN includes the version. Changing the YAML
# does not create a new version on its own - you must bump component_version
# by hand. Forgetting makes the apply change nothing and look like it updated.
#
# VALIDATE THE YAML LOCALLY BEFORE THE APPLY. A build costs 15 to 25 minutes
# to find a syntax error:
#
#   curl -O https://awstoe-us-west-2.s3.us-west-2.amazonaws.com/latest/linux/amd64/awstoe
#   chmod +x awstoe
#   ./awstoe validate --documents components/docker.yml
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

resource "aws_imagebuilder_component" "this" {
  name        = var.name
  platform    = var.platform
  version     = var.component_version
  description = var.description

  data = var.data

  # Supported OS versions. Empty = all.
  #
  # We do not restrict by default: our own component is written for the
  # company standard, and a list here would become one more place to forget to
  # update when the Ubuntu version changes.
  supported_os_versions = length(var.supported_os_versions) > 0 ? var.supported_os_versions : null

  # REQUIRED, not a refinement.
  #
  # The old component version cannot be deleted while a RECIPE still points to
  # it - nor while there is an image version referencing it, INCLUDING a build
  # that failed. By default Terraform destroys before creating, and the
  # removal fails with ResourceDependencyException.
  #
  # With create_before_destroy the order inverts: it creates the new version,
  # the recipes start pointing at it, and only then does the old one go.
  lifecycle {
    create_before_destroy = true
  }
}
