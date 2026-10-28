# ---------------------------------------------------------------------------
# modules/recipe/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Nome da receita. Por convencao, igual ao da imagem."
  type        = string
}

variable "recipe_version" {
  description = <<-EOT
    Versao semantica da receita (ex.: "1.0.2").

    Chama-se recipe_version e nao "version" porque "version" e argumento
    RESERVADO em bloco module.

    SOBE A MAO, e junto com a do componente: o ARN do componente inclui a
    versao dele, entao mudar um componente muda a receita - e receita e
    imovel. Esquecer faz o apply nao mudar nada e parecer que atualizou.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.recipe_version))
    error_message = "Use versao semantica com tres numeros, por exemplo 1.0.0."
  }
}

variable "parent_image" {
  description = <<-EOT
    AMI de origem.

    A ARQUITETURA E ASSADA AQUI: imagem x86_64 nao roda em instancia ARM e
    vice-versa.

    Pode ser uma AMI publica (Canonical) ou uma golden image nossa - e assim
    que se EMPILHA imagem, que e o padrao decidido no A42: o host de container
    e garantidamente a imagem base mais Docker.
  EOT
  type        = string
}

variable "component_arns" {
  description = <<-EOT
    ARNs dos componentes, NA ORDEM DE EXECUCAO.

    O componente de limpeza deve ser o ULTIMO.

    Em ARN de componente GERENCIADO, o "x.x.x" nao e placeholder: e a sintaxe
    do Image Builder para "a versao mais recente".
  EOT
  type        = list(string)
}

variable "description" {
  description = "O que a imagem contem"
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Tamanho do disco raiz da imagem, em GB"
  type        = number
  default     = 20
}

variable "root_device_name" {
  description = "Nome do dispositivo raiz. /dev/sda1 nas AMIs do Ubuntu; /dev/xvda em Amazon Linux."
  type        = string
  default     = "/dev/sda1"
}
