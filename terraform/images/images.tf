# ---------------------------------------------------------------------------
# images/images.tf
#
# The image lineages. Each one is three modules: recipe, distribution and
# pipeline.
#
# Why three calls instead of one "image" module wrapping all three: because
# recipe, distribution and pipeline have different lifecycles. A new recipe
# does not require a new distribution; a distribution can be shared. Wrapping
# all three was what the old image-pipeline module did, and it was what
# prevented stacking images without duplicating code.
#
# ===========================================================================
# THE HIERARCHY
# ===========================================================================
#
#   Canonical Ubuntu 26.04  (public SSM parameter)
#            |
#            v
#   acme-base-ubuntu-2604        update-linux, timezone, cloudwatch-agent, cleanup
#            |
#            v
#   acme-docker-host-ubuntu-2604 update-linux, docker, cleanup
#
# STACK, don't repeat. The container host image uses the AMI of our base image
# as the parent image, so it is GUARANTEED to be the base plus Docker - not
# "the base and the container host built with the same components on different
# dates", which could start from different patch levels.
#
# The sentence you want to be able to say: "every server is the base image;
# some have more stuff".
#
# In exchange, it creates a dependency chain: the Docker image is as old as the
# base it started from, and rebuilding the base does not update the child on
# its own.
# ===========================================================================

# ---------------------------------------------------------------------------
# Lineage 1 - base image
#
# Name derived from the version: "26.04" becomes "acme-base-ubuntu-2604".
# Changing the version generates a NEW LINEAGE - new recipe, distribution and
# pipeline - which is the correct behavior: a different OS version is not an
# update of the same image.
# ---------------------------------------------------------------------------

locals {
  base_name         = "acme-base-ubuntu-${replace(var.ubuntu_version, ".", "")}"
  docker_name       = "acme-docker-host-ubuntu-${replace(var.ubuntu_version, ".", "")}"
  base_arm64_name   = "acme-base-ubuntu-${replace(var.ubuntu_version, ".", "")}-arm64"
  docker_arm64_name = "acme-docker-host-ubuntu-${replace(var.ubuntu_version, ".", "")}-arm64"

  # PINNED parent AMIs, not the value of the SSM data source.
  #
  # WHY: Canonical's public parameter points to "the current one" and changes
  # on its own when they republish - it happened on 2026-10-16 at 03:20. Since
  # parent_image is ForceNew in a recipe, a dynamic value makes Terraform want
  # to REPLACE the recipes on every republication, and the replacement would
  # FAIL because there are images referencing them
  # (ResourceDependencyException).
  #
  # The data source still exists, but only to CONSULT which one is current - it
  # became an informational output, not a recipe input.
  parent_ami_ubuntu       = var.base_parent_ami_amd64
  parent_ami_ubuntu_arm64 = var.base_parent_ami_arm64
}

module "base_recipe" {
  source = "./modules/recipe"

  name = local.base_name

  # NO description, and this is NOT an oversight.
  #
  # A recipe is IMMUTABLE in the Image Builder: every argument is ForceNew. The
  # recipe that exists today was created without a description, so adding one
  # would make Terraform try to REPLACE it - and the replacement would fail
  # with ResourceDependencyException, because ami-0f66666666666666f references
  # this recipe.
  #
  # On the base lineage the diff has to be ZERO for the moved block to be a
  # MOVE. The Docker lineage, being new, has a description normally.

  # 1.0.3 - CYCLE OF 2026-10-19. Three changes in the same apply, on purpose:
  # pay the cost of the recipe replacement once instead of three times.
  #
  #   1. acme-timezone 1.0.1, with the AWS time source
  #   2. parent AMI updated to Canonical's 10-16 republication
  #   3. (consequence) OS patches accumulated since the previous cycle
  #
  # The previous comment said "DO NOT CHANGE in this refactor" - that applied
  # to the refactor into modules, where the diff had to be ZERO for the moved
  # blocks to be a MOVE and not a replace. That apply was completed and the
  # moved blocks have already been removed, so the restriction no longer
  # applies.
  recipe_version = "1.0.3"

  parent_image     = local.parent_ami_ubuntu
  root_volume_size = var.root_volume_size

