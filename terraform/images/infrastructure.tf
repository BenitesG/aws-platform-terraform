# ---------------------------------------------------------------------------
# images/infrastructure.tf
#
# ONDE as builds rodam. Compartilhado por todas as imagens: papel, instance
# profile, security group e a infrastructure configuration.
#
# Uma configuracao so para as duas linhagens de proposito. Se cada imagem
# tivesse a sua, haveria dois papeis e dois security groups fazendo o mesmo -
# e dois lugares para esquecer de atualizar.
# ---------------------------------------------------------------------------

module "build_infrastructure" {
  source = "./modules/infrastructure"

  name = "acme-swe-prod-images-build"

  # Nomes com o prefixo "delegated-" porque a DelegatedAdminBoundary so
  # permite criar IAM dentro dele. O modulo valida isso e falha no plan, nao
  # no apply - erro de nome nao chega a virar AccessDenied da AWS.
  role_name             = "delegated-imagebuilder"
  instance_profile_name = "delegated-imagebuilder"

  permissions_boundary_arn = var.permissions_boundary_arn

  vpc_id              = var.vpc_id
  subnet_id           = var.build_subnet_id
  security_group_name = "acme-swe-prod-images-build-sg"

  instance_types = [var.build_instance_type]

  # true: derruba a instancia se a build falhar. Trocar para false
  # TEMPORARIAMENTE para investigar uma falha por dentro da maquina.
  terminate_instance_on_failure = true

  # Tags da instancia TEMPORARIA de build e do volume dela. Sem isto, as horas
  # de build apareceriam no relatorio de custo sem alocacao.
  resource_tags = var.common_tags

  # Notificacao de build desligada por ora. Ligar passando o topico do A22:
  #   sns_topic_arn = "arn:aws:sns:us-west-2:111122223333:acme-swe-prod-alarms"
  #
  # Pensar antes: o topico e o mesmo dos alarmes de infraestrutura, e
  # notificacao de build bem-sucedida viraria ruido num canal que precisa ser
  # levado a serio. Se ligar, considere um topico proprio.
  sns_topic_arn = null

  # Log em S3 desligado. O Image Builder ja grava o log dos componentes no
  # CloudWatch Logs em /aws/imagebuilder/<nome-da-imagem>, e e de la que saiu
  # o diagnostico das builds que falharam em 14/10.
  s3_logs_bucket = null
}

# ---------------------------------------------------------------------------
# Infrastructure configuration para builds ARM64 (Graviton)
#
# POR QUE UMA SEGUNDA: a instancia de build precisa EXECUTAR a imagem-pai, e a
# arquitetura e assada na AMI. Build de imagem arm64 exige instancia arm64
# (t4g); nao da para usar t3a. E nao da para listar os dois tipos na mesma
# configuracao: o Image Builder escolheria um e a build falharia quando a
# escolha nao casasse com a arquitetura da imagem-pai.
#
# POR QUE NAO E UMA SEGUNDA CHAMADA DO MODULO: o modulo cria tambem o papel, o
# instance profile e o security group, e chamar duas vezes tentaria criar dois
# objetos de IAM com o mesmo nome. Esses recursos NAO dependem de arquitetura,
# entao sao reaproveitados do modulo - aqui so muda o instance_types.
#
# Quando houver uma terceira variacao de build, vale extrair a infrastructure
# configuration do modulo para um for_each proprio. Com duas, duplicar e mais
# simples de ler do que generalizar.
# ---------------------------------------------------------------------------

resource "aws_imagebuilder_infrastructure_configuration" "build_arm64" {
  name = "acme-swe-prod-images-build-arm64"

  instance_profile_name = module.build_infrastructure.instance_profile_name
  instance_types        = [var.build_instance_type_arm64]

  subnet_id          = var.build_subnet_id
  security_group_ids = [module.build_infrastructure.security_group_id]

  # Tags da instancia TEMPORARIA de build e do volume dela - o default_tags do
  # provider nao alcanca, porque quem as cria e o servico.
  resource_tags = var.common_tags

  terminate_instance_on_failure = true
}
