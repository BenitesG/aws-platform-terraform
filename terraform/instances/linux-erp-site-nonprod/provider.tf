##################################################################
#_____ TERRAFORM / BACKEND / PROVIDER ___________________________#
##################################################################
# Pasta do site legacy ERP-Linux, ambiente NONPROD. State PROPRIO, separado do prod
# (linux-erp-site-prod) e do instances/ raiz.
#
# POR QUE DOIS STATES (nonprod e prod) em vez de um so: a fronteira de state e
# a fronteira de blast-radius. Com states separados, um apply/destroy errado
# no nonprod NAO alcanca producao - e o nonprod vira o campo onde errar e
# barato. Mesmo raciocinio que clientsg.tf registra sobre nao unificar os SGs
# de prod e nonprod: "com SG unica, alterar a regra para testar em nonprod
# aplicaria em producao no mesmo apply".
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

  # key DIFERENTE de todas as outras configuracoes. State unico por config:
  # se duas usassem a mesma key, a segunda a rodar se acharia dona dos
  # recursos da primeira - e um destroy apagaria coisa de outro projeto.
  backend "s3" {
    bucket       = "acme-swe-prod-tfstate"
    key          = "instances/swe-nonprod/linux-erp-site/terraform.tfstate"
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
