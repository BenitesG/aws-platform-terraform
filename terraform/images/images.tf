# ---------------------------------------------------------------------------
# images/images.tf
#
# As linhagens de imagem. Cada uma sao tres modulos: recipe, distribution e
# pipeline.
#
# Por que tres chamadas em vez de um modulo "imagem" que embrulha os tres:
# porque receita, distribuicao e pipeline tem ciclos de vida diferentes. Uma
# receita nova nao exige distribuicao nova; uma distribuicao pode ser
# compartilhada. Embrulhar os tres foi o que o modulo image-pipeline antigo
# fazia, e era o que impedia empilhar imagem sem duplicar codigo.
#
# ===========================================================================
# A HIERARQUIA
# ===========================================================================
#
#   Ubuntu 26.04 da Canonical  (parametro publico do SSM)
#            |
#            v
#   mb-base-ubuntu-2604        update-linux, timezone, cloudwatch-agent, cleanup
#            |
#            v
#   mb-docker-host-ubuntu-2604 update-linux, docker, cleanup
#
# EMPILHAR, nao repetir. A imagem de host de container usa a AMI da nossa
# imagem base como imagem-pai, entao ela e GARANTIDAMENTE a base mais Docker -
# nao "a base e o host de container construidos com os mesmos componentes em
# datas diferentes", que poderiam partir de niveis de patch distintos.
#
# A frase que se quer poder dizer: "todo servidor e a imagem base; alguns tem
# mais coisa".
#
# Em troca, cria cadeia de dependencia: a imagem de Docker e tao antiga quanto
# a base de onde partiu, e repicar a base nao atualiza a filha sozinho.
# ===========================================================================

# ---------------------------------------------------------------------------
# Linhagem 1 - imagem base
#
# Nome derivado da versao: "26.04" vira "mb-base-ubuntu-2604". Trocar a versao
# gera LINHAGEM NOVA - receita, distribuicao e pipeline novos - o que e o
# comportamento correto: versao de SO diferente nao e atualizacao da mesma
# imagem.
# ---------------------------------------------------------------------------

locals {
  base_name         = "mb-base-ubuntu-${replace(var.ubuntu_version, ".", "")}"
  docker_name       = "mb-docker-host-ubuntu-${replace(var.ubuntu_version, ".", "")}"
  base_arm64_name   = "mb-base-ubuntu-${replace(var.ubuntu_version, ".", "")}-arm64"
  docker_arm64_name = "mb-docker-host-ubuntu-${replace(var.ubuntu_version, ".", "")}-arm64"

  # AMIs-pai FIXAS, nao o valor do data source do SSM.
  #
  # POR QUE: o parametro publico da Canonical aponta para "a atual" e muda
  # sozinho quando ela republica - aconteceu em 16/10/2026 as 03:20. Como
  # parent_image e ForceNew numa receita, valor dinamico faz o Terraform
  # querer SUBSTITUIR as receitas a cada republicacao, e a substituicao
  # FALHARIA porque ha imagens referenciando (ResourceDependencyException).
  #
  # O data source continua existindo, mas apenas para CONSULTAR qual e a
  # atual - virou output informativo, nao entrada da receita.
  parent_ami_ubuntu       = var.base_parent_ami_amd64
  parent_ami_ubuntu_arm64 = var.base_parent_ami_arm64
}

module "base_recipe" {
  source = "./modules/recipe"

  name = local.base_name

  # SEM description, e isto NAO e esquecimento.
  #
  # Receita e IMUTAVEL no Image Builder: todo argumento e ForceNew. A receita
  # que existe hoje foi criada sem descricao, entao acrescentar uma faria o
  # Terraform tentar SUBSTITUIR - e a substituicao falharia com
  # ResourceDependencyException, porque a ami-0a1b2c3d4e5fb0008 referencia
  # esta receita.
  #
  # Na linhagem base o diff tem de ser ZERO para o bloco moved ser um MOVE.
  # A linhagem do Docker, sendo nova, tem descricao normalmente.

