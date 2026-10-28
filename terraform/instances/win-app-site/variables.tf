variable "aws_configs" {
  type = object({
    region       = string
    default_tags = map(string)
  })
  description = "Configuração do provider: região e tags padrão (mb:*) aplicadas via default_tags."

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_configs.region))
    error_message = "region deve ser uma região AWS válida, ex.: us-west-2."
  }
}

variable "alarms_topic_name" {
  description = "Nome do tópico SNS que recebe os alarmes de status (A28). Resolvido por data source em data.tf. Tópico único da conta, reusado pelo parque."
  type        = string
  default     = "acme-swe-prod-alarms"
}

variable "network" {
  type = object({
    subnet_id          = string
    vpc_id             = optional(string, null)
    private_ip_enabled = optional(bool, false)
  })
  description = "Rede onde as instâncias serão criadas."
}

variable "s3_bucket_name" {
  type        = string
  description = "Nome do bucket S3 (global) usado para software compartilhado (shared/) e backup individual por instância (<hostname>/)."
  default     = "win-app-site"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.s3_bucket_name))
    error_message = "s3_bucket_name deve ser um nome de bucket S3 válido (minúsculas, números, hífen/ponto, 3-63 chars)."
  }
}

# Agrupa os servidores em um mapa de objetos, chaveados por hostname. Cada campo
# tem seu default no próprio schema via optional(), então o resource block pode
# consumir each.value.* diretamente, sem merge com defaults externos. Cada
# servidor pode ter 0, 1 ou N discos de dados (lista de objetos).
variable "servers" {
  type = map(object({
    role             = string
    instance_type    = optional(string, "t3a.micro")
    root_volume_size = optional(number, 60)
    volume_type      = optional(string, "gp3")
    key_name         = optional(string, null)

    # AMI da instancia. null (default) = usa a golden image resolvida no
    # data.tf. Informe para fixar uma AMI especifica nesta maquina - por
    # exemplo a base crua da AWS para um teste, ou uma golden image futura.
    ami_id = optional(string, null)

    data_disks = optional(list(object({
      size        = number
      device_name = string
      volume_type = optional(string, "gp3")
    })), [])

    # Security group da instância. Nome default = hostname; customizável.
    security_group_name = optional(string, null)

    # Regras de entrada. Default [] = nada liberado (acesso via SSM).
    ingress = optional(list(object({
      from_port       = number
      to_port         = number
      protocol        = string
      cidr_blocks     = optional(list(string), null)
      security_groups = optional(list(string), null)
      description     = optional(string, null)
    })), [])

    # Regras de saída. Default = todo o tráfego liberado (necessário p/ SSM).
    egress = optional(list(object({
      from_port        = number
      to_port          = number
      protocol         = string
      cidr_blocks      = optional(list(string), ["0.0.0.0/0"])
      ipv6_cidr_blocks = optional(list(string), null)
      description      = optional(string, null)
    })), [{ from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"], description = "Allow all outbound" }])
  }))
  description = "Servidores a provisionar, chaveados por hostname. instance_type default t3a.micro; data_disks aceita múltiplos discos."

  validation {
    condition     = alltrue([for k, v in var.servers : can(regex("^[A-Z0-9]+$", k))])
    error_message = "O hostname (chave do mapa) deve conter apenas letras maiúsculas e números."
  }

  validation {
    condition = alltrue([
      for v in var.servers : alltrue([for d in v.data_disks : d.size > 0])
    ])
    error_message = "Todo disco de dados deve ter size maior que zero."
  }
}
