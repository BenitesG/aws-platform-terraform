# ---------------------------------------------------------------------------
# modules/infrastructure/main.tf
#
# ONDE a build roda: papel, instance profile, security group e a
# infrastructure configuration. Compartilhado por todas as imagens.
#
# Como funciona uma build:
#   1. voce dispara o pipeline
#   2. o Image Builder sobe uma instancia EC2 TEMPORARIA a partir da AMI-pai
#   3. essa instancia recebe o instance profile declarado aqui
#   4. o servico manda comandos para dentro dela VIA SSM - e assim que os
#      componentes sao aplicados
#   5. desliga, tira a AMI do disco e destroi a instancia
#
# O papel nao e seu nem do Image Builder: e de uma maquina que vive uns 20
# minutos e morre. Por isso o instance profile e obrigatorio e nao existe
# "anexar depois" - voce nunca tem a chance de tocar nela.
#
# DUAS ADAPTACOES OBRIGATORIAS NESTA CONTA, ambas ausentes do modulo de
# referencia da equipe:
#
#   1. permissions_boundary no papel. Sem ela o CreateRole e NEGADO, com um
#      AccessDenied que NAO menciona a boundary
#   2. subnet e security group explicitos. O modulo de referencia os omite e
#      cai na VPC default - que NAO EXISTE mais em nenhuma regiao desta conta
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

# ---------------------------------------------------------------------------
# Papel da instancia de build
#
# Separado do delegated-ec2-ssm (das instancias de aplicacao) de proposito: a
# maquina de build precisa de permissoes que servidor de aplicacao nao deve
# ter. Juntar faria toda instancia da empresa carregar permissao de construir
# imagem.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "this" {
  # O prefixo "delegated-" e OBRIGATORIO, nao convencao de estilo. A
  # DelegatedAdminBoundary so permite criar papel, instance profile e politica
  # dentro de arn:aws:iam::*:role/delegated-*. Fora do prefixo, CreateRole e
  # negado.
  name = var.role_name

  # Sem esta linha o CreateRole e NEGADO. A boundary exige que todo papel
  # criado por delegacao carregue ela mesma como teto de permissao - e o que
  # impede escalada de privilegio por quem tem a delegacao.
  permissions_boundary = var.permissions_boundary_arn

  description = "Papel da instancia temporaria de build do EC2 Image Builder"

  # Metade 1 do papel: QUEM pode vesti-lo. Sem trust policy o papel existe
  # mas ninguem consegue usar.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Metade 2 do papel: O QUE ele pode fazer.
#
# EC2InstanceProfileForImageBuilder: baixar as definicoes dos componentes e
# enviar logs.
resource "aws_iam_role_policy_attachment" "imagebuilder" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

# AmazonSSMManagedInstanceCore: registrar a instancia no SSM. Sem ela a build
# fica parada esperando, porque o servico nao consegue executar os componentes
# dentro da maquina.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# O "cabide": um papel nao pode ser anexado direto a uma instancia EC2,
# precisa estar dentro de um instance profile. O console cria esse objeto
# automaticamente com o mesmo nome do papel, e por isso quase ninguem sabe que
# ele existe. Em Terraform ele e explicito.
resource "aws_iam_instance_profile" "this" {
  name = var.instance_profile_name
  role = aws_iam_role.this.name
}

# ---------------------------------------------------------------------------
# Security group da instancia de build
#
# Dedicado, em vez de reaproveitar o acme-swe-prod-app01-sg. Dois motivos:
#
#   - separacao de proposito: o SG da aplicacao vai GANHAR regra de entrada no
#     A35, quando o peering com a producao existir. A instancia de build nao
#     tem motivo para herdar aquilo
#   - o nome passa a dizer a que serve
#
# Entrada: NENHUMA. A build e orquestrada pelo SSM, que trabalha por conexao
# de SAIDA da propria instancia - nao ha nada entrando.
# ---------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = var.security_group_name
  description = "Instancia temporaria de build do Image Builder: apenas saida"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.security_group_name
  }
}

# Regras como recursos separados, nao blocos inline.
#
# Com "ingress"/"egress" inline, o Terraform assume a posse de TODAS as regras
# do SG e remove qualquer uma criada fora dele. Como recursos separados, a
# gestao e por regra - e o plan mostra exatamente qual regra muda.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "SSM, API da AWS, download de componentes e registry do Docker"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.this.id
  description       = "Repositorios apt do Ubuntu (pacotes assinados por GPG)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Infrastructure configuration
#
# A instancia de build vai na subnet PRIVADA: so precisa de SAIDA (para o SSM
# e para baixar pacotes), e a saida existe pelo NAT.
# ---------------------------------------------------------------------------

resource "aws_imagebuilder_infrastructure_configuration" "this" {
  name        = var.name
  description = var.description

  # Campo obrigatorio. Recebe o NOME do instance profile, nao o ARN.
  instance_profile_name = aws_iam_instance_profile.this.name

  instance_types = var.instance_types

  subnet_id          = var.subnet_id
  security_group_ids = [aws_security_group.this.id]

  # resource_tags e DIFERENTE de tags.
  #
  #   tags           -> taqueiam a infrastructure configuration em si
  #   resource_tags  -> taqueiam a INSTANCIA TEMPORARIA de build e o volume
  #                     dela, criados pelo Image Builder
  #
  # O default_tags do provider nao alcanca esses: ele vale para o que o
  # Terraform cria, e a instancia de build e criada pelo SERVICO. Sem isto, as
  # horas da build apareceriam no relatorio de custo sem alocacao.
  #
  # O Name da instancia de build NAO e sobrescrito aqui: o servico a nomeia
  # como "Build instance for <imagem>". Fixar um Name nesta configuracao seria
  # pior, porque ela e compartilhada entre imagens - o mesmo nome valeria para
  # toda build.
  resource_tags = var.resource_tags

  # true: derruba a instancia se a build falhar, evitando maquina esquecida
  # rodando e sendo cobrada, com instance profile anexado.
  #
  # O modulo de referencia da equipe usa false no exemplo, "para debug". Como
  # padrao e armadilha: build que falha de madrugada deixa EC2 ligada
  # indefinidamente. Troque para false TEMPORARIAMENTE quando precisar
  # investigar por dentro.
  terminate_instance_on_failure = var.terminate_instance_on_failure

  # Notificacao opcional. Reaproveita o topico acme-swe-prod-alarms do A22
  # quando passado.
  sns_topic_arn = var.sns_topic_arn

  # Log em S3 e OPCIONAL e esta desligado por padrao.
  #
  # O Image Builder ja grava o log dos componentes no CloudWatch Logs, em
  # /aws/imagebuilder/<nome-da-imagem>, sem configuracao nenhuma - e e de la
  # que saiu o diagnostico das builds que falharam em 14/10.
  #
  # O modulo de referencia da equipe cria um bucket por infrastructure
  # configuration com bucket_prefix, gerando nome com sufixo aleatorio que nao
  # segue mb-{escopo}-{ambiente}-{finalidade}. Preferimos nao criar bucket.
  dynamic "logging" {
    for_each = var.s3_logs_bucket != null ? [1] : []

    content {
      s3_logs {
        s3_bucket_name = var.s3_logs_bucket
        s3_key_prefix  = var.s3_logs_prefix
      }
    }
  }
}
