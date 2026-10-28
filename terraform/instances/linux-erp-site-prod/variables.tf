##################################################################
#_____ VARIAVEIS DE INFRA / PROVIDER ____________________________#
##################################################################

variable "aws_profile" {
  description = <<-EOT
    Perfil do AWS CLI para o PROVIDER (operacoes de recurso).

    DelegatedAdministrator, nao PowerUserAccess: anexar instance profile a
    instancia exige iam:PassRole, que o PowerUser NAO tem. O backend (so S3)
    continua no PowerUser pela variavel de ambiente AWS_PROFILE - config
    explicita no provider vence a variavel de ambiente, entao as duas metades
    convivem.
  EOT
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
  description = "VPC onde os security groups das instancias e o client SG sao criados."
  type        = string
}

variable "private_subnet_id" {
  description = "Subnet privada-d. As publicas NAO tem rota para fora (o SSM nao registra)."
  type        = string
}

variable "instance_profile" {
  description = "Instance profile do papel de baseline (SSM + CloudWatch). Compartilhado pelas maquinas - a Linux nao tem bucket por maquina, entao nao precisa de role por instancia como o win-app-site."
  type        = string
}

variable "erp_host_cidr" {
  description = <<-EOT
    Host do legacy ERP na conta de PRODUCAO (444455556666), em /32. Destino e origem
    das regras da integracao, no client SG (clientsg.tf).

    INFRA DE TERCEIRO: este endereco pertence a outra conta/equipe, alcancado
    pelo peering. /32 OBRIGATORIO - faixa mais larga daria a toda a VPC de
    producao as portas da integracao, inclusive a 65022 de entrada.
  EOT
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.erp_host_cidr))
    error_message = "Precisa ser um host unico em /32, nao uma faixa."
  }
}

# tflint-ignore: terraform_unused_declarations
variable "plc_host_cidr" {
  description = <<-EOT
    Host do Studio 5000 em /32, origem e destino das regras de protocolo do ATB.

    INFRA DE TERCEIRO: esta na conta de PRODUCAO (172.31.0.0/16), alcancada
    pelo peering - apesar do nome "acme-swe-nonprod-plc". /32 obrigatorio.
    Vazio = maquina sem regras de protocolo industrial.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.plc_host_cidr == "" || can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.plc_host_cidr))
    error_message = "Precisa ser um host unico em /32, nao uma faixa."
  }
}

variable "alarms_topic_name" {
  description = <<-EOT
    Nome do topico SNS que recebe os alarmes de status (A28). Resolvido por
    data source em data.tf.

    Um unico topico na conta (acme-swe-prod-alarms), reusado por prod e nonprod.
    Topico por grupo de trabalho fica para o futuro.
  EOT
  type        = string
  default     = "acme-swe-prod-alarms"
}

variable "common_tags" {
  description = <<-EOT
    Tags comuns, viram default_tags do provider e colam em TODO recurso da
    pasta. So o que e genuinamente comum: departamento, centro de custo,
    classificacao, dono, tipo de cobranca.

    NAO inclui Project/Application/Environment - essas VARIAM por maquina e
    sao declaradas no schema servers, sobrescrevendo o default.
  EOT
  type        = map(string)
}

##################################################################
#_____ SERVERS (schema rico da Linux legacy ERP) _______________________#
##################################################################
# Mapa chaveado por HOSTNAME (chave de negocio estavel - entra no endereco do
# state). Mais rico que o schema do win-app-site: carrega as regras de
# integracao por maquina, a client SG por ambiente e as tags que variam.
#
# Cada campo tem default no proprio schema via optional(), entao os recursos
# consomem each.value.* direto. Maquina simples (cagworkbench) vira ~8 linhas;
# complexa (atb, com protocolo industrial) usa os mapas de integracao.
#
# NAO RENOMEAR A CHAVE depois de aplicada: ela e o endereco no state, e
# renomear DESTROI e recria a instancia e tudo pendurado nela.

variable "servers" {
  type = map(object({
    # --- Identidade / arquitetura (sem default: decisao por maquina) ---
    name     = string # acme-swe-{ambiente}-{finalidade}
    ami_id   = string # FIXO - "latest" via data source recriaria a maquina
    key_name = string # IMUTAVEL depois do lancamento (ForceNew)

    instance_type    = optional(string, "t4g.small")
    root_volume_size = optional(number, 30) # piso arm64; x86 usa 20

    enable_termination_protection = optional(bool, true)

    # --- Client SG do legacy ERP (compartilhada no ambiente), anexada via
    # extra_security_group_ids. O valor e sempre o mesmo SG do ambiente desta
    # pasta; o flag liga/desliga o anexo. Toda maquina do parque fala com o
    # legacy ERP, entao o default e true. ---
    attach_client_sg = optional(bool, true)

    # --- Regras de integracao ESPECIFICAS da maquina (ex.: protocolo
    # industrial do ATB, apontando para o Studio 5000). Vazio por padrao: o
    # padrao A18 e entrada vazia, acesso so por SSM. ---
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

    # --- Tags que VARIAM por maquina (sobrescrevem default_tags). Sem default
    # honesto possivel: cada maquina e uma Application diferente. ---
    project     = string
    application = string
    environment = string                 # "prod" nesta pasta
    request_id  = optional(string, null) # ticketing-system-xxxx; nem toda maquina tem
    auto_wake   = optional(bool, true)
  }))

  description = "Servidores Linux do site legacy ERP, chaveados por hostname. Egress fixo 443/80 (R07) nao e campo: e inviolavel por construcao no main.tf."

  # Hostname (chave) no padrao SWE-{N|P}-...
  validation {
    condition     = alltrue([for k, v in var.servers : can(regex("^SWE-[NP]-[A-Z0-9]+$", k))])
    error_message = "O hostname (chave do mapa) deve seguir SWE-{N|P}-NOME, so maiusculas e numeros."
  }

  # Protege contra renomear a chave de regra de integracao (quebraria o state).
  validation {
    condition = alltrue([
      for v in var.servers : alltrue([
        for rk, rv in merge(v.integration_ingress_rules, v.integration_egress_rules) :
        rv.from_port <= rv.to_port
      ])
    ])
    error_message = "Em toda regra de integracao, from_port deve ser <= to_port."
  }
}
