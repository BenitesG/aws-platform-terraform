# ---------------------------------------------------------------------------
# images/windows.tf - linhagem da imagem base WINDOWS SERVER 2025
#
# Pedido em 23/10 para a equipe legacy ERP: 7 VMs do site SITE-A (arquitetura APP
# App). Elas diferem em hostname, papel e tamanho do disco E: - tudo de
# INSTANCIA. O SO e identico nas sete, entao UMA imagem base serve todas. Esse
# e o padrao: o molde e a imagem; o que varia fica por VM, no diretorio
# instances/.
#
# ESTA IMAGEM E SO O SO: Windows Server 2025, ingles, Windows Update aplicado,
# RDP habilitado, firewall confirmado ligado. SEM App, SEM SQL Server - a legacy ERP
# instala na maquina entregue. A resolucao 1920x1080 do pedido se configura no
# CLIENTE RDP, nao na imagem - ver a nota em components/windows-base.yml.
#
# ===========================================================================
# POR QUE WINDOWS E DIFERENTE DAS QUATRO LINHAGENS UBUNTU
# ===========================================================================
#
# NAO EMPILHA. As linhagens Ubuntu empilham (docker-host parte da base). Esta
# e uma linhagem unica, chapada - nao ha "base Windows" e "Windows mais X" por
# enquanto. Se um dia houver, empilha igual.
#
# PLATFORM = "Windows" no componente. O modulo de componente ja suporta - a
# validacao aceita Linux ou Windows. Nao foi preciso tocar o modulo.
#
# COMPONENTE EM POWERSHELL, nao bash. E o AWSTOE de Windows NAO valida no WSL
# como o de Linux - so valida em instancia Windows real. A primeira build e o
# primeiro teste de verdade; erro de PowerShell na primeira e quase regra.
# Contar com 15-25 min por iteracao, e a build Windows inteira passa de 60 min
# por causa do Windows Update e do Sysprep.
#
# SEM COMPONENTE DE LIMPEZA, e isto e o OPOSTO da linhagem Linux.
#
#   No Linux, o cleanup.yml apaga identidade (chaves SSH, machine-id,
#   cloud-init) e e o ULTIMO da receita. Em Windows, o Image Builder roda
#   SYSPREP automaticamente no fim, via EC2Launch, para generalizar a imagem.
#   Escrever um componente de Sysprep COLIDE com o automatico e quebra a build.
#   Entao nao ha mb-cleanup aqui - o servico faz a limpeza.
#
# AMI-PAI FIXA, mesma disciplina das Ubuntu: parent_image e ForceNew, entao
# valor que rastreia "a mais recente" faria o Terraform querer substituir a
# receita a cada republicacao da AWS, e a substituicao falha se houver imagem
# referenciando. O valor vem de var.windows_parent_ami, fixo no tfvars.
# ===========================================================================

locals {
  windows_name = "acme-base-windows-2025"
}

# ---------------------------------------------------------------------------
# Infrastructure configuration para a build WINDOWS
#
# Mesmo padrao da build_arm64 em infrastructure.tf, e pela mesma razao: a
# instancia de build precisa ser de um tipo que comporte a imagem-pai.
# Windows Server 2025 nao sobe em t3a.small (a build da base Ubuntu x86),
# entao precisa de instance_types proprio - m5.large.
#
# REAPROVEITA o papel, o instance profile e o security group do modulo
# build_infrastructure: eles NAO dependem de SO. Chamar o modulo de novo
# tentaria criar IAM com nome duplicado - a mesma nota que esta na build_arm64.
# So o instance_types muda.
# ---------------------------------------------------------------------------

resource "aws_imagebuilder_infrastructure_configuration" "build_windows" {
  name = "acme-swe-prod-images-build-windows"

  instance_profile_name = module.build_infrastructure.instance_profile_name
  instance_types        = [var.windows_build_instance_type]

  subnet_id          = var.build_subnet_id
  security_group_ids = [module.build_infrastructure.security_group_id]

  resource_tags = var.common_tags

  terminate_instance_on_failure = true
}

