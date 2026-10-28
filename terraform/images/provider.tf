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

  # ATENCAO: aqui o perfil precisa ser o DelegatedAdministrator
  # (acme-swe-prod-admin), porque esta configuracao cria papel e instance
  # profile. O PowerUserAccess nao tem iam:GetRole nem iam:GetInstanceProfile,
  # e sem essas LEITURAS o apply falha DEPOIS de criar o recurso - deixando
  # objeto orfao, criado na AWS mas ausente do estado.
  #
  # O BACKEND, por outro lado, usa a variavel de ambiente AWS_PROFILE: ele so
  # precisa de S3, que o PowerUserAccess tem. Configuracao explicita (aqui)
  # vence variavel de ambiente, entao as duas metades convivem.
  profile = var.aws_profile

  # default_tags aplica estas tags em tudo que o provider criar, sem precisar
  # repetir em cada recurso. E onde a norma de tagueamento sobrevive.
  default_tags {
    tags = var.common_tags
  }
}
