# ---------------------------------------------------------------------------
# modules/pipeline/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Pipeline name. By convention, the same as the image's."
  type        = string
}

variable "recipe_arn" {
  description = "Recipe ARN"
  type        = string
}

variable "infrastructure_arn" {
  description = "ARN of the shared infrastructure configuration"
  type        = string
}

variable "distribution_arn" {
  description = <<-EOT
    Distribution configuration ARN.

    REQUIRED. Without it the AMI and the snapshot are born without the
    standard tags and the image retention policy, which selects by tag, does
    not find them.
  EOT
  type        = string
}

variable "description" {
  description = "Pipeline description"
  type        = string
  default     = null
}

variable "status" {
  description = "ENABLED or DISABLED"
  type        = string
  default     = "ENABLED"

  validation {
    condition     = contains(["ENABLED", "DISABLED"], var.status)
    error_message = "status must be ENABLED or DISABLED."
  }
}

variable "image_tests_enabled" {
  description = "Run the test phase on an instance launched from the finished AMI"
  type        = bool
  default     = true
}

variable "image_tests_timeout" {
  description = "Maximum time of the test phase, in minutes"
  type        = number
  default     = 60
}

variable "extra_tags" {
  description = <<-EOT
    Tags specific to this lineage, merged on top of the provider's
    default_tags. A tag declared on the resource beats default_tags.

    WHY IT EXISTS: without it the pipeline's nine tags all came from
    default_tags, so the pipelines ended up with Application = golden-image and
    were indistinguishable by tag. The AMI, the snapshot and the retention
    policy already use the lineage value - the pipeline was the only layer
    still generic.

    DO NOT CONFUSE IT WITH RETENTION: a pipeline tag does NOT propagate to the
    Image Builder image resource, which is what the retention policy
    evaluates. Verified in practice. Here the tag serves for INVENTORY - a
    pipeline is a definition, not a billed resource, so it does not appear on
    the invoice.
  EOT
  type        = map(string)
  default     = {}
}

variable "schedule" {
  description = <<-EOT
    Build schedule. null = manual trigger, which is the default today.

    Do NOT turn it on before the retention policy works: each monthly build
    leaves a 20 GB snapshot that nobody deletes.

    Example:
      schedule = {
        expression      = "cron(0 3 1 * ? *)"
        start_condition = "EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE"
      }
  EOT
  type = object({
    expression      = string
    start_condition = string
  })
  default = null
}