  # 1.0.3 - CICLO DE 19/10/2026. Tres mudancas no mesmo apply, de proposito:
  # pagar o custo da substituicao de receita uma vez em vez de tres.
  #
  #   1. mb-timezone 1.0.1, com a fonte de tempo da AWS
  #   2. AMI-pai atualizada para a republicacao da Canonical de 16/10
  #   3. (consequencia) patches de SO acumulados desde 14/10
  #
  # O comentario anterior dizia "NAO MUDAR nesta refatoracao" - aquilo valia
  # para a refatoracao em modulos de 15/10, onde o diff tinha de ser ZERO para
  # os blocos moved serem MOVE e nao replace. Aquele apply foi concluido e os
  # blocos moved ja foram removidos, entao a restricao nao se aplica mais.
  recipe_version = "1.0.3"

  parent_image     = local.parent_ami_ubuntu
  root_volume_size = var.root_volume_size

  # A ORDEM E A ORDEM DE EXECUCAO. O cleanup e o ULTIMO.
  #
  # O "x.x.x" nos componentes gerenciados nao e placeholder: e a sintaxe do
  # Image Builder para "a versao mais recente".
  #
  # Nota sobre o update-linux: ele tenta instalar amazon-ssm-agent por apt e
  # falha com "E: Unable to locate package". E INOFENSIVO - no Ubuntu o agente
  # e snap e ja vem na AMI da Canonical. A build segue normalmente.
  component_arns = [
    "arn:aws:imagebuilder:${var.region}:aws:component/update-linux/x.x.x",
    module.component_timezone.arn,
    "arn:aws:imagebuilder:${var.region}:aws:component/amazon-cloudwatch-agent-linux/x.x.x",
    module.component_cleanup.arn,
  ]
}

module "base_distribution" {
  source = "./modules/distribution"

  # Sem description, pelo mesmo motivo da receita: diff zero na linhagem base.
  name           = local.base_name
  region         = var.region
  recipe_version = module.base_recipe.version
  parent_image   = module.base_recipe.parent_image
  common_tags    = var.common_tags

  # TAGS DA LINHAGEM, alinhadas em 16/10 com o que foi aplicado a mao nas AMIs
  # e snapshots existentes.
  #
  # POR QUE AQUI: ami_tags e o UNICO lugar que tagueia a AMI e o snapshot. O
  # default_tags do provider nao alcanca nenhum dos dois, porque quem os cria e
  # o servico. Mudar a tag no console resolve o recurso que ja existe, mas a
  # PROXIMA build volta com o valor do codigo - foi o que ia acontecer aqui.
  #
  # extra_ami_tags e mesclado POR ULTIMO no modulo, entao sobrescreve o Name
  # padrao (que seria o nome do recurso, sem o sufixo de arquitetura).
  #
  # "x86" por brevidade, decidido em 16/10 - entende-se como x86_64. O
  # importante e a consistencia: o Cost Explorer trata grafias diferentes como
  # aplicacoes diferentes.
  extra_ami_tags = {
    Name                               = "${local.base_name}-x86"
    "acme:cost-allocation:Application" = "ubuntu-2604-x86"
  }
}

module "base_pipeline" {
  source = "./modules/pipeline"

  # Sem description: diff zero.
  name = local.base_name

  recipe_arn         = module.base_recipe.arn
  infrastructure_arn = module.build_infrastructure.arn
  distribution_arn   = module.base_distribution.arn

  # TAGS DA LINHAGEM. Acrescentado em 16/10: os tres pipelines estavam com
  # Application = golden-image, herdada do default_tags, e eram
  # indistinguiveis por tag - a mesma ambiguidade que as AMIs e as politicas
  # de retencao resolveram mais cedo no mesmo dia.
  #
  # O valor casa com o extra_ami_tags da distribuicao e com a chave em
  # retention_lineages, de proposito: as tres camadas dizem a mesma coisa.
  #
  # NAO e isto que faz a retencao funcionar - ela le o recurso image, nao o
  # pipeline. Aqui e inventario.
  extra_tags = {
    "acme:cost-allocation:Application" = "ubuntu-2604-x86"
  }

