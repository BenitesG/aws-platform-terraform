# ---------------------------------------------------------------------------
# images/infrastructure.tf
#
# WHERE the builds run. Shared by all images: role, instance profile, security
# group and the infrastructure configuration.
#
# A single configuration for both lineages on purpose. If each image had its
# own, there would be two roles and two security groups doing the same thing -
# and two places to forget to update.
# ---------------------------------------------------------------------------

module "build_infrastructure" {
  source = "./modules/infrastructure"

  name = "acme-swe-prod-images-build"

  # Names with the "delegated-" prefix because the DelegatedAdminBoundary only
  # allows creating IAM inside it. The module validates this and fails at the
  # plan, not at the apply - a name error never turns into an AccessDenied from
  # AWS.
  role_name             = "delegated-imagebuilder"
  instance_profile_name = "delegated-imagebuilder"

  permissions_boundary_arn = var.permissions_boundary_arn

  vpc_id              = var.vpc_id
  subnet_id           = var.build_subnet_id
  security_group_name = "acme-swe-prod-images-build-sg"

  instance_types = [var.build_instance_type]

  # true: brings the build instance down if the build fails. Switch to false
  # TEMPORARILY to investigate a failure from inside the machine.
  terminate_instance_on_failure = true

  # Tags of the TEMPORARY build instance and its volume. Without this, the
  # build hours would show up in the cost report with no allocation.
  resource_tags = var.common_tags

  # Build notification off for now. Turn it on by passing the alarm topic:
  #   sns_topic_arn = "arn:aws:sns:us-west-2:111122223333:acme-swe-prod-alarms"
  #
  # Think first: the topic is the same as the infrastructure alarms, and a
  # successful-build notification would become noise in a channel that needs to
  # be taken seriously. If you turn it on, consider a dedicated topic.
  sns_topic_arn = null

  # S3 logging off. The Image Builder already writes the component log to
  # CloudWatch Logs in /aws/imagebuilder/<image-name>, and that is where the
  # diagnosis of the builds that failed in the first cycles came from.
  s3_logs_bucket = null
}

# ---------------------------------------------------------------------------
# Infrastructure configuration for ARM64 (Graviton) builds
#
# WHY A SECOND ONE: the build instance has to RUN the parent image, and the
# architecture is baked into the AMI. Building an arm64 image requires an arm64
# instance (t4g); you cannot use t3a. And you cannot list both types in the
# same configuration: the Image Builder would pick one and the build would
# fail when the choice did not match the parent image's architecture.
#
# WHY IT IS NOT A SECOND CALL OF THE MODULE: the module also creates the role,
# the instance profile and the security group, and calling it twice would try
# to create two IAM objects with the same name. Those resources do NOT depend
# on the architecture, so they are reused from the module - here only
# instance_types changes.
#
# When there is a third build variation, it is worth extracting the
# infrastructure configuration from the module into its own for_each. With two,
# duplicating is simpler to read than generalizing.
# ---------------------------------------------------------------------------

resource "aws_imagebuilder_infrastructure_configuration" "build_arm64" {
  name = "acme-swe-prod-images-build-arm64"

  instance_profile_name = module.build_infrastructure.instance_profile_name
  instance_types        = [var.build_instance_type_arm64]

  subnet_id          = var.build_subnet_id
  security_group_ids = [module.build_infrastructure.security_group_id]

  # Tags of the TEMPORARY build instance and its volume - the provider's
  # default_tags does not reach them, because the service is the one that
  # creates them.
  resource_tags = var.common_tags

  terminate_instance_on_failure = true
}
