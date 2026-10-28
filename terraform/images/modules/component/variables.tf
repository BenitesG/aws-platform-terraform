# ---------------------------------------------------------------------------
# modules/component/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Nome do componente, no padrao mb-{funcao} (ex.: mb-timezone)"
  type        = string
}

variable "component_version" {
  description = <<-EOT
    Versao semantica do componente (ex.: "1.0.2").

    Chama-se component_version e nao "version" porque "version" e argumento
    RESERVADO em bloco module - o Terraform o usa para versao de modulo do
    registry e recusaria o nome.

    MUDAR O YAML NAO SOBE ESTA VERSAO SOZINHO. E manual, e sao DOIS lugares:
    aqui e o recipe_version da receita que consome o componente, porque o ARN
    do componente inclui a versao, logo mudar o componente muda a receita - e
    receita e imovel.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.component_version))
    error_message = "Use versao semantica com tres numeros, por exemplo 1.0.0."
  }
}

variable "platform" {
  description = "Plataforma do componente: Linux ou Windows"
  type        = string
  default     = "Linux"

  validation {
    condition     = contains(["Linux", "Windows"], var.platform)
    error_message = "platform deve ser Linux ou Windows."
  }
}

variable "description" {
  description = "O que o componente faz. Aparece no console e no log da build."
  type        = string
  default     = null
}

variable "data" {
  description = "Conteudo do documento AWSTOE em YAML. Use file() na chamada."
  type        = string
}

variable "supported_os_versions" {
  description = "Versoes de SO suportadas. Lista vazia = sem restricao."
  type        = list(string)
  default     = []
}
