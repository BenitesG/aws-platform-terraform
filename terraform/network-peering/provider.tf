# ---------------------------------------------------------------------------
# network-peering/provider.tf
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

  # PowerUserAccess IS ENOUGH here: nothing in IAM is created in this directory.
  #
  # The peering and the route are EC2 calls (CreateVpcPeeringConnection,
  # CreateRoute, ModifyVpcPeeringConnectionOptions) and PowerUser has them.
  profile = var.aws_profile

  default_tags {
    tags = var.common_tags
  }
}
