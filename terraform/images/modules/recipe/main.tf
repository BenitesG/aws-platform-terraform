# ---------------------------------------------------------------------------
# modules/recipe/main.tf
#
# A receita de UMA imagem: imagem-pai + lista ordenada de componentes + disco.
#
# Se voce pensa em Docker, a imagem-pai e o FROM e os componentes sao os RUN.
# ---------------------------------------------------------------------------

resource "aws_imagebuilder_image_recipe" "this" {
  name         = var.name
  version      = var.recipe_version
  parent_image = var.parent_image
  description  = var.description

  block_device_mapping {
    device_name = var.root_device_name

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # A ORDEM DA LISTA E A ORDEM DE EXECUCAO.
  #
  # O componente de limpeza tem de ser o ULTIMO: ele apaga a identidade da
  # maquina de build (chaves de host SSH, machine-id, estado do cloud-init) e
  # qualquer componente depois dele reintroduziria residuo no snapshot.
  dynamic "component" {
    for_each = var.component_arns

    content {
      component_arn = component.value
    }
  }

  # OBRIGATORIO aqui, nao e refinamento.
  #
  # Receita e IMUTAVEL: mudar o conteudo gera versao nova, e a antiga precisa
  # ser removida. Por padrao o Terraform DESTROI antes de CRIAR - e a receita
  # antiga nao pode ser apagada enquanto o pipeline ainda aponta para ela,
  # resultando em ResourceDependencyException.
  #
  # Com create_before_destroy a ordem inverte: cria a versao nova, atualiza o
  # pipeline para apontar nela, e so entao remove a antiga. Funciona porque as
  # duas versoes coexistem - o ARN inclui a versao.
  #
  # Se o erro aparecer MESMO ASSIM, quem segura a dependencia e uma IMAGEM, e
  # nao a receita - inclusive uma build que falhou:
  #   aws imagebuilder delete-image --image-build-version-arn <arn>
  # A ordem de remocao e de dentro para fora: imagem, receita, componente.
  lifecycle {
    create_before_destroy = true
  }
}
