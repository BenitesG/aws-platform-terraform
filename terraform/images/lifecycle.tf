# ---------------------------------------------------------------------------
# images/lifecycle.tf
#
# Politica de descontinuacao das golden images.
#
# POR QUE ISTO NAO E OPCIONAL: cada build guarda um snapshot EBS do disco da
# imagem. Com 20 GB, e da ordem de US$ 1/mes por versao. Num repique mensal,
# doze meses sem limpeza viram ~US$ 12/mes de imagem que ninguem usa - e o
# custo cresce em silencio, sem alarme nenhum. Mesmo padrao do EIP esquecido.
#
# Ha um segundo motivo, descoberto em 14/10: receitas e componentes nao podem
# ser apagados enquanto existir imagem que os referencie. Sem descontinuacao,
# as receitas antigas tambem acumulam sem poder ser removidas.
# ---------------------------------------------------------------------------

# O papel que o servico de lifecycle assume para apagar AMI e snapshot.
#
# Diferente do papel de build: este e assumido pelo PROPRIO SERVICO
# (imagebuilder.amazonaws.com), nao por uma instancia EC2.
resource "aws_iam_role" "lifecycle" {
  # Prefixo delegated- obrigatorio pela DelegatedAdminBoundary.
  name = "delegated-imagebuilder-lifecycle"

  # Sem a boundary o CreateRole e negado.
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "imagebuilder.amazonaws.com" }
    }]
  })

  description = "Papel de execucao da politica de descontinuacao de imagens"
}

resource "aws_iam_role_policy_attachment" "lifecycle" {
  role       = aws_iam_role.lifecycle.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/EC2ImageBuilderLifecycleExecutionPolicy"
}

# ---------------------------------------------------------------------------
# DESTRAVADO EM 15/10/2026
#
# Historico: a criacao falhou em 14/10 com
#   AccessDeniedException: not authorized to perform iam:PassRole on
#   role/delegated-imagebuilder-lifecycle because no permissions boundary
#   allows the iam:PassRole action
#
# Causa: o statement "PassRoleSomenteParaServicos" da DelegatedAdminBoundary
# restringia iam:PassRole a ec2, lambda e ecs-tasks. A politica de lifecycle
# passa o papel para imagebuilder.amazonaws.com, que nao estava na lista.
#
# O administrador publicou a v2 da boundary em 15/10 13:38 UTC, trocando
# StringEquals por StringLike com "lambda*", "ecs*", "ec2.*" e "image*".
# Confirmado por simulate-principal-policy, com a MESMA sessao de antes
# (mudanca em documento de politica vale na proxima chamada, nao exige
# relogin):
#   PassRole -> imagebuilder.amazonaws.com .............. allowed
#   imagebuilder:CreateLifecyclePolicy ................... allowed
#
# RESSALVA REGISTRADA: o curinga alargou a boundary mais que o necessario -
# "ecs*" agora cobre ecs.amazonaws.com, nao so ecs-tasks. Nao e bloqueante,
# mas a versao estreita (StringEquals com os quatro principais exatos) daria o
# mesmo resultado funcional sem ampliar nada.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# UMA POLITICA POR LINHAGEM, decidido em 16/10
#
# Antes havia UMA politica selecionando Application = golden-image, valor que
# as tres linhagens compartilhavam. Dois problemas nisso:
#
#   1. O agrupamento do COUNT ficava ambiguo - "manter as 3 mais recentes"
#      valia por linhagem ou para o conjunto? Com 2 builds de cada, a mais
#      antiga poderia ser apagada mesmo sendo a unica daquela linhagem. E a
#      base x86 e IMAGEM-PAI do host de container: apaga-la quebraria a
#      receita filha
#   2. Nao dava para diferenciar imagens no inventario nem no Cost Explorer
#
# Com uma politica por linhagem, "as 3 mais recentes" e inequivoco, e o
# acrescimo de uma linhagem nova e uma entrada no mapa.
#
# ATENCAO - ISTO AINDA NAO FUNCIONA, e o motivo e importante:
#
# A selecao por tag avalia tags no RECURSO IMAGE do Image Builder, nao na AMI
# de saida. A documentacao da AWS: "tags on the Image Builder image resource
# only, not on output AMIs". E o recurso image nasce SEM TAGS - nao propaga do
# pipeline nem da receita (verificado em 15 e 16/10).
#
# Entao e preciso taguear o recurso image DEPOIS de cada build:
#   aws imagebuilder tag-resource --resource-arn <arn da imagem> \
#     --tags "acme:cost-allocation:Application=<linhagem>"
#
# A Lambda desenhada no A44 existe para automatizar isso - ela copiaria as
# tags da receita para a imagem, de forma generica. Nao foi implementada.
# ---------------------------------------------------------------------------