  # Disparo manual. Sem schedule - o agendamento mensal entra quando a cadencia
  # de repique for decidida (A42) E o tagueamento do recurso image estiver
  # automatizado pela Lambda, porque hoje ele e manual depois de cada build.
  schedule = null
}

# ---------------------------------------------------------------------------
# Linhagem 2 - host de container (Docker)
#
# EMPILHADA sobre a imagem base.
#
# Docker NAO entra na imagem base: o daemon roda como root e pertencer ao
# grupo "docker" equivale a ser root - da para montar o filesystem do host
# dentro de um container. Nao deve estar em servidor que nao precisa.
# ---------------------------------------------------------------------------

module "docker_host_recipe" {
  source = "./modules/recipe"

  name        = local.docker_name
  description = "Host de container: imagem base mais Docker Engine com pool de enderecos proprio"

  # 1.0.3 - ciclo da fase 2, 19/10. Reponta para a base x86 NOVA
  # (ami-0a1b2c3d4e5fb0003), que traz a correcao do relogio e a AMI-pai
  # republicada em 16/10.
  #
  # Isto e o que LIBERA a ami-0a1b2c3d4e5fb0008 para remocao: ela era a
  # imagem-pai desta receita, e essa era a unica referencia que a prendia.
  #
  # ESTE E O CASO CLASSICO DAS "DUAS VERSOES": o ARN do componente inclui a
  # versao dele, entao mudar o componente MUDA A RECEITA. Subir so a do
  # componente faria o apply nao mudar a receita e a build continuar usando a
  # versao antiga - sem erro nenhum.
  recipe_version = "1.0.3"

  # A IMAGEM-PAI E A NOSSA PROPRIA AMI BASE, nao a do Ubuntu.
  #
  # O valor e FIXO e vem do tfvars, de proposito - mesmo motivo pelo qual o
  # ami_id das instancias e fixo. Um data "aws_ami" com most_recent = true
  # parece conveniente e e perigoso: uma build nova da base mudaria o valor, e
  # o proximo apply - mesmo um feito para outra coisa - substituiria esta
  # receita sem ninguem pedir.
  #
  # Trocar de base deve ser ato deliberado: muda-se a variavel sabendo que a
  # receita sera substituida e que a versao precisa subir.
  parent_image     = var.base_ami_id
  root_volume_size = var.root_volume_size

  # NAO repete timezone nem o agente do CloudWatch: ja vieram da imagem base e
  # estao no disco. Isso e o ganho de empilhar.
  #
  # O update-linux ENTRA de novo, e de proposito: pega os patches publicados
  # entre a build da base e esta build.
  #
  # O cleanup TAMBEM entra de novo, e isso e facil de esquecer ao empilhar: a
  # instancia de build desta imagem nasce da AMI base e gera identidade NOVA
  # no primeiro boot - chaves de host SSH, machine-id, estado do cloud-init.
  # Sem rodar a limpeza outra vez, essa identidade iria para o snapshot.
  component_arns = [
    "arn:aws:imagebuilder:${var.region}:aws:component/update-linux/x.x.x",
    module.component_docker.arn,
    module.component_cleanup.arn,
  ]
}

module "docker_host_distribution" {
  source = "./modules/distribution"

  name           = local.docker_name
  description    = "Distribuicao da imagem de host de container na us-west-2"
  region         = var.region
  recipe_version = module.docker_host_recipe.version

  # ParentImage recebe a AMI da nossa base, o que torna a cadeia auditavel:
  # olhando a AMI do host de container, da para saber de qual base ela nasceu.
  parent_image = module.docker_host_recipe.parent_image
  common_tags  = var.common_tags

  # Tags da linhagem, alinhadas em 16/10 com o que foi aplicado a mao.
  # Ver a nota em base_distribution.
  extra_ami_tags = {
    Name                               = "${local.docker_name}-x86"
    "acme:cost-allocation:Application" = "docker-ubuntu-2604-x86"
    ImageRole                          = "docker-host"
  }
}

module "docker_host_pipeline" {
  source = "./modules/pipeline"

