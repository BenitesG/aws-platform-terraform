# ---------------------------------------------------------------------------
# bootstrap/provider.tf
#
# Declara a versao do Terraform e do provider da AWS.
#
# required_version: evita que alguem rode com uma versao antiga demais.
#   O >= 1.10 e necessario porque o backend S3 com use_lockfile (trava de
#   estado sem DynamoDB) so existe a partir dessa versao.
#
# required_providers: o Terraform nao fala com a AWS por conta propria. Ele
#   baixa um "provider", que e o tradutor entre o codigo e a API da AWS.
#   O terraform init e o comando que faz esse download.
#
# ATENCAO: este diretorio NAO tem bloco backend de proposito. Ele cria o
# bucket que vai guardar o estado, e o estado nao pode morar num bucket que
# ainda nao existe. Roda com estado local primeiro; depois migra. Ver README.
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

  # Perfil do SSO configurado em ~/.aws/config.
  # Aqui serve o PowerUserAccess: este diretorio nao cria nada de IAM.
  profile = "acme-swe-prod"
}
