##################################################################
#_____ BACKEND (TEMPLATE) _______________________________________#
##################################################################
# MOLDE - copie a pasta _templates/ inteira para uma pasta nova e ajuste.
#
# TROQUE A KEY. Ela DEVE ser unica por stack - duas configuracoes com a mesma
# key fazem a segunda a rodar se achar dona dos recursos da primeira, e um
# destroy apagaria coisa de outro projeto. O Terraform NAO valida isso.
#
# Padrao da key:  instances/<conta-env>/<stack>/terraform.tfstate
#   ex.: instances/swe-prod/meu-site/terraform.tfstate
#
# O backend NAO herda o profile do provider e nao aceita variavel. Antes do
# init:  $env:AWS_PROFILE = "acme-swe-prod"
terraform {
  backend "s3" {
    bucket       = "acme-swe-prod-tfstate"
    key          = "instances/<CONTA-ENV>/<STACK>/terraform.tfstate" # TODO: trocar
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
