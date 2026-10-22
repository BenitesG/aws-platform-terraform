# ---------------------------------------------------------------------------
# images/variables.tf
#
# Variable declarations: name, type and description. The VALUES live in
# terraform.tfvars, which does not go to git.
#
# A variable without a "default" is required: Terraform asks for it in the
# terminal if you do not provide it. A variable with a default is optional.
# ---------------------------------------------------------------------------

variable "aws_profile" {
  description = "AWS CLI profile (SSO). Must be the DelegatedAdministrator because of the IAM."
  type        = string
}

variable "region" {
  description = "Region where the image is built and distributed"
  type        = string
  default     = "us-west-2"
}

variable "ubuntu_version" {
  description = <<-EOT
    Ubuntu LTS version used as the parent image (e.g., "26.04").

    USE ONLY LTS. The interim releases (24.10, 25.04, 25.10) have 9 months of
    support and are not fit for a server.

    26.04 LTS (resolute) has standard support until 2031; 24.04 (noble), until
    2029.

    KNOWN RISK when using the newest LTS: THIRD-PARTY repositories often take
    months to publish a package for the new codename. It affects the
    patch-rebuild cadence - the managed component docker-ce-ubuntu depends on
    Docker having a channel for "resolute". If it is missing, the container
    host build fails.
  EOT
  type        = string
  default     = "26.04"
}

variable "architecture" {
  description = <<-EOT
    Image architecture: "amd64" (x86_64, t3a instances) or "arm64" (Graviton,
    t4g instances).

    Defined default for the fleet: amd64.

    The architecture is BAKED INTO THE AMI - an amd64 image does not run on t4g
    and an arm64 image does not run on t3a. Changing it requires rebuilding the
    image and also changing the build instance type.
  EOT
  type        = string
  default     = "amd64"

  validation {
    condition     = contains(["amd64", "arm64"], var.architecture)
    error_message = "architecture must be amd64 or arm64."
  }
}

variable "build_subnet_id" {
  description = "Subnet of the temporary build instance. Needs egress to the internet (NAT)."
  type        = string
}

variable "vpc_id" {
  description = "VPC where the build instance security group is created"
  type        = string
}

variable "build_instance_type" {
  description = "Type of the temporary build instance. Must match the architecture."
  type        = string
  default     = "t3a.small"
}

variable "build_instance_type_arm64" {
  description = <<-EOT
    Build instance type for the ARM64 images.

    MUST be a Graviton family (t4g, m6g, c7g). The build instance runs the
    parent image, and the architecture is baked into the AMI - t3a cannot
    build an arm64 image.
  EOT
  type        = string
  default     = "t4g.small"
}

variable "permissions_boundary_arn" {
  description = "ARN of the permissions boundary required for roles created by delegation"
  type        = string
}

variable "root_volume_size" {
  description = "Size of the image's root disk, in GB"
  type        = number
  default     = 20
}

variable "arm64_root_volume_size" {
  description = <<-EOT
    Size of the ARM64 image's root disk, in GB.

    Separate from root_volume_size because the ARM lineage asked for 30 GB. The
    IMAGE disk is the minimum disk size of the instance: you cannot launch an
    instance with a disk smaller than the AMI's, only larger.
  EOT
  type        = number
  default     = 30
}

variable "base_parent_ami_amd64" {
  description = <<-EOT
    Parent AMI of the base amd64 lineage.

    PINNED ON PURPOSE, and this is NOT redundant with the SSM data source.

    Canonical's public parameter points to "the CURRENT one", and it changes
    on its own when they republish - on 2026-10-16 that happened at 03:20.
    Since parent_image is ForceNew in an Image Builder recipe, a dynamic value
    makes Terraform want to REPLACE the recipe on every republication, with no
    one having changed anything.

    And the replacement would FAIL: a recipe referenced by an already-built
    image cannot be removed (ResourceDependencyException). The apply would
    abort midway.

    It is the same reason the instances' ami_id is pinned - see the comment on
    the variable in the ec2-instance module.

    UPDATING IS A DELIBERATE ACT: changing this value replaces the recipe, so
    bump the recipe_version along with it. To find out which one is current,
    use the output parent_ami_ubuntu_disponivel.
  EOT
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.base_parent_ami_amd64))
    error_message = "Expected format: ami-0123456789abcdef0."
  }
}

variable "base_parent_ami_arm64" {
  description = <<-EOT
    Parent AMI of the base arm64 (Graviton) lineage.

    Pinned for the same reason as amd64 - see above. It must be an arm64 AMI;
    an amd64 image does not run on t4g and vice versa, because the architecture
    is baked into the AMI.
  EOT
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.base_parent_ami_arm64))
    error_message = "Expected format: ami-0123456789abcdef0."
  }
}

variable "base_arm64_ami_id" {
  description = <<-EOT
    AMI of OUR ARM64 base image, used as the parent image of the Graviton
    container host.

    SAME LOGIC as base_ami_id, with the difference that matters: YOU CANNOT
    STACK ACROSS ARCHITECTURES. The architecture is baked into the AMI, so the
    arm64 container host has to start from the arm64 base - using the x86 base
    as parent would produce an image that does not boot on t4g.

    WHY THIS LINEAGE EXISTS: the integration worker (dataflow) is t4g and had
    Docker installed BY HAND after launch, because there was no ARM container
    host image. The practical consequence is that it runs without the
    component's daemon.json - no log rotation, on a 30 GB disk, which is the
    most likely failure mode of that machine.

    PINNED ON PURPOSE, for the same reason as base_ami_id.
  EOT
  type        = string
}

variable "base_ami_id" {
  description = <<-EOT
    AMI of OUR base image, used as the parent image of the container host.

    Stack instead of repeating components: the Docker image is guaranteed to be
    the base plus Docker, not "the two built with the same components on
    different dates".

    PINNED ON PURPOSE, same reason as the instances' ami_id. A
    data "aws_ami" with most_recent = true looks convenient and is dangerous:
    a new base build would change the value, and the next apply - even one done
    for something else - would replace the container host recipe with no one
    asking.

    Changing it is a deliberate act: you change this value knowing the recipe
    will be replaced and that the Docker lineage's recipe_version needs to be
    bumped.

    To find the most recent base AMI:
      aws ec2 describe-images --owners self \
        --filters "Name=tag:ImageRole,Values=" "Name=name,Values=acme-base-ubuntu-*" \
        --query "sort_by(Images,&CreationDate)[-1].ImageId" --output text
  EOT
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.base_ami_id))
    error_message = "Expected format: ami-0123456789abcdef0."
  }
}

variable "common_tags" {
  description = "Standard tags, applied to all resources via the provider's default_tags"
  type        = map(string)
}