  # THE ORDER IS THE ORDER OF EXECUTION. The cleanup is the LAST.
  #
  # The "x.x.x" in the managed components is not a placeholder: it is the Image
  # Builder syntax for "the latest version".
  #
  # Note on update-linux: it tries to install amazon-ssm-agent via apt and
  # fails with "E: Unable to locate package". It is HARMLESS - on Ubuntu the
  # agent is a snap and already ships in Canonical's AMI. The build proceeds
  # normally.
  component_arns = [
    "arn:aws:imagebuilder:${var.region}:aws:component/update-linux/x.x.x",
    module.component_timezone.arn,
    "arn:aws:imagebuilder:${var.region}:aws:component/amazon-cloudwatch-agent-linux/x.x.x",
    module.component_cleanup.arn,
  ]
}

module "base_distribution" {
  source = "./modules/distribution"

  # No description, for the same reason as the recipe: zero diff on the base
  # lineage.
  name           = local.base_name
  region         = var.region
  recipe_version = module.base_recipe.version
  parent_image   = module.base_recipe.parent_image
  common_tags    = var.common_tags

  # LINEAGE TAGS, aligned with what was applied by hand to the existing AMIs
  # and snapshots.
  #
  # WHY HERE: ami_tags is the ONLY place that tags the AMI and the snapshot.
  # The provider's default_tags reaches neither of them, because the service
  # is the one that creates them. Changing the tag in the console fixes the
  # resource that already exists, but the NEXT build comes back with the value
  # from the code - that was what was going to happen here.
  #
  # extra_ami_tags is merged LAST in the module, so it overrides the default
  # Name (which would be the resource name, without the architecture suffix).
  #
  # "x86" for brevity, understood as x86_64. What matters is consistency: the
  # Cost Explorer treats different spellings as different applications.
  extra_ami_tags = {
    Name                               = "${local.base_name}-x86"
    "acme:cost-allocation:Application" = "ubuntu-2604-x86"
  }
}

module "base_pipeline" {
  source = "./modules/pipeline"

  # No description: zero diff.
  name = local.base_name

  recipe_arn         = module.base_recipe.arn
  infrastructure_arn = module.build_infrastructure.arn
  distribution_arn   = module.base_distribution.arn

  # LINEAGE TAGS. The three pipelines had Application = golden-image, inherited
  # from default_tags, and were indistinguishable by tag - the same ambiguity
  # the AMIs and the retention policies resolved earlier.
  #
  # The value matches the distribution's extra_ami_tags and the key in
  # retention_lineages, on purpose: the three layers say the same thing.
  #
  # This is NOT what makes retention work - it reads the image resource, not
  # the pipeline. Here it is inventory.
  extra_tags = {
    "acme:cost-allocation:Application" = "ubuntu-2604-x86"
  }

  # Manual trigger. No schedule - the monthly scheduling comes in when the
  # rebuild cadence is decided AND the image resource tagging is automated by
  # the Lambda, because today it is manual after each build.
  schedule = null
}

# ---------------------------------------------------------------------------
# Lineage 2 - container host (Docker)
#
# STACKED on top of the base image.
#
# Docker does NOT go into the base image: the daemon runs as root and belonging
# to the "docker" group is equivalent to being root - you can mount the host
# filesystem inside a container. It should not be on a server that does not
# need it.
# ---------------------------------------------------------------------------

module "docker_host_recipe" {
  source = "./modules/recipe"

  name        = local.docker_name
  description = "Container host: base image plus Docker Engine with its own address pool"

  # 1.0.3 - phase 2 cycle, 10-19. Repoints to the NEW x86 base
  # (ami-0c33333333333333c), which brings the clock fix and the parent AMI
  # republished on 10-16.
  #
  # This is what RELEASES ami-0f66666666666666f for removal: it was the parent
  # image of this recipe, and that was the only reference holding it.
  #
  # THIS IS THE CLASSIC "TWO VERSIONS" CASE: the component ARN includes its
  # version, so changing the component CHANGES THE RECIPE. Bumping only the
  # component's would make the apply not change the recipe and the build keep
  # using the old version - with no error at all.
  recipe_version = "1.0.3"

  # THE PARENT IMAGE IS OUR OWN BASE AMI, not Ubuntu's.
  #
  # The value is PINNED and comes from the tfvars, on purpose - same reason the
  # instances' ami_id is pinned. A data "aws_ami" with most_recent = true looks
  # convenient and is dangerous: a new base build would change the value, and
  # the next apply - even one done for something else - would replace this
  # recipe with no one asking.
  #
  # Changing the base should be a deliberate act: you change the variable
  # knowing the recipe will be replaced and that the version needs to be
  # bumped.
  parent_image     = var.base_ami_id
  root_volume_size = var.root_volume_size