locals {
  # chave = valor da tag Application na linhagem
  # valor = nome da politica de retencao
  #
  # Os valores da chave vem do que foi aplicado nas AMIs em 16/10 e do
  # ami_tags das distribution configurations - os dois precisam casar, senao a
  # politica nao seleciona nada.
  #
  # QUATRO LINHAGENS Ubuntu desde 19/10, mais a WINDOWS desde 23/10.
  # A arm64 de host de container existe porque a operationalflow e t4g e teve
  # Docker instalado A MAO - sem linhagem propria, o daemon.json com rotacao
  # de log nao chega em maquina Graviton.
  #
  # A chave TEM DE CASAR com o acme:cost-allocation:Application do extra_ami_tags
  # da distribution configuration da linhagem - senao a politica seleciona
  # nada. A da Windows e "windows-2025", definida em windows.tf.
  retention_lineages = {
    "ubuntu-2604-x86"          = "acme-swe-prod-retention-ubuntu-2604-x86"
    "ubuntu-2604-arm64"        = "acme-swe-prod-retention-ubuntu-2604-arm64"
    "docker-ubuntu-2604-x86"   = "acme-swe-prod-retention-docker-ubuntu-2604-x86"
    "docker-ubuntu-2604-arm64" = "acme-swe-prod-retention-docker-ubuntu-2604-arm64"
    "windows-2025"             = "acme-swe-prod-retention-windows-2025"
  }
}

resource "aws_imagebuilder_lifecycle_policy" "golden_images" {
  for_each = local.retention_lineages

  name           = each.value
  description    = "Mantem as 2 versoes mais recentes da linhagem ${each.key}"
  execution_role = aws_iam_role.lifecycle.arn
  resource_type  = "AMI_IMAGE"
  status         = "ENABLED"

  policy_detail {
    action {
      type = "DELETE"

      # snapshots = true e o ponto central: desregistrar a AMI sem apagar o
      # snapshot nao libera custo nenhum, porque o armazenamento esta no
      # snapshot, nao na AMI.
      #
      # containers = false E OBRIGATORIO DECLARAR, mesmo sendo o padrao.
      #
      # Sem esta linha o apply falha com "Provider produced inconsistent
      # result after apply": o provider planeja containers como UNKNOWN, a API
      # devolve false, e como policy_detail e um SET o elemento planejado nao
      # correlaciona com o retornado. O recurso chega a ser criado na AWS, mas
      # o apply aborta. Descoberto no apply de 15/10.
      include_resources {
        amis       = true
        snapshots  = true
        containers = false
      }
    }

    # COUNT = mantem as N mais recentes. A alternativa seria AGE (por idade),
    # que e pior aqui: se ninguem construir imagem por meses, AGE apagaria a
    # unica que existe.
    #
    # Com UMA POLITICA POR LINHAGEM o agrupamento e inequivoco: sao as N mais
    # recentes DESTA linhagem.
    #
    # COUNT 2, baixado de 3 em 19/10. O motivo e o TETO, nao o presente:
    #
    #   4 linhagens x 3 versoes = ate 300 GB  ~US$ 15,00/mes
    #   4 linhagens x 2 versoes = ate 200 GB  ~US$ 10,00/mes
    #
    # Duas versoes e o MINIMO que preserva rollback: "a atual e a anterior".
    # Se uma build nova sair defeituosa, da para voltar. A terceira guardada
    # nao resolve nada que a segunda ja nao resolva.
    #
    # COUNT 1 foi descartado: apagaria justamente a versao que funcionava no
    # momento em que a nova entrasse, deixando a conta sem caminho de volta.
    filter {
      type  = "COUNT"
      value = 2
    }

    # Rede de seguranca: nao apaga AMI usada para lancar instancia nos
    # ultimos 30 dias, mesmo que ela caia fora das 3 mais recentes.
    #
    # Apagar a AMI nao derruba instancia ja rodando - ela tem volume proprio.
    # O que se perde e a capacidade de lancar OUTRA instancia identica, e e
    # exatamente isso que esta regra protege.
    #
    # Protege PARCIALMENTE a AMI base: a build do host de container lanca uma
    # instancia a partir dela, o que atualiza o last_launched. Mas se ninguem
    # construir o host de container por mais de 30 dias, essa protecao expira.
    exclusion_rules {
      amis {
        # is_public = false TEM DE SER DECLARADO, mesmo sendo o padrao - mesma
        # armadilha do containers acima.
        #
        # A API devolve is_public = false; sem declarar, o elemento do set
        # policy_detail difere do que esta no estado e o plan fica com DIFF
        # PERPETUO: toda execucao mostra policy_detail sendo removido e
        # recriado, e "No changes" nunca mais aparece. Descoberto em 15/10,
        # depois do untaint.
        #
        # Nossas AMIs nunca sao publicas (o A06 bloqueia acesso publico na
        # conta), entao false tambem e o valor correto por desenho: a regra
        # "nao apague AMI publica" nao tem efeito aqui.
        is_public = false

        last_launched {
          unit  = "DAYS"
          value = 30
        }
      }
    }
  }

  # Selecao por TAG DA LINHAGEM, nao por receita: assim a politica acompanha
  # as versoes futuras da mesma linhagem sem ser editada.
  #
  # LEMBRE: isto avalia tags no RECURSO IMAGE do Image Builder, NAO na AMI de
  # saida. E o recurso image nasce sem tags - precisa ser tagueado depois de
  # cada build, a mao ou pela Lambda do A44. Ver a nota no topo.
  resource_selection {
    tag_map = {
      "acme:cost-allocation:Application" = each.key
    }
  }

  # Garante que a politica gerenciada esteja anexada antes de o servico tentar
  # usar o papel.
  depends_on = [aws_iam_role_policy_attachment.lifecycle]
}

