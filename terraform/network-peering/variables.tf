# ---------------------------------------------------------------------------
# network-peering/variables.tf
# ---------------------------------------------------------------------------

variable "aws_profile" {
  description = "Perfil do AWS CLI (SSO)"
  type        = string
}

variable "region" {
  description = "Regiao"
  type        = string
  default     = "us-west-2"
}

# --- nosso lado ------------------------------------------------------------

variable "vpc_id" {
  description = "acme-swe-prod-vpc. Construida no console, NAO gerenciada por este codigo."
  type        = string
}

variable "private_route_table_id" {
  description = <<-EOT
    acme-swe-prod-rt-private, onde entra a rota para a producao.

    Esta route table foi criada no console e NAO esta no estado do Terraform.
    O aws_route gerencia UMA rota dentro de uma tabela existente, referenciada
    por ID - nao exige que a tabela esteja sob gestao do Terraform. E por isso
    que a rota pode ir em codigo sem importar a rede e sem gerar drift.
  EOT
  type        = string
}

# --- lado da producao ------------------------------------------------------

variable "production_account_id" {
  description = "Conta AWS de producao, 12 digitos SEM hifens (os hifens sao apresentacao do console)"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.production_account_id))
    error_message = "Precisa ser exatamente 12 digitos, sem hifens."
  }
}

variable "production_vpc_id" {
  description = "VPC de producao que recebe a solicitacao de peering"
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.production_vpc_id))
    error_message = "Formato esperado: vpc-0123456789abcdef0."
  }
}

variable "production_vpc_cidr" {
  description = <<-EOT
    CIDR da VPC de producao. Destino da rota na rt-private.

    NAO pode se sobrepor a 10.20.0.0/16: a propria AWS recusa a criacao do
    peering nesse caso, nao e uma convencao nossa.
  EOT
  type        = string
}

variable "common_tags" {
  description = "Tags da norma"
  type        = map(string)
}
