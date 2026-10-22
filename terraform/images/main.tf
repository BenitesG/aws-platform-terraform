# ---------------------------------------------------------------------------
# images/main.tf
#
# Public parent AMI and our OWN COMPONENTS, shared across recipes.
#
# Directory map:
#   main.tf (this one)  parent AMI and components
#   infrastructure.tf   where the build runs (IAM, SG, infrastructure config)
#   images.tf           the four lineages: base and container host, x86 and arm64
#   variables.tf        variable declarations (values in the tfvars)
#   outputs.tf          ARNs to trigger the builds
#   lifecycle.tf        retention - ACTIVE, 4 policies (one per lineage)
#   components/         the AWSTOE documents in YAML
#   modules/            component, recipe, distribution, infrastructure, pipeline
# ---------------------------------------------------------------------------

# "data" creates nothing: it only READS information that already exists in AWS.
# Here it reads the ID of the official Ubuntu AMI that Canonical publishes in a
# public SSM parameter, which makes the reference follow the image's
# republication.
#
# The architecture is in the parameter's PATH. Defined default: amd64. For
# Graviton it would be ".../arm64/hvm/ebs-gp3/ami-id" - and the resulting image
# would NOT run on a t3a instance, because the architecture is baked into the
# AMI.
#
# IF THIS data source ERRORS, the parameter path may have changed. Workaround:
# replace it with a variable holding the AMI ID.
# "data" creates nothing: it only READS information that already exists in AWS.
# Here it reads the ID of the official Ubuntu AMI that Canonical publishes in a
# public SSM parameter.
#
# ATTENTION: THIS DOES NOT FEED THE RECIPES.
#
# The parameter points to "the CURRENT one" and changes on its own when
# Canonical republishes - on 2026-10-16 that happened at 03:20. Since
# parent_image is ForceNew in an Image Builder recipe, using this value
# directly made Terraform want to REPLACE the recipes on every republication,
# with no one having changed anything. And the replacement would FAIL, because
# a recipe referenced by an already-built image cannot be removed.
#
# The recipes use var.base_parent_ami_amd64 and var.base_parent_ami_arm64,
# pinned in the tfvars. These data sources serve to CONSULT which one is
# current when you want to update deliberately - see the outputs
# parent_ami_ubuntu_disponivel and parent_ami_ubuntu_arm64_disponivel.
#
# The architecture is in the parameter's PATH. Defined default: amd64.
#
# IF IT ERRORS here, the parameter path may have changed. Since it no longer
# feeds anything critical, it can be removed without breaking the recipes.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/${var.ubuntu_version}/stable/current/${var.architecture}/hvm/ebs-gp3/ami-id"
}

data "aws_ssm_parameter" "ubuntu_arm64" {
  name = "/aws/service/canonical/ubuntu/server/${var.ubuntu_version}/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

# ---------------------------------------------------------------------------
# Our own components
#
# One component per module. Shared across the recipes: acme-cleanup runs on
# both lineages, and it is always the LAST in the list.
#
# VALIDATE THE YAML LOCALLY before the apply - a build costs 15 to 25 minutes
# to find a syntax error:
#   ./awstoe validate --documents components/docker.yml
# ---------------------------------------------------------------------------

module "component_timezone" {
  source = "./modules/component"

  name = "acme-timezone"

  # NO description, and this is NOT an oversight.
  #
  # In aws_imagebuilder_component the description is also ForceNew, because a
  # component is immutable. The component that exists today was created without
  # a description: adding one REPLACES it, which changes its ARN - and the
  # component ARN is part of the recipe, so the base recipe would be replaced
  # in cascade and would fail with ResourceDependencyException.
  #
  # Discovered in the plan of this refactor, which flagged "forces
  # replacement".
  #
  # NOTE: the version was bumped to 1.0.1 and, therefore, the component IS
  # being replaced in this cycle. Even so the description stays out, on purpose
  # - adding it now brings nothing and would make the diff larger for no
  # reason. The place to record what the component does is the YAML, which has
  # the full diagnosis at the top.

  # 1.0.1 - adds the AWS time source (169.254.169.123) and removes Canonical's
  # NTS pools, which require TCP 4460 and are unreachable with egress
  # restricted to 443/80. Full diagnosis in components/timezone.yml.
  #
  # BUMPING THIS VERSION FORCES bumping the recipe_version of the lineages that
  # consume it - base x86 and base arm64. The children inherit it through the
  # parent image and do not need to be touched.
  component_version = "1.0.1"

  data = file("${path.module}/components/timezone.yml")
}

module "component_cleanup" {
  source = "./modules/component"

  name = "acme-cleanup"

  # No description, for the same reason as timezone: it would be a cascade
  # replace.

  # 1.0.2: the sshd validation became a NON-BLOCKING diagnostic.
  #   1.0.0 failed on "sshd -t" with 255; I assumed it required an absolute path
  #   1.0.1 failed on "/usr/sbin/sshd -t" with 255 - wrong hypothesis
  #   1.0.2 prints the diagnostic to the log without bringing the build down
  #
  # The real cause was environmental: /run is tmpfs and /run/sshd only exists
  # when the service comes up - and ssh.service is DISABLED because of socket
  # activation. It was not a configuration error.
  #
  # KNOWN IMPROVEMENT, not yet applied: the steps RemoveSshHostKeys,
  # ResetMachineId and CleanCloudInit are redundant, because the Image Builder
  # itself runs a RunSanitizeScript before the snapshot. Simplifying would
  # require bumping this version and that of the two recipes - worth doing
  # together with the next real change, not in a build just for it.
  component_version = "1.0.2"

  data = file("${path.module}/components/cleanup.yml")
}

module "component_docker" {
  source = "./modules/component"

  name        = "acme-docker"
  description = "Docker Engine with log limit and live-restore"

  # 1.0.2: the validation was SIMPLIFIED.
  #
  # 1.0.1 had a step that started a container and read the LogConfig with
  # "grep -A3". The 3-line window cut off before the max-size, and build
  # 1.0.1/1 was REJECTED by mistake - the configuration was correct (max-file:
  # 3 appeared in the log, proving the inheritance).
  #
  # ONE check is left: "Live Restore Enabled: true" in docker info, which only
  # shows up if it came from the daemon.json. If the daemon read the file, it
  # read the log-opts too - they are in the same file. A complicated checker
  # becomes a source of failure instead of a detector: of the 3 build
  # failures, 1 was a real bug and 2 were the checker itself.
  #
  # History of previous versions:
  # 1.0.1 - daemon.json started being written BEFORE the apt install (the "apt
  #         install" already starts the daemon, and configuration that only
  #         applies to resources created afterwards does not reach what it
  #         already created), and the custom default-address-pools was REMOVED,
  #         going back to the Docker default. See the note at the end of
  #         components/docker.yml.
  component_version = "1.0.2"

  data = file("${path.module}/components/docker.yml")
}
