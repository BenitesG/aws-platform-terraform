# ---------------------------------------------------------------------------
# network-peering/variables.tf
# ---------------------------------------------------------------------------

variable "aws_profile" {
  description = "AWS CLI profile (SSO)"
  type        = string
}

variable "region" {
  description = "Region"
  type        = string
  default     = "us-west-2"
}

# --- our side --------------------------------------------------------------

variable "vpc_id" {
  description = "acme-swe-prod-vpc. Built in the console, NOT managed by this code."
  type        = string
}

variable "private_route_table_id" {
  description = <<-EOT
    acme-swe-prod-rt-private, where the route to production goes.

    This route table was created in the console and is NOT in the Terraform
    state. aws_route manages ONE route inside an existing table, referenced by
    ID - it does not require the table to be under Terraform management. That
    is why the route can live in code without importing the network and
    without producing drift.
  EOT
  type        = string
}

# --- production side -------------------------------------------------------

variable "production_account_id" {
  description = "Production AWS account, 12 digits WITHOUT hyphens (the hyphens are a console presentation)"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.production_account_id))
    error_message = "Must be exactly 12 digits, no hyphens."
  }
}

variable "production_vpc_id" {
  description = "Production VPC that receives the peering request"
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.production_vpc_id))
    error_message = "Expected format: vpc-0123456789abcdef0."
  }
}

variable "production_vpc_cidr" {
  description = <<-EOT
    Production VPC CIDR. Destination of the route in rt-private.

    It must NOT overlap 10.20.0.0/16: AWS itself refuses to create the peering
    in that case, it is not a convention of ours.
  EOT
  type        = string
}

variable "common_tags" {
  description = "Standard tags"
  type        = map(string)
}
