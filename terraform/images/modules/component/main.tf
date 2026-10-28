# ---------------------------------------------------------------------------
# modules/component/main.tf
#
# UM componente AWSTOE a partir de um documento YAML.
#
# Componente e IMUTAVEL: o ARN inclui a versao. Mudar o YAML nao cria versao
# nova sozinho - e preciso subir o component_version a mao. Esquecer faz o
# apply nao mudar nada e parecer que atualizou.
#
# VALIDE O YAML LOCALMENTE ANTES DO APPLY. Uma build custa 15 a 25 minutos
# para descobrir erro de sintaxe:
#
#   curl -O https://awstoe-us-west-2.s3.us-west-2.amazonaws.com/latest/linux/amd64/awstoe
#   chmod +x awstoe
#   ./awstoe validate --documents components/docker.yml
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_imagebuilder_component" "this" {
  name        = var.name
  platform    = var.platform
  version     = var.component_version
  description = var.description

  data = var.data

  # Versoes suportadas do SO. Vazio = todas.
  #
  # Nao restringimos por padrao: o componente proprio e escrito para o padrao
  # da empresa, e uma lista aqui viraria mais um lugar para esquecer de
  # atualizar quando a versao do Ubuntu mudar.
  supported_os_versions = length(var.supported_os_versions) > 0 ? var.supported_os_versions : null

  # OBRIGATORIO, nao e refinamento.
  #
  # A versao antiga do componente nao pode ser apagada enquanto uma RECEITA
  # ainda apontar para ela - nem enquanto existir versao de imagem que a
  # referencie, INCLUSIVE uma build que falhou. Por padrao o Terraform destroi
  # antes de criar, e a remocao falha com ResourceDependencyException.
  #
  # Com create_before_destroy a ordem inverte: cria a versao nova, as receitas
  # passam a apontar nela, e so entao a antiga sai.
  lifecycle {
    create_before_destroy = true
  }
}
