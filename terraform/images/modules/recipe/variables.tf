# ---------------------------------------------------------------------------
# modules/recipe/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Recipe name. By convention, the same as the image's."
  type        = string
}

variable "recipe_version" {
  description = <<-EOT
    Semantic version of the recipe (e.g., "1.0.2").

    It is called recipe_version and not "version" because "version" is a
    RESERVED argument in a module block.

    BUMP IT BY HAND, together with the component's: the component ARN includes
    its version, so changing a component changes the recipe - and the recipe
    is immutable. Forgetting makes the apply change nothing and look like it
    updated.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.recipe_version))
    error_message = "Use a semantic version with three numbers, for example 1.0.0."
  }
}

variable "parent_image" {
  description = <<-EOT
    Source AMI.

    THE ARCHITECTURE IS BAKED IN HERE: an x86_64 image does not run on an ARM
    instance and vice versa.

    It can be a public AMI (Canonical) or one of our golden images - that is
    how you STACK images, which is the pattern adopted for the fleet: the
    container host is guaranteed to be the base image plus Docker.
  EOT
  type        = string
}

variable "component_arns" {
  description = <<-EOT
    Component ARNs, IN THE ORDER OF EXECUTION.

    The cleanup component must be the LAST.

    In a MANAGED component ARN, the "x.x.x" is not a placeholder: it is the
    Image Builder syntax for "the latest version".
  EOT
  type        = list(string)
}

variable "description" {
  description = "What the image contains"
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Size of the image's root disk, in GB"
  type        = number
  default     = 20
}

variable "root_device_name" {
  description = "Root device name. /dev/sda1 on Ubuntu AMIs; /dev/xvda on Amazon Linux."
  type        = string
  default     = "/dev/sda1"
}
