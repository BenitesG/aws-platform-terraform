# ---------------------------------------------------------------------------
# modules/infrastructure/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Nome da infrastructure configuration"
  type        = string
}

variable "description" {
  description = <<-EOT
    Descricao da infrastructure configuration.

    Default null de proposito: a configuracao existente foi criada sem
    descricao, e manter null garante diff ZERO na refatoracao.
  EOT
  type        = string
  default     = null
}

# --- IAM -------------------------------------------------------------------

variable "role_name" {
  description = <<-EOT
    Nome do papel da instancia de build.

    PRECISA comecar com "delegated-". A DelegatedAdminBoundary so permite
    criar papel em arn:aws:iam::*:role/delegated-*; fora do prefixo,
    CreateRole e negado.
  EOT
  type        = string

  validation {
    condition     = startswith(var.role_name, "delegated-")
    error_message = "O nome do papel precisa comecar com 'delegated-' por causa da DelegatedAdminBoundary."
  }
}

variable "instance_profile_name" {
  description = <<-EOT
    Nome do instance profile.

    PRECISA comecar com "delegated-", pelo mesmo motivo do papel: a boundary
    restringe a arn:aws:iam::*:instance-profile/delegated-*.
  EOT
  type        = string

  validation {
    condition     = startswith(var.instance_profile_name, "delegated-")
    error_message = "O nome do instance profile precisa comecar com 'delegated-'."
  }
}

variable "permissions_boundary_arn" {
  description = <<-EOT
    ARN da permissions boundary obrigatoria para papeis criados por delegacao.

    Sem isto o CreateRole e NEGADO, e o erro nao menciona a boundary.
  EOT
  type        = string
}

# --- Rede ------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC onde o security group da build e criado"
  type        = string
}

variable "subnet_id" {
  description = <<-EOT
    Subnet da instancia temporaria de build. Precisa de SAIDA para a internet
    (pelo NAT) para o SSM e para baixar pacotes.

    Obrigatorio nesta conta: NAO existe VPC default em nenhuma regiao, entao
    omitir nao cai em lugar nenhum - a build falha por ausencia de rede.
  EOT
  type        = string
}

variable "security_group_name" {
  description = "Nome do security group da build, no padrao mb-{escopo}-{ambiente}-{finalidade}"
  type        = string
}

# --- Instancia de build ----------------------------------------------------

variable "instance_types" {
  description = "Tipos aceitos para a instancia de build. Precisam casar com a arquitetura da imagem."
  type        = list(string)
}

variable "terminate_instance_on_failure" {
  description = <<-EOT
    Derrubar a instancia quando a build falha.

    Mantenha true. false deixa EC2 ligada indefinidamente, com instance
    profile anexado, se a build falhar fora do horario. Troque para false
    TEMPORARIAMENTE para investigar uma falha por dentro.
  EOT
  type        = bool
  default     = true
}

variable "resource_tags" {
  description = <<-EOT
    Tags da INSTANCIA de build e do volume dela.

    Diferente de tags: o default_tags do provider nao alcanca esses recursos,
    porque quem os cria e o servico, nao o Terraform.
  EOT
  type        = map(string)
  default     = {}
}

# --- Opcionais -------------------------------------------------------------

variable "sns_topic_arn" {
  description = "Topico SNS para notificacao de build. null desliga."
  type        = string
  default     = null
}

variable "s3_logs_bucket" {
  description = <<-EOT
    Bucket para log da build. null desliga, que e o padrao.

    O log dos componentes ja vai para o CloudWatch Logs em
    /aws/imagebuilder/<nome-da-imagem> sem configuracao nenhuma.
  EOT
  type        = string
  default     = null
}

variable "s3_logs_prefix" {
  description = "Prefixo das chaves do log em S3. So usado se s3_logs_bucket for definido."
  type        = string
  default     = "imagebuilder"
}
