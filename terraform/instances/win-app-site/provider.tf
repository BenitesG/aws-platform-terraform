terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Ajuste bucket/key/region conforme o padrão de backends da sua conta.
  # Lock de state nativo do S3 (use_lockfile), sem necessidade de DynamoDB.
  backend "s3" {
    bucket       = "acme-swe-prod-tfstate"
    key          = "instances/swe-nonprod/win-app-site/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_configs.region

  default_tags {
    tags = var.aws_configs.default_tags
  }
}