  name        = local.docker_name
  description = "Pipeline do host de container: base mais Docker"

  recipe_arn         = module.docker_host_recipe.arn
  infrastructure_arn = module.build_infrastructure.arn
  distribution_arn   = module.docker_host_distribution.arn

  # Tag da linhagem. Ver a nota em base_pipeline.
  extra_tags = {
    "acme:cost-allocation:Application" = "docker-ubuntu-2604-x86"
  }

  schedule = null
}

# ---------------------------------------------------------------------------
# Linhagem 3 - imagem base ARM64 (Graviton)
#
# Para instancias t4g. NAO e variacao das outras: linhagem propria, porque a
# arquitetura e assada na AMI e imagem amd64 nao roda em t4g.
#
# Parte da AMI publica da Canonical arm64, nao da nossa base amd64 - nao da
# para empilhar entre arquiteturas diferentes.
#
# Usa a infrastructure configuration ARM, porque a instancia de build tambem
# precisa ser Graviton.
#
# Disco de 30 GB, maior que os 20 GB das outras.
# ---------------------------------------------------------------------------

module "base_arm64_recipe" {
  source = "./modules/recipe"

  name        = local.base_arm64_name
  description = "Imagem base ARM64 (Graviton) para instancias t4g"

  # 1.0.1 - ciclo de 19/10: mb-timezone 1.0.1 (fonte de tempo da AWS) e
  # AMI-pai atualizada para a republicacao da Canonical de 16/10.
  recipe_version = "1.0.1"

  parent_image     = local.parent_ami_ubuntu_arm64
  root_volume_size = var.arm64_root_volume_size

  # Mesmos componentes da base amd64, e de proposito: o padrao da empresa nao
  # muda com a arquitetura. Os componentes proprios sao scripts shell, que
  # rodam igual nas duas.
  #
  # O cleanup e sempre o ULTIMO.
  #
  # NOTA sobre o amazon-cloudwatch-agent-linux: o componente gerenciado tem
  # versao arm64, entao funciona. Se a build falhar nele, conferir no log se a
  # mensagem fala de arquitetura - seria o primeiro suspeito.
  component_arns = [
    "arn:aws:imagebuilder:${var.region}:aws:component/update-linux/x.x.x",
    module.component_timezone.arn,
    "arn:aws:imagebuilder:${var.region}:aws:component/amazon-cloudwatch-agent-linux/x.x.x",
    module.component_cleanup.arn,
  ]
}

module "base_arm64_distribution" {
  source = "./modules/distribution"

  name           = local.base_arm64_name
  description    = "Distribuicao da imagem base ARM64 na us-west-2"
  region         = var.region
  recipe_version = module.base_arm64_recipe.version
  parent_image   = module.base_arm64_recipe.parent_image
  common_tags    = var.common_tags

  # Tags da linhagem, alinhadas em 16/10 com o que foi aplicado a mao.
  # O Name ja tinha o sufixo -arm64 pelo nome do recurso; aqui fica explicito
  # junto da Application, para as tres linhagens seguirem o mesmo padrao.
  extra_ami_tags = {
    Name                               = local.base_arm64_name
    "acme:cost-allocation:Application" = "ubuntu-2604-arm64"
    Architecture                       = "arm64"
  }
}

module "base_arm64_pipeline" {
  source = "./modules/pipeline"

  name        = local.base_arm64_name
  description = "Pipeline da imagem base ARM64 (Graviton)"

  recipe_arn = module.base_arm64_recipe.arn

  # A infrastructure configuration ARM, nao a compartilhada.
  infrastructure_arn = aws_imagebuilder_infrastructure_configuration.build_arm64.arn
  distribution_arn   = module.base_arm64_distribution.arn

  # Tag da linhagem. Ver a nota em base_pipeline.
  extra_tags = {
    "acme:cost-allocation:Application" = "ubuntu-2604-arm64"
  }

  schedule = null
}

