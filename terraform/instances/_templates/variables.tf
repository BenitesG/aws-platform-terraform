##################################################################
#_____ VARIAVEIS DE INFRA (TEMPLATE) ____________________________#
##################################################################
# Esqueleto comum a qualquer stack de instancias. Acrescente/remova conforme o
# que o seu stack precisa (ex.: erp_host_cidr so faz sentido num site que fala
# com o legacy ERP).

variable "aws_profile" {
  description = "Perfil do AWS CLI para o PROVIDER. DelegatedAdministrator se o stack anexa instance profile (iam:PassRole)."
  type        = string
}

variable "region" {
  description = "Regiao AWS."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "region deve ser uma regiao AWS valida, ex.: us-west-2."
  }
}

variable "vpc_id" {
  description = "VPC onde os security groups sao criados."
  type        = string
}

variable "private_subnet_id" {
  description = "Subnet privada-d. As publicas NAO tem rota para fora (o SSM nao registra)."
  type        = string
}

variable "instance_profile" {
  description = "Instance profile do papel de baseline (SSM + CloudWatch)."
  type        = string
}

variable "alarms_topic_name" {
  description = "Nome do topico SNS dos alarmes (A28). Resolvido por data source. Topico unico da conta."
  type        = string
  default     = "acme-swe-prod-alarms"
}

variable "common_tags" {
  description = "Tags comuns (viram default_tags). So o que NAO varia por maquina. Project/Application/Environment vao no schema servers."
  type        = map(string)
}

# --- Especificas do site legacy ERP. Remova se o seu stack nao fala com o legacy ERP nem
# tem protocolo industrial. ---

variable "erp_host_cidr" {
  description = "Host do legacy ERP em /32 (infra de terceiro, via peering). Usado no client SG (clientsg.tf)."
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.erp_host_cidr))
    error_message = "Precisa ser um host unico em /32, nao uma faixa."
  }
}

variable "plc_host_cidr" {
  description = "Host do Studio 5000 em /32 (infra de terceiro). Origem/destino das regras de protocolo. Vazio = sem protocolo industrial."
  type        = string
  default     = ""

  validation {
    condition     = var.plc_host_cidr == "" || can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.plc_host_cidr))
    error_message = "Precisa ser um host unico em /32, nao uma faixa."
  }
}

##################################################################
#_____ SERVERS (schema de exemplo) ______________________________#
##################################################################
# Mapa chaveado por HOSTNAME (chave de negocio estavel - entra no endereco do
# state, NAO renomear depois de aplicada). Campos com optional() tem default no
# schema, entao o recurso consome each.value.* direto.
#
# Adapte os campos ao seu stack. Este exemplo cobre o caso Linux do legacy ERP
# (egress fixo 443/80 no main.tf, regras de integracao opcionais, tags que
# variam por maquina). Um stack mais simples pode ter menos campos.

variable "servers" {
  type = map(object({
    name     = string # acme-swe-{ambiente}-{finalidade}
    ami_id   = string # FIXO - "latest" via data source recriaria a maquina
    key_name = string # IMUTAVEL depois do lancamento (ForceNew)

    instance_type    = optional(string, "t4g.small")
    root_volume_size = optional(number, 30)

    enable_termination_protection = optional(bool, true)

    # Anexa o client SG do legacy ERP (clientsg.tf). true = fala com o legacy ERP.
    attach_client_sg = optional(bool, true)

    integration_ingress_rules = optional(map(object({
      description = string
      ip_protocol = string
      from_port   = number
      to_port     = number
      cidr_ipv4   = string
    })), {})

    integration_egress_rules = optional(map(object({
      description = string
      ip_protocol = string
      from_port   = number
      to_port     = number
      cidr_ipv4   = string
    })), {})

    project     = string
    application = string
    environment = string
    request_id  = optional(string, null)
    auto_wake   = optional(bool, true)
  }))

  description = "Servidores do stack, chaveados por hostname."

  validation {
    condition     = alltrue([for k, v in var.servers : can(regex("^[A-Z0-9-]+$", k))])
    error_message = "O hostname (chave do mapa) deve ter so maiusculas, numeros e hifen."
  }
}