# ---------------------------------------------------------------------------
# O componente proprio da base Windows
# ---------------------------------------------------------------------------

module "component_windows_base" {
  source = "./modules/component"

  name        = "mb-windows-base"
  description = "Base Windows Server 2025 para a legacy ERP: Windows Update, RDP habilitado, firewall confirmado"
  platform    = "Windows"

  # 1.0.0 - primeira versao. Diferente das Ubuntu, aqui a description ENTRA
  # desde o inicio: o componente nasce agora, nao ha recurso existente que uma
  # mudanca de description iria substituir.
  component_version = "1.0.0"

  data = file("${path.module}/components/windows-base.yml")
}

# ---------------------------------------------------------------------------
# Receita
# ---------------------------------------------------------------------------

module "windows_recipe" {
  source = "./modules/recipe"

  name        = local.windows_name
  description = "Imagem base Windows Server 2025 (legacy ERP / site SITE-A)"

  recipe_version = "1.0.0"

  parent_image = var.windows_parent_ami

  # DISCO C: da IMAGEM = 60 GB, que e o C: de todas as 7 VMs do pedido.
  #
  # O disco E: (aplicacao, 50-150 GB conforme a VM) NAO entra aqui: e da
  # INSTANCIA, um ebs_block_device separado por maquina. Imagem define so o C:.
  root_volume_size = var.windows_root_volume_size

  # ROOT DEVICE DO WINDOWS e /dev/sda1, NAO /dev/xvda das AMIs Linux desta
  # conta. Errar aqui faz a receita nao casar com a AMI-pai e a build falha no
  # mapeamento de bloco. Vem de var.windows_root_device_name.
  root_device_name = var.windows_root_device_name

  # SO O COMPONENTE PROPRIO. O update de SO nao e um componente gerenciado da
  # AWS aqui - a acao WindowsUpdate esta DENTRO do windows-base.yml. E nao ha
  # cleanup: o Sysprep do servico faz isso (ver o cabecalho).
  component_arns = [
    module.component_windows_base.arn,
  ]
}

# ---------------------------------------------------------------------------
# Distribuicao
# ---------------------------------------------------------------------------

module "windows_distribution" {
  source = "./modules/distribution"

  name           = local.windows_name
  description    = "Distribuicao da imagem base Windows Server 2025"
  region         = var.region
  recipe_version = module.windows_recipe.version
  parent_image   = module.windows_recipe.parent_image
  common_tags    = var.common_tags

  # ami_tags e o UNICO lugar que tagueia a AMI e o snapshot - o default_tags
  # nao alcanca, porque quem os cria e o servico. Ver a nota em base_distribution.
  extra_ami_tags = {
    Name                               = local.windows_name
    "acme:cost-allocation:Application" = "windows-2025"
    "acme:cost-allocation:Project"     = "legacy-erp"
    Platform                           = "windows"
  }
}

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

module "windows_pipeline" {
  source = "./modules/pipeline"

  name        = local.windows_name
  description = "Pipeline da imagem base Windows Server 2025 (legacy ERP / site SITE-A)"

  recipe_arn = module.windows_recipe.arn

  # A infrastructure configuration WINDOWS, criada acima - NAO a compartilhada
  # x86, que usa t3a.small e travaria o boot do Windows Server 2025.
  infrastructure_arn = aws_imagebuilder_infrastructure_configuration.build_windows.arn
  distribution_arn   = module.windows_distribution.arn

  # TESTE DE BOOT com timeout maior. Windows Update + Sysprep + primeiro boot
  # passa de 10 min; o default de 60 do pipeline arrisca cortar antes. 90 min.
  image_tests_enabled = true
  image_tests_timeout = 90

  extra_tags = {
    "acme:cost-allocation:Application" = "windows-2025"
    "acme:cost-allocation:Project"     = "legacy-erp"
  }

  # Disparo manual, igual as Ubuntu. Sem schedule.
  schedule = null
}

output "windows_pipeline_arn" {
  description = "ARN do pipeline da base Windows - usar no start-image-pipeline-execution"
  value       = module.windows_pipeline.arn
}
