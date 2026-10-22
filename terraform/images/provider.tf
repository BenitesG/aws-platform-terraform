# ---------------------------------------------------------------------------
# images/provider.tf
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  # ATTENTION: here the profile must be the DelegatedAdministrator
  # (acme-swe-prod-admin), because this configuration creates a role and an
  # instance profile. PowerUserAccess has neither iam:GetRole nor
  # iam:GetInstanceProfile, and without those READS the apply fails AFTER
  # creating the resource - leaving an orphan object, created in AWS but
  # absent from the state.
  #
  # The BACKEND, on the other hand, uses the AWS_PROFILE environment variable:
  # it only needs S3, which PowerUserAccess has. Explicit configuration (here)
  # beats the environment variable, so the two halves coexist.
  profile = var.aws_profile

  # default_tags applies these tags to everything the provider creates, with
  # no need to repeat them on each resource. It is where the tagging standard
  # survives.
  default_tags {
    tags = var.common_tags
  }
}