output "lifecycle_policy_arns" {
  description = "ARNs das politicas de retencao, uma por linhagem"
  value       = { for k, v in aws_imagebuilder_lifecycle_policy.golden_images : k => v.arn }
}

# ---------------------------------------------------------------------------
# O QUE FALTA PARA A RETENCAO FUNCIONAR DE FATO
#
# As politicas estao ENABLED e corretas, mas NAO SELECIONAM NADA ainda,
# porque o recurso IMAGE do Image Builder nasce sem tags.
#
# As tres camadas de recurso e quem le o que:
#
#   recurso IMAGE do Image Builder  -> SEM tags  -> E ESTA que a retencao le
#   AMI de saida                    -> tagueada  -> nao e lida pela retencao
#   snapshot                        -> tagueado  -> nao e lido pela retencao
#
# As tags de AMI e snapshot servem para INVENTARIO e Cost Explorer, e nisso
# sao uteis: dao para separar custo de snapshot por linhagem. Mas a selecao da
# politica avalia so o recurso image.
#
# PARA CADA BUILD, taguear o recurso image:
#
#   aws imagebuilder tag-resource `
#     --resource-arn "arn:aws:imagebuilder:us-west-2:111122223333:image/<nome>/<versao>/1" `
#     --tags "acme:cost-allocation:Application=<linhagem>" `
#     --profile acme-swe-prod
#
# Linhagens validas, que precisam casar com as chaves de retention_lineages:
#   ubuntu-2604-x86 . ubuntu-2604-arm64 . docker-ubuntu-2604-x86
#
# A Lambda desenhada no A44 automatiza isso de forma generica: le a receita da
# imagem (image.imageRecipe.arn), pega as tags dela - que o Terraform ja cria
# completas - e copia para a imagem. Nao precisa de tabela de linhagens, e
# qualquer imagem futura funciona sozinha. Nao foi implementada: com disparo
# manual e poucas imagens, taguear a mao e mais honesto que manter codigo.
#
# COMO CONFERIR depois da primeira execucao de uma politica:
#   aws imagebuilder list-lifecycle-execution-resources \
#     --lifecycle-execution-id <id>
# Mostra exatamente o que ela marcou. Vale olhar ANTES de confiar nela com
# varias versoes acumuladas.
# ---------------------------------------------------------------------------
