##################################################################
#_____ TERRAFORM / BACKEND / PROVIDER ___________________________#
##################################################################
# Pasta do site legacy ERP-Linux, ambiente PROD. State PROPRIO, separado do nonprod
# (linux-erp-site-nonprod) e do instances/ raiz.
#
# POR QUE DOIS STATES (nonprod e prod) em vez de um so: a fronteira de state e
# a fronteira de blast-radius. Com states separados, um apply/destroy errado
# no nonprod NAO alcanca producao - e o nonprod vira o campo onde errar e
# barato.
#
# O BACKEND NAO HERDA O PROFILE do provider e nao aceita variavel. Antes do
# init:  $env:AWS_PROFILE = "acme-swe-prod"
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "acme-swe-prod-tfstate"
    key          = "instances/swe-prod/linux-erp-site/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = var.common_tags
  }
}
