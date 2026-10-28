# ---------------------------------------------------------------------------
# network-peering/terraform.tfvars
#
# RECONSTRUIDO EM 22/10/2026. O arquivo original foi apagado junto com o
# diretorio inteiro, por acidente, ao limpar .tfplan. Os sete arquivos de
# codigo voltaram pelo git; este NAO estava versionado e teve de ser refeito.
#
# TODOS OS VALORES FORAM LIDOS DA AWS, nao de documento:
#   aws ec2 describe-vpc-peering-connections
#   aws ec2 describe-route-tables --filters Name=vpc-id,Values=vpc-0a1b2c3d4e5f60001
#
# Isso e mais confiavel que o documento: afirmacao de estado no .md e
# hipotese, e tres delas nao sobreviveram a leitura pela CLI em 20/10.
# ---------------------------------------------------------------------------

aws_profile = "acme-swe-prod"
region      = "us-west-2"

# --- nosso lado ---
# acme-swe-prod-vpc
vpc_id = "vpc-0a1b2c3d4e5f60001"

# acme-swe-prod-rt-private: a tabela associada as subnets privadas.
# NAO usar a rt-main, que fica so com "local" de proposito (decisao do A15) -
# conferido em 22/10: a rt-main tem exatamente uma rota, 10.20.0.0/16.
#
# As tres tabelas da VPC, para nao confundir na proxima vez:
#   rtb-0a1b2c3d4e5f80002  acme-swe-prod-rt-main     so local
#   rtb-0a1b2c3d4e5f80003  acme-swe-prod-rt-nat      local + 0.0.0.0/0
#   rtb-0a1b2c3d4e5f80001  acme-swe-prod-rt-private  local + 0.0.0.0/0 + 172.31.0.0/16
private_route_table_id = "rtb-0a1b2c3d4e5f80001"

# --- lado da producao ---
# 12 digitos, SEM hifens. O console mostra com hifens; a API nao os aceita.
production_account_id = "444455556666"
production_vpc_id     = "vpc-0a1b2c3d4e5f60002"

# NAO pode se sobrepor a 10.20.0.0/16 - a AWS recusa o peering.
production_vpc_cidr = "172.31.0.0/16"

common_tags = {
  ManagedBy = "terraform"

  # Project/Application proprios DESTE diretorio, diferentes dos demais.
  # A tag Application descreve O QUE o recurso e, nao o projeto: em images/ e
  # golden-image, em bootstrap/ e terraform-state, aqui e network-traffic.
  "acme:cost-allocation:Project"     = "infrastructure"
  "acme:cost-allocation:Application" = "network-traffic"
  "acme:cost-allocation:Department"  = "swe"
  "acme:cost-allocation:CostCenter"  = "h370infra"
  "mb:automation:Environment"        = "prod"
  "mb:data:DataClassification"       = "interno"

  Owner      = "platform-team@acme.example"
  ChargeType = "dedicated"
}
