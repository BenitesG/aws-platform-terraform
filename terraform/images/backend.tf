# ---------------------------------------------------------------------------
# imagens/backend.tf
#
# Onde o estado desta configuracao e guardado.
#
# IMPORTANTE: o bloco backend NAO aceita variavel. Nada de var.* aqui - tem
# que ser literal. E limitacao do Terraform, nao erro de escrita.
#
# O bucket precisa existir antes do primeiro "terraform init". Rode o
# diretorio bootstrap/ primeiro.
#
# key: o caminho do arquivo dentro do bucket. O prefixo permite que o mesmo
#   bucket guarde o estado de varios projetos, cada um no seu caminho.
#
# use_lockfile: trava o estado usando o proprio S3, dispensando DynamoDB.
#   Sem trava, dois apply simultaneos (voce e a esteira, por exemplo) leem o
#   mesmo estado, os dois decidem criar, e o estado fica inconsistente.
#   Requer Terraform >= 1.10.
# ---------------------------------------------------------------------------

terraform {
  backend "s3" {
    bucket       = "acme-swe-prod-tfstate"
    key          = "images/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
