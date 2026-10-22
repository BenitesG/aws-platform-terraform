# ---------------------------------------------------------------------------
# modules/recipe/main.tf
#
# The recipe for ONE image: parent image + ordered list of components + disk.
#
# If you think in Docker, the parent image is the FROM and the components are
# the RUNs.
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

resource "aws_imagebuilder_image_recipe" "this" {
  name         = var.name
  version      = var.recipe_version
  parent_image = var.parent_image
  description  = var.description

  block_device_mapping {
    device_name = var.root_device_name

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # THE ORDER OF THE LIST IS THE ORDER OF EXECUTION.
  #
  # The cleanup component must be the LAST: it wipes the build machine's
  # identity (SSH host keys, machine-id, cloud-init state) and any component
  # after it would reintroduce residue into the snapshot.
  dynamic "component" {
    for_each = var.component_arns

    content {
      component_arn = component.value
    }
  }

  # REQUIRED here, not a refinement.
  #
  # A recipe is IMMUTABLE: changing the content generates a new version, and
  # the old one has to be removed. By default Terraform DESTROYS before
  # CREATING - and the old recipe cannot be deleted while the pipeline still
  # points to it, resulting in ResourceDependencyException.
  #
  # With create_before_destroy the order inverts: it creates the new version,
  # updates the pipeline to point at it, and only then removes the old one. It
  # works because the two versions coexist - the ARN includes the version.
  #
  # If the error shows up ANYWAY, what is holding the dependency is an IMAGE,
  # not the recipe - including a build that failed:
  #   aws imagebuilder delete-image --image-build-version-arn <arn>
  # The removal order is from the inside out: image, recipe, component.
  lifecycle {
    create_before_destroy = true
  }
}
