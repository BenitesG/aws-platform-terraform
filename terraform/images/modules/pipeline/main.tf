# ---------------------------------------------------------------------------
# modules/pipeline/main.tf
#
# The pipeline ties recipe + infrastructure + distribution together.
#
# There is NO resource here to "run the build". A build is an ACTION, not
# state:
#
#   aws imagebuilder start-image-pipeline-execution --image-pipeline-arn <arn>
#
# There is an aws_imagebuilder_image resource that triggers a build, but do
# not use it: each new version would make Terraform want to replace the
# resource, mixing "defining the pipeline" with "running the pipeline".
# Execution stays in the CI pipeline.
# ---------------------------------------------------------------------------

resource "aws_imagebuilder_image_pipeline" "this" {
  name        = var.name
  description = var.description
  status      = var.status

  image_recipe_arn                 = var.recipe_arn
  infrastructure_configuration_arn = var.infrastructure_arn

  # REQUIRED to pass, unlike the team's reference example, which omits it.
  # Without a distribution configuration the AMI and the snapshot are born
  # WITHOUT the standard tags, and the image retention policy - which selects
  # by tag - stops finding the images.
  distribution_configuration_arn = var.distribution_arn

  # The test phase runs on an instance launched from the ALREADY-FINISHED AMI.
  # It is what distinguishes "image created" from "image that provably boots"
  # - the base's simple-boot-test-linux passed on the first build.
  image_tests_configuration {
    image_tests_enabled = var.image_tests_enabled
    timeout_minutes     = var.image_tests_timeout
  }

  # Lineage tags, merged on top of the provider's default_tags.
  #
  # A tag declared on the resource BEATS default_tags, so you only need to
  # declare what differs - no need to repeat the nine.
  #
  # ATTENTION: this does NOT feed the retention policy. The policy's selection
  # evaluates tags on the IMAGE resource of the Image Builder, and a pipeline
  # tag does not propagate to it (verified in practice). Here the tag serves
  # for inventory. See the note at the end of lifecycle.tf.
  tags = var.extra_tags

  # No "schedule": manual trigger. The monthly patch-rebuild scheduling comes
  # in when the cadence is decided.
  #
  # ORDER MATTERS: do not turn on scheduling before the retention policy is
  # working, or each monthly build leaves a 20 GB snapshot that nobody deletes.
  #
  # CURRENT STATE: retention IS working. The permissions boundary was unlocked
  # (v2, with "image*" in the iam:PassedToService condition), the per-lineage
  # policies are ENABLED, and the image resources were tagged. What is MISSING
  # is automation: the image resource is born without tags, and today the
  # tag-resource is manual after each build. As long as it is manual,
  # scheduling should not be turned on - a scheduled build goes unwatched, and
  # an untagged image falls outside the policy silently. That is what the image
  # resource tagging Lambda solves.
  dynamic "schedule" {
    for_each = var.schedule != null ? [var.schedule] : []

    content {
      schedule_expression                = schedule.value.expression
      pipeline_execution_start_condition = schedule.value.start_condition
    }
  }
}
