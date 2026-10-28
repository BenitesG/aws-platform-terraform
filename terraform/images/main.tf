# ---------------------------------------------------------------------------
# images/main.tf
#
# AMI-pai publica e os COMPONENTES proprios, compartilhados entre receitas.
#
# Mapa do diretorio:
#   main.tf (este)      AMI-pai e componentes
#   infrastructure.tf   onde a build roda (IAM, SG, infrastructure config)
#   images.tf           as linhagens de imagem: base, docker-host e base arm64
#   moved.tf            refatoracao: diz ao Terraform que os recursos
#                       trocaram de endereco, nao de identidade
#   outputs.tf          ARNs para disparar as builds
#   lifecycle.tf        retencao - ATIVA, 3 politicas (uma por linhagem)
# ---------------------------------------------------------------------------

# "data" nao cria nada: apenas LE uma informacao existente na AWS. Aqui le o
# ID da AMI oficial do Ubuntu que a Canonical publica num parametro publico do
# SSM, o que faz a referencia acompanhar a republicacao da imagem.
#
# A arquitetura esta no CAMINHO do parametro. Padrao definido: amd64. Para
# Graviton seria ".../arm64/hvm/ebs-gp3/ami-id" - e a imagem resultante NAO
# rodaria em instancia t3a, porque a arquitetura e assada na AMI.
#
# SE DER ERRO neste data source, o caminho do parametro pode ter mudado.
# Contorno: trocar por uma variavel com o ID da AMI.
# "data" nao cria nada: apenas LE uma informacao existente na AWS. Aqui le o
# ID da AMI oficial do Ubuntu que a Canonical publica num parametro publico do
# SSM.
#
# ATENCAO: ISTO NAO ALIMENTA AS RECEITAS.
#
# O parametro aponta para "a ATUAL" e muda sozinho quando a Canonical
# republica - em 16/10/2026 isso aconteceu as 03:20. Como parent_image e
# ForceNew numa receita do Image Builder, usar este valor direto fazia o
# Terraform querer SUBSTITUIR as receitas a cada republicacao, sem ninguem ter
# mudado nada. E a substituicao FALHARIA, porque receita referenciada por
# imagem ja construida nao pode ser removida.
#
# As receitas usam var.base_parent_ami_amd64 e var.base_parent_ami_arm64,
# fixas no tfvars. Estes data sources servem para CONSULTAR qual e a atual
# quando se quiser atualizar deliberadamente - ver os outputs
# parent_ami_ubuntu_disponivel e parent_ami_ubuntu_arm64_disponivel.
#
# A arquitetura esta no CAMINHO do parametro. Padrao definido: amd64.
#
# SE DER ERRO aqui, o caminho do parametro pode ter mudado. Como ele nao
# alimenta mais nada critico, dá para remover sem quebrar as receitas.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/${var.ubuntu_version}/stable/current/${var.architecture}/hvm/ebs-gp3/ami-id"
}

