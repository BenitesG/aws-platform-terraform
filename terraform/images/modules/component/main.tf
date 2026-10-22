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