  # Does NOT repeat timezone nor the CloudWatch agent: they already came from
  # the base image and are on the disk. That is the gain of stacking.
  #
  # update-linux goes in AGAIN, on purpose: it picks up the patches published
  # between the base build and this build.
  #
  # cleanup ALSO goes in again, and this is easy to forget when stacking: the
  # build instance of this image is born from the base AMI and generates a NEW
  # identity on the first boot - SSH host keys, machine-id, cloud-init state.
  # Without running the cleanup again, that identity would go into the
  # snapshot.
  component_arns = [
    "arn:aws:imagebuilder:${var.region}:aws:component/update-linux/x.x.x",
    module.component_docker.arn,
    module.component_cleanup.arn,
  ]
}

module "docker_host_distribution" {
  source = "./modules/distribution"

  name           = local.docker_name
  description    = "Distribution of the container host image in us-west-2"
  region         = var.region
  recipe_version = module.docker_host_recipe.version

  # ParentImage receives the AMI of our base, which makes the chain auditable:
  # looking at the container host AMI, you can tell which base it was born
  # from.
  parent_image = module.docker_host_recipe.parent_image
  common_tags  = var.common_tags

  # Lineage tags, aligned with what was applied by hand.
  # See the note in base_distribution.
  extra_ami_tags = {
    Name                               = "${local.docker_name}-x86"
    "acme:cost-allocation:Application" = "docker-ubuntu-2604-x86"
    ImageRole                          = "docker-host"
  }
}

module "docker_host_pipeline" {
  source = "./modules/pipeline"

  name        = local.docker_name
  description = "Container host pipeline: base plus Docker"

  recipe_arn         = module.docker_host_recipe.arn
  infrastructure_arn = module.build_infrastructure.arn
  distribution_arn   = module.docker_host_distribution.arn

  # Lineage tag. See the note in base_pipeline.
  extra_tags = {
    "acme:cost-allocation:Application" = "docker-ubuntu-2604-x86"
  }

  schedule = null
}

# ---------------------------------------------------------------------------
# Lineage 3 - base image ARM64 (Graviton)
#
# For t4g instances. It is NOT a variation of the others: its own lineage,
# because the architecture is baked into the AMI and an amd64 image does not
# run on t4g.
#
# It starts from Canonical's public arm64 AMI, not from our amd64 base - you
# cannot stack across different architectures.
#
# It uses the ARM infrastructure configuration, because the build instance also
# needs to be Graviton.
#
# 30 GB disk, larger than the others' 20 GB.
# ---------------------------------------------------------------------------

module "base_arm64_recipe" {
  source = "./modules/recipe"

  name        = local.base_arm64_name
  description = "Base ARM64 (Graviton) image for t4g instances"

  # 1.0.1 - 10-19 cycle: acme-timezone 1.0.1 (AWS time source) and parent AMI
  # updated to Canonical's 10-16 republication.
  recipe_version = "1.0.1"

  parent_image     = local.parent_ami_ubuntu_arm64
  root_volume_size = var.arm64_root_volume_size

  # Same components as the amd64 base, on purpose: the fleet standard does not
  # change with the architecture. Our own components are shell scripts, which
  # run the same on both.
  #
  # The cleanup is always the LAST.
  #
  # NOTE on amazon-cloudwatch-agent-linux: the managed component has an arm64
  # version, so it works. If the build fails on it, check in the log whether
  # the message mentions architecture - that would be the first suspect.
  component_arns = [
    "arn:aws:imagebuilder:${var.region}:aws:component/update-linux/x.x.x",
    module.component_timezone.arn,
    "arn:aws:imagebuilder:${var.region}:aws:component/amazon-cloudwatch-agent-linux/x.x.x",
    module.component_cleanup.arn,
  ]
}

module "base_arm64_distribution" {
  source = "./modules/distribution"

  name           = local.base_arm64_name
  description    = "Distribution of the base ARM64 image in us-west-2"
  region         = var.region
  recipe_version = module.base_arm64_recipe.version
  parent_image   = module.base_arm64_recipe.parent_image
  common_tags    = var.common_tags

  # Lineage tags, aligned with what was applied by hand.
  # The Name already had the -arm64 suffix from the resource name; here it is
  # explicit next to the Application, so the three lineages follow the same
  # pattern.
  extra_ami_tags = {
    Name                               = local.base_arm64_name
    "acme:cost-allocation:Application" = "ubuntu-2604-arm64"
    Architecture                       = "arm64"
  }
}