data "aws_ssm_parameter" "ubuntu_arm64" {
  name = "/aws/service/canonical/ubuntu/server/${var.ubuntu_version}/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

# ---------------------------------------------------------------------------
# Componentes proprios
#
# Um componente por modulo. Compartilhados entre as receitas: o mb-cleanup
# roda nas duas linhagens, e e sempre o ULTIMO da lista.
#
# VALIDE O YAML LOCALMENTE antes do apply - uma build custa 15 a 25 minutos
# para descobrir erro de sintaxe:
#   ./awstoe validate --documents components/docker.yml
# ---------------------------------------------------------------------------

module "component_timezone" {
  source = "./modules/component"

  name = "mb-timezone"

  # SEM description, e isto NAO e esquecimento.
  #
  # Em aws_imagebuilder_component a descricao tambem e ForceNew, porque
  # componente e imutavel. O componente que existe hoje foi criado sem
  # descricao: acrescentar uma o SUBSTITUI, o que muda o ARN dele - e o ARN do
  # componente faz parte da receita, entao a receita base seria substituida em
  # cascata e falharia com ResourceDependencyException.
  #
  # Descoberto no plan desta refatoracao, que acusou "forces replacement".
  #
  # NOTA DE 19/10: a versao subiu para 1.0.1 e, portanto, o componente ESTA
  # sendo substituido neste ciclo. Mesmo assim a description continua fora, de
  # proposito - acrescenta-la agora nao traz nada e tornaria o diff maior sem
  # necessidade. O lugar de registrar o que o componente faz e o YAML, que tem
  # o diagnostico completo no topo.

  # 1.0.1 - acrescenta a fonte de tempo da AWS (169.254.169.123) e remove os
  # pools NTS da Canonical, que exigem TCP 4460 e sao inalcancaveis com a saida
  # restrita a 443/80. Diagnostico completo em components/timezone.yml.
  #
  # SUBIR ESTA VERSAO OBRIGA a subir o recipe_version das linhagens que o
  # consomem - base x86 e base arm64. As filhas herdam pela imagem-pai e nao
  # precisam ser tocadas.
  component_version = "1.0.1"

  data = file("${path.module}/components/timezone.yml")
}

module "component_cleanup" {
  source = "./modules/component"

  name = "mb-cleanup"

  # Sem description, pelo mesmo motivo do timezone: seria replace em cascata.

  # 1.0.2: a validacao do sshd virou diagnostico NAO BLOQUEANTE.
  #   1.0.0 falhou em "sshd -t" com 255; supus exigencia de caminho absoluto
  #   1.0.1 falhou em "/usr/sbin/sshd -t" com 255 - hipotese errada
  #   1.0.2 imprime o diagnostico no log sem derrubar a build
  #
  # A causa real era ambiental: /run e tmpfs e /run/sshd so existe quando o
  # servico sobe - e o ssh.service esta DESABILITADO por causa da ativacao por
  # socket. Nao era erro de configuracao.
  #
  # MELHORIA CONHECIDA, ainda nao aplicada: os passos RemoveSshHostKeys,
  # ResetMachineId e CleanCloudInit sao redundantes, porque o proprio Image
  # Builder roda um RunSanitizeScript antes do snapshot. Simplificar exigiria
  # subir esta versao e a das duas receitas - vale fazer junto com a proxima
  # mudanca real, nao numa build so para isso.
  component_version = "1.0.2"

  data = file("${path.module}/components/cleanup.yml")
}

module "component_docker" {
  source = "./modules/component"

  name        = "mb-docker"
  description = "Docker Engine com limite de log e live-restore"

  # 1.0.2: a validacao foi SIMPLIFICADA.
  #
  # A 1.0.1 tinha um passo que subia container e lia o LogConfig com
  # "grep -A3". A janela de 3 linhas cortava antes do max-size, e a build
  # 1.0.1/1 foi REPROVADA por engano - a configuracao estava correta
  # (max-file: 3 apareceu no log, provando a heranca).
  #
  # Ficou UMA verificacao: "Live Restore Enabled: true" no docker info, que so
  # aparece se veio do daemon.json. Se o daemon leu o arquivo, leu o log-opts
  # tambem - estao no mesmo arquivo. Verificador complicado vira fonte de
  # falha em vez de detector: das 3 falhas de build, 1 foi bug real e 2 foram
  # o proprio verificador.
  #
  # Historico das versoes anteriores:
  # 1.0.1 - daemon.json passou a ser escrito ANTES do apt install (o "apt
  #         install" ja sobe o daemon, e configuracao que so vale para
  #         recursos criados depois nao alcanca o que ele ja criou), e o
  #         default-address-pools customizado foi REMOVIDO, voltando ao padrao
  #         do Docker. Ver a nota ao fim de components/docker.yml.
  component_version = "1.0.2"

  data = file("${path.module}/components/docker.yml")
}
