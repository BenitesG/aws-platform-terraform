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

  # PowerUserAccess BASTA aqui: nao se cria nada de IAM neste diretorio.
  #
  # O peering e a rota sao chamadas de EC2 (CreateVpcPeeringConnection,
  # CreateRoute, ModifyVpcPeeringConnectionOptions) e o PowerUser as tem.
  profile = var.aws_profile

  default_tags {
    tags = var.common_tags
  }
}
