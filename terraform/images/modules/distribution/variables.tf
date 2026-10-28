# ---------------------------------------------------------------------------
# modules/distribution/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Nome da distribution configuration. Por convencao, igual ao da imagem."
  type        = string
}

variable "region" {
  description = "Regiao de destino da AMI"
  type        = string
}

variable "recipe_version" {
  description = "Versao da receita, gravada na tag RecipeVersion da AMI"
  type        = string
}

variable "parent_image" {
  description = <<-EOT
    AMI-pai, gravada na tag ParentImage.

    Na imagem empilhada este valor e a AMI da nossa propria imagem base, o que
    torna a cadeia auditavel: olhando a AMI do host de container, da para
    saber exatamente de qual base ela nasceu.
  EOT
  type        = string
}

variable "common_tags" {
  description = <<-EOT
    Tags da norma, aplicadas a AMI e ao snapshot.

    Precisam ser passadas explicitamente: o default_tags do provider nao
    alcanca nenhum dos dois, porque quem os cria e o Image Builder.
  EOT
  type        = map(string)
  default     = {}
}

variable "extra_ami_tags" {
  description = "Tags adicionais especificas desta imagem (ex.: DockerVersion)"
  type        = map(string)
  default     = {}
}

variable "description" {
  description = "Descricao da distribution configuration"
  type        = string
  default     = null
}

variable "target_account_ids" {
  description = <<-EOT
    Contas com as quais a AMI e compartilhada. Vazio = so esta conta.

    ATENCAO: compartilhar entre contas exige CMK. Snapshot criptografado com a
    chave gerenciada aws/ebs NAO e compartilhavel.
  EOT
  type        = list(string)
  default     = []
}
