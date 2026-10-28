# ---------------------------------------------------------------------------
# modules/pipeline/main.tf
#
# O pipeline amarra receita + infraestrutura + distribuicao.
#
# NAO EXISTE recurso aqui para "executar a build". Build e ACAO, nao estado:
#
#   aws imagebuilder start-image-pipeline-execution --image-pipeline-arn <arn>
#
# Existe um recurso aws_imagebuilder_image que dispara uma build, mas nao use:
# cada versao nova faria o Terraform querer substituir o recurso, misturando
# "definir o pipeline" com "executar o pipeline". A execucao fica na esteira.
# ---------------------------------------------------------------------------

resource "aws_imagebuilder_image_pipeline" "this" {
  name        = var.name
  description = var.description
  status      = var.status

  image_recipe_arn                 = var.recipe_arn
  infrastructure_configuration_arn = var.infrastructure_arn

  # OBRIGATORIO passar, ao contrario do exemplo de referencia da equipe, que o
  # omite. Sem distribution configuration a AMI e o snapshot nascem SEM as
  # tags da norma, e a politica de retencao do A41 - que seleciona por tag -
  # deixa de encontrar as imagens.
  distribution_configuration_arn = var.distribution_arn

  # A fase de teste roda numa instancia lancada a partir da AMI JA PRONTA.
  # E o que diferencia "imagem criada" de "imagem que comprovadamente
  # inicializa" - o simple-boot-test-linux da base passou em 14/10.
  image_tests_configuration {
    image_tests_enabled = var.image_tests_enabled
    timeout_minutes     = var.image_tests_timeout
  }

  # Tags da linhagem, mescladas por cima do default_tags do provider.
  #
  # Tag declarada no recurso VENCE default_tags, entao basta declarar o que
  # diverge - nao e preciso repetir as nove.
  #
  # ATENCAO: isto NAO alimenta a politica de retencao. A selecao da politica
  # avalia tags no RECURSO IMAGE do Image Builder, e tag de pipeline nao
  # propaga para ele (verificado em 15 e 16/10). Aqui a tag serve para
  # inventario. Ver a nota ao fim de lifecycle.tf.
  tags = var.extra_tags

  # Sem "schedule": disparo manual. O agendamento mensal de repique de patch
  # entra quando a cadencia for decidida (A42).
  #
  # ORDEM IMPORTA: nao ligue o agendamento antes de a politica de retencao
  # estar funcionando, senao cada build mensal deixa um snapshot de 20 GB que
  # ninguem apaga.
  #
  # ESTADO EM 16/10: a retencao ESTA funcionando. A boundary foi liberada em
  # 15/10 (v2, com "image*" na condicao iam:PassedToService), as tres
  # politicas por linhagem estao ENABLED, e os tres recursos image foram
  # tagueados. O que FALTA e automatizar: o recurso image nasce sem tags, e
  # hoje o tag-resource e manual depois de cada build. Enquanto for manual, o
  # agendamento nao deve ser ligado - build agendada ninguem acompanha, e
  # imagem sem tag fica fora da politica em silencio. E o que a Lambda do A44
  # resolve.
  dynamic "schedule" {
    for_each = var.schedule != null ? [var.schedule] : []

    content {
      schedule_expression                = schedule.value.expression
      pipeline_execution_start_condition = schedule.value.start_condition
    }
  }
}
