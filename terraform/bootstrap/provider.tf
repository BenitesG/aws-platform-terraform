# ---------------------------------------------------------------------------
# bootstrap/provider.tf
#
# Declares the Terraform version and the AWS provider version.
#
# required_version: prevents someone from running with a version that is too
#   old. The >= 1.10 is needed because the S3 backend with use_lockfile (state
#   locking without DynamoDB) only exists from that version onward.
#
# required_providers: Terraform does not talk to AWS on its own. It downloads
#   a "provider", which is the translator between the code and the AWS API.
#   terraform init is the command that performs that download.
#
# ATTENTION: this directory has NO backend block on purpose. It creates the
# bucket that will hold the state, and the state cannot live in a bucket that
# does not exist yet. Run it with local state first; then migrate. See README.
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
  region = "us-west-2"

  # SSO profile configured in ~/.aws/config.
  # PowerUserAccess is enough here: this directory does not create any IAM.
  profile = "acme-swe-prod"
}
