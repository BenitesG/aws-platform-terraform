##################################################################
#_____ TERRAFORM / PROVIDER (TEMPLATE) __________________________#
##################################################################
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  # Tags comuns ao stack (o que NAO varia por maquina). O que varia
  # (Project/Application/Environment) vai no schema servers.
  default_tags {
    tags = var.common_tags
  }
}
