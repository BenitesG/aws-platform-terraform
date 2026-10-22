# ---------------------------------------------------------------------------
# instances/provider.tf
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

  # Here PowerUserAccess is ENOUGH: this directory creates nothing IAM-related,
  # it only references an existing instance profile by name.
  #
  # But watch out: attaching an instance profile to an instance requires
  # iam:PassRole. The DelegatedAdminBoundary allows it for role/delegated-*
  # passed to EC2, and that is exactly why the role is called delegated-ec2-ssm.
  # If PowerUserAccess does not have PassRole, switch to the acme-swe-prod-admin
  # profile.
  profile = var.aws_profile

  default_tags {
    tags = var.common_tags
  }
}
