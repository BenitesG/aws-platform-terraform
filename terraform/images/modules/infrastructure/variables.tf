# ---------------------------------------------------------------------------
# modules/infrastructure/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Infrastructure configuration name"
  type        = string
}

variable "description" {
  description = <<-EOT
    Description of the infrastructure configuration.

    Default null on purpose: the existing configuration was created without a
    description, and keeping null guarantees a ZERO diff on the refactor.
  EOT
  type        = string
  default     = null
}

# --- IAM -------------------------------------------------------------------

variable "role_name" {
  description = <<-EOT
    Name of the build instance role.

    MUST start with "delegated-". The DelegatedAdminBoundary only allows
    creating a role in arn:aws:iam::*:role/delegated-*; outside the prefix,
    CreateRole is denied.
  EOT
  type        = string

  validation {
    condition     = startswith(var.role_name, "delegated-")
    error_message = "The role name must start with 'delegated-' because of the DelegatedAdminBoundary."
  }
}

variable "instance_profile_name" {
  description = <<-EOT
    Instance profile name.

    MUST start with "delegated-", for the same reason as the role: the
    boundary restricts it to arn:aws:iam::*:instance-profile/delegated-*.
  EOT
  type        = string

  validation {
    condition     = startswith(var.instance_profile_name, "delegated-")
    error_message = "The instance profile name must start with 'delegated-'."
  }
}

variable "permissions_boundary_arn" {
  description = <<-EOT
    ARN of the permissions boundary required for roles created by delegation.

    Without this the CreateRole is DENIED, and the error does not mention the
    boundary.
  EOT
  type        = string
}

# --- Network ---------------------------------------------------------------

variable "vpc_id" {
  description = "VPC where the build security group is created"
  type        = string
}

variable "subnet_id" {
  description = <<-EOT
    Subnet of the temporary build instance. Needs EGRESS to the internet
    (through the NAT) for SSM and to download packages.

    Required in this account: there is NO default VPC in any region, so
    omitting it does not fall back to anywhere - the build fails for lack of a
    network.
  EOT
  type        = string
}

variable "security_group_name" {
  description = "Build security group name, following the acme-{scope}-{environment}-{purpose} pattern"
  type        = string
}

# --- Build instance --------------------------------------------------------

variable "instance_types" {
  description = "Accepted types for the build instance. Must match the image's architecture."
  type        = list(string)
}

variable "terminate_instance_on_failure" {
  description = <<-EOT
    Bring the instance down when the build fails.

    Keep it true. false leaves an EC2 running indefinitely, with the instance
    profile attached, if the build fails after hours. Switch to false
    TEMPORARILY to investigate a failure from the inside.
  EOT
  type        = bool
  default     = true
}

variable "resource_tags" {
  description = <<-EOT
    Tags for the build INSTANCE and its volume.

    Different from tags: the provider's default_tags does not reach these
    resources, because the service is the one that creates them, not
    Terraform.
  EOT
  type        = map(string)
  default     = {}
}

# --- Optional --------------------------------------------------------------

variable "sns_topic_arn" {
  description = "SNS topic for build notification. null turns it off."
  type        = string
  default     = null
}

variable "s3_logs_bucket" {
  description = <<-EOT
    Bucket for the build log. null turns it off, which is the default.

    The component log already goes to CloudWatch Logs in
    /aws/imagebuilder/<image-name> with no configuration at all.
  EOT
  type        = string
  default     = null
}

variable "s3_logs_prefix" {
  description = "Prefix for the S3 log keys. Only used if s3_logs_bucket is set."
  type        = string
  default     = "imagebuilder"
}
