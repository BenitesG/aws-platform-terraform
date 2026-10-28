# ---------------------------------------------------------------------------
# network-peering/backend.tf
#
# key DIFERENTE de bootstrap/, images/ e instances/. Estado proprio, isolado.
#
# Se duas configuracoes usassem o mesmo key, a segunda a rodar acharia que e
# dona dos recursos da primeira - e um destroy apagaria coisa de outro
# projeto. O Terraform nao valida isso: key unico por configuracao e regra
# manual do repositorio.
#
# Lembrete: o bloco backend NAO aceita variavel, e ele nao herda o profile do
# provider. Antes do init:  $env:AWS_PROFILE = "acme-swe-prod"
# ---------------------------------------------------------------------------

terraform {
  backend "s3" {
    bucket       = "acme-swe-prod-tfstate"
    key          = "network-peering/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
