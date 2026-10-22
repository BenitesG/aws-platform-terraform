# ---------------------------------------------------------------------------
# modules/distribution/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Distribution configuration name. By convention, the same as the image's."
  type        = string
}

variable "region" {
  description = "Target region of the AMI"
  type        = string
}

variable "recipe_version" {
  description = "Recipe version, recorded in the AMI's RecipeVersion tag"
  type        = string
}

variable "parent_image" {
  description = <<-EOT
    Parent AMI, recorded in the ParentImage tag.

    In the stacked image this value is the AMI of our own base image, which
    makes the chain auditable: looking at the container host AMI, you can tell
    exactly which base it was born from.
  EOT
  type        = string
}

variable "common_tags" {
  description = <<-EOT
    Standard tags, applied to the AMI and the snapshot.

    They have to be passed explicitly: the provider's default_tags reaches
    neither of them, because the Image Builder is the one that creates them.
  EOT
  type        = map(string)
  default     = {}
}

variable "extra_ami_tags" {
  description = "Additional tags specific to this image (e.g., DockerVersion)"
  type        = map(string)
  default     = {}
}

variable "description" {
  description = "Description of the distribution configuration"
  type        = string
  default     = null
}

variable "target_account_ids" {
  description = <<-EOT
    Accounts the AMI is shared with. Empty = this account only.

    ATTENTION: sharing across accounts requires a CMK. A snapshot encrypted
    with the aws/ebs managed key is NOT shareable.
  EOT
  type        = list(string)
  default     = []
}