module "base_arm64_pipeline" {
  source = "./modules/pipeline"

  name        = local.base_arm64_name
  description = "Base ARM64 (Graviton) image pipeline"

  recipe_arn = module.base_arm64_recipe.arn

  # The ARM infrastructure configuration, not the shared one.
  infrastructure_arn = aws_imagebuilder_infrastructure_configuration.build_arm64.arn
  distribution_arn   = module.base_arm64_distribution.arn

  # Lineage tag. See the note in base_pipeline.
  extra_tags = {
    "acme:cost-allocation:Application" = "ubuntu-2604-arm64"
  }

  schedule = null
}

# ---------------------------------------------------------------------------
# Lineage 4 - container host ARM64 (Graviton)
#
# CREATED ON 2026-10-19. It is the fourth and last lineage of the pattern: base
# and container host, in x86 and arm64.
#
# WHY IT NEEDED TO EXIST: the integration worker (dataflow) is t4g and had
# Docker installed BY HAND after launch, because there was no ARM container
# host image. The practical consequence is that it runs WITHOUT the component's
# daemon.json - without log rotation (max-size 10m, max-file 3) on a 30 GB
# disk. A container that logs a lot fills the disk and brings the machine down,
# with the symptom "the server stopped" and no obvious cause. It is the most
# likely failure mode of that instance today.
#
# YOU CANNOT STACK ACROSS ARCHITECTURES: it starts from the arm64 base, not the
# x86 one. The architecture is baked into the AMI.
#
# THE COMPONENTS ARE THE SAME as the x86 lineage, with no adaptation. Confirmed
# by inspection: docker.yml builds the repository line with
# "$(dpkg --print-architecture)", so it resolves arm64 on its own. Same with
# timezone and cleanup - they are shell scripts. It had already been proven
# when our own components ran on ARM with no change to the arm64 base.
# ---------------------------------------------------------------------------

module "docker_host_arm64_recipe" {
  source = "./modules/recipe"

  name        = local.docker_arm64_name
  description = "Container host ARM64 (Graviton): arm64 base image plus Docker Engine"

  recipe_version = "1.0.0"

  # The ARM64 base, not the x86 one. Pinned in the tfvars on purpose.
  parent_image     = var.base_arm64_ami_id
  root_volume_size = var.arm64_root_volume_size

  # Does NOT repeat timezone nor the CloudWatch agent: they already came from
  # the arm64 base.
  #
  # update-linux goes in AGAIN, on purpose: it picks up the patches published
  # between the base build and this build.
  #
  # cleanup ALSO goes in again - the build instance is born from the base AMI
  # and generates a NEW identity on the first boot (SSH host keys, machine-id,
  # cloud-init state). Without running the cleanup again, that identity would
  # go into the snapshot.
  component_arns = [
    "arn:aws:imagebuilder:${var.region}:aws:component/update-linux/x.x.x",
    module.component_docker.arn,
    module.component_cleanup.arn,
  ]
}

module "docker_host_arm64_distribution" {
  source = "./modules/distribution"

  name           = local.docker_arm64_name
  description    = "Distribution of the container host ARM64 image in us-west-2"
  region         = var.region
  recipe_version = module.docker_host_arm64_recipe.version

  # ParentImage receives the AMI of our arm64 base, which makes the chain
  # auditable: looking at the AMI, you can tell which base it was born from.
  parent_image = module.docker_host_arm64_recipe.parent_image
  common_tags  = var.common_tags

  # The Application tag MUST match the key in retention_lineages of
  # lifecycle.tf, otherwise the retention policy selects nothing - and it fails
  # silently, with no error at all.
  extra_ami_tags = {
    Name                               = local.docker_arm64_name
    "acme:cost-allocation:Application" = "docker-ubuntu-2604-arm64"
    ImageRole                          = "docker-host"
    Architecture                       = "arm64"
  }
}

module "docker_host_arm64_pipeline" {
  source = "./modules/pipeline"

  name        = local.docker_arm64_name
  description = "Container host ARM64 pipeline: arm64 base plus Docker"

  recipe_arn = module.docker_host_arm64_recipe.arn

  # The ARM infrastructure configuration, not the shared one: the build
  # instance also needs to be Graviton.
  infrastructure_arn = aws_imagebuilder_infrastructure_configuration.build_arm64.arn
  distribution_arn   = module.docker_host_arm64_distribution.arn

  extra_tags = {
    "acme:cost-allocation:Application" = "docker-ubuntu-2604-arm64"
  }

  schedule = null
}
