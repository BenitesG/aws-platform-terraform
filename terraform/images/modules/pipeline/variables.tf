# ---------------------------------------------------------------------------
# modules/pipeline/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Nome do pipeline. Por convencao, igual ao da imagem."
  type        = string
}

variable "recipe_arn" {
  description = "ARN da receita"
  type        = string
}

variable "infrastructure_arn" {
  description = "ARN da infrastructure configuration compartilhada"
  type        = string
}

variable "distribution_arn" {
  description = <<-EOT
    ARN da distribution configuration.

    OBRIGATORIO. Sem ela a AMI e o snapshot nascem sem as tags da norma e a
    politica de retencao do A41, que seleciona por tag, nao os encontra.
  EOT
  type        = string
}

variable "description" {
  description = "Descricao do pipeline"
  type        = string
  default     = null
}

variable "status" {
  description = "ENABLED ou DISABLED"
  type        = string
  default     = "ENABLED"

  validation {
    condition     = contains(["ENABLED", "DISABLED"], var.status)
    error_message = "status deve ser ENABLED ou DISABLED."
  }
}

variable "image_tests_enabled" {
  description = "Rodar a fase de teste numa instancia lancada da AMI pronta"
  type        = bool
  default     = true
}

variable "image_tests_timeout" {
  description = "Tempo maximo da fase de teste, em minutos"
  type        = number
  default     = 60
}

variable "extra_tags" {
  description = <<-EOT
    Tags especificas desta linhagem, mescladas por cima do default_tags do
    provider. Tag declarada no recurso vence default_tags.

    POR QUE EXISTE: sem ela as nove tags do pipeline vinham todas do
    default_tags, entao os tres pipelines ficavam com
    Application = golden-image e eram indistinguiveis por tag. A AMI, o
    snapshot e a politica de retencao ja usam o valor da linhagem desde
    16/10 - o pipeline era a unica camada ainda generica.

    NAO CONFUNDA COM RETENCAO: tag de pipeline NAO propaga para o recurso
    image do Image Builder, que e o que a politica de retencao avalia.
    Verificado em 15 e 16/10. Aqui a tag serve para INVENTARIO - pipeline e
    definicao, nao recurso cobrado, entao nao aparece na fatura.
  EOT
  type        = map(string)
  default     = {}
}

variable "schedule" {
  description = <<-EOT
    Agendamento da build. null = disparo manual, que e o padrao hoje.

    NAO ligue antes de a politica de retencao funcionar: cada build mensal
    deixa um snapshot de 20 GB que ninguem apaga.

    Exemplo:
      schedule = {
        expression      = "cron(0 3 1 * ? *)"
        start_condition = "EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE"
      }
  EOT
  type = object({
    expression      = string
    start_condition = string
  })
  default = null
}
