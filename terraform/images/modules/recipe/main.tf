# ---------------------------------------------------------------------------
# modules/recipe/main.tf
#
# The recipe for ONE image: parent image + ordered list of components + disk.
#
# If you think in Docker, the parent image is the FROM and the components are
# the RUNs.
# ---------------------------------------------------------------------------

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