# ---------------------------------------------------------------------------
# Linhagem 4 - host de container ARM64 (Graviton)
#
# CRIADA EM 19/10/2026. E a quarta e ultima linhagem do padrao: base e host de
# container, em x86 e arm64.
#
# POR QUE ELA PRECISAVA EXISTIR: a operationalflow e t4g e teve Docker
# instalado A MAO depois do lancamento, porque nao havia imagem de host de
# container ARM. A consequencia pratica e que ela roda SEM o daemon.json do
# componente - sem rotacao de log (max-size 10m, max-file 3) num disco de
# 30 GB. Container que loga muito enche o disco e derruba a maquina, com
# sintoma "o servidor parou" sem causa obvia. E o modo de falha mais provavel
# daquela instancia hoje.
#
# NAO DA PARA EMPILHAR ENTRE ARQUITETURAS: parte da base arm64, nao da x86. A
# arquitetura e assada na AMI.
#
# OS COMPONENTES SAO OS MESMOS da linhagem x86, sem adaptacao. Confirmado em
# 19/10 por inspecao: o docker.yml monta a linha do repositorio com
# "$(dpkg --print-architecture)", entao resolve arm64 sozinho. Mesma coisa do
# fuso e da limpeza - sao scripts shell. Ja havia sido comprovado em 15/10,
# quando os componentes proprios rodaram em ARM sem mudanca na base arm64.
# ---------------------------------------------------------------------------

module "docker_host_arm64_recipe" {
  source = "./modules/recipe"

  name        = local.docker_arm64_name
  description = "Host de container ARM64 (Graviton): imagem base arm64 mais Docker Engine"

  recipe_version = "1.0.0"

  # A base ARM64, nao a x86. Fixo no tfvars de proposito.
  parent_image     = var.base_arm64_ami_id
  root_volume_size = var.arm64_root_volume_size

  # NAO repete timezone nem o agente do CloudWatch: ja vieram da base arm64.
  #
  # O update-linux ENTRA de novo, de proposito: pega os patches publicados
  # entre a build da base e esta build.
  #
  # O cleanup TAMBEM entra de novo - a instancia de build nasce da AMI base e
  # gera identidade NOVA no primeiro boot (chaves de host SSH, machine-id,
  # estado do cloud-init). Sem rodar a limpeza outra vez, essa identidade iria
  # para o snapshot.
  component_arns = [
    "arn:aws:imagebuilder:${var.region}:aws:component/update-linux/x.x.x",
    module.component_docker.arn,
    module.component_cleanup.arn,
  ]
}

module "docker_host_arm64_distribution" {
  source = "./modules/distribution"

  name           = local.docker_arm64_name
  description    = "Distribuicao da imagem de host de container ARM64 na us-west-2"
  region         = var.region
  recipe_version = module.docker_host_arm64_recipe.version

  # ParentImage recebe a AMI da nossa base arm64, o que torna a cadeia
  # auditavel: olhando a AMI, da para saber de qual base ela nasceu.
  parent_image = module.docker_host_arm64_recipe.parent_image
  common_tags  = var.common_tags

  # A tag Application TEM de casar com a chave em retention_lineages do
  # lifecycle.tf, senao a politica de retencao nao seleciona nada - e falha em
  # silencio, sem erro nenhum.
  extra_ami_tags = {
    Name                               = local.docker_arm64_name
    "acme:cost-allocation:Application" = "docker-ubuntu-2604-arm64"
    ImageRole                          = "docker-host"
    Architecture                       = "arm64"
  }
}

module "docker_host_arm64_pipeline" {
  source = "./modules/pipeline"

  name        = local.docker_arm64_name
  description = "Pipeline do host de container ARM64: base arm64 mais Docker"

  recipe_arn = module.docker_host_arm64_recipe.arn

  # A infrastructure configuration ARM, nao a compartilhada: a instancia de
  # build tambem precisa ser Graviton.
  infrastructure_arn = aws_imagebuilder_infrastructure_configuration.build_arm64.arn
  distribution_arn   = module.docker_host_arm64_distribution.arn

  extra_tags = {
    "acme:cost-allocation:Application" = "docker-ubuntu-2604-arm64"
  }

  schedule = null
}