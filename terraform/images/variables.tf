# ---------------------------------------------------------------------------
# images/variables.tf
#
# Declaracao das variaveis: nome, tipo e descricao. Os VALORES ficam em
# terraform.tfvars, que nao vai para o git.
#
# Variavel sem "default" e obrigatoria: o Terraform pergunta no terminal se
# voce nao fornecer. Variavel com default e opcional.
# ---------------------------------------------------------------------------

variable "aws_profile" {
  description = "Perfil do AWS CLI (SSO). Precisa ser o DelegatedAdministrator por causa do IAM."
  type        = string
}

variable "region" {
  description = "Regiao onde a imagem e construida e distribuida"
  type        = string
  default     = "us-west-2"
}

variable "ubuntu_version" {
  description = <<-EOT
    Versao LTS do Ubuntu usada como imagem-pai (ex.: "26.04").

    USAR SOMENTE LTS. As intermediarias (24.10, 25.04, 25.10) tem 9 meses de
    suporte e nao servem para servidor.

    26.04 LTS (resolute) tem suporte padrao ate 2031; a 24.04 (noble), ate
    2029.

    RISCO CONHECIDO ao usar o LTS mais recente: repositorios de TERCEIROS
    costumam atrasar meses para publicar pacote para o codinome novo. Afeta o
    A42 - o componente gerenciado docker-ce-ubuntu depende de a Docker ter
    canal para "resolute". Se faltar, a build do host de container falha.
  EOT
  type        = string
  default     = "26.04"
}

variable "architecture" {
  description = <<-EOT
    Arquitetura da imagem: "amd64" (x86_64, instancias t3a) ou "arm64"
    (Graviton, instancias t4g).

    Padrao definido para a empresa: amd64.

    A arquitetura e ASSADA NA AMI - imagem amd64 nao roda em t4g e imagem
    arm64 nao roda em t3a. Trocar exige reconstruir a imagem e tambem trocar
    o tipo da instancia de build.
  EOT
  type        = string
  default     = "amd64"

  validation {
    condition     = contains(["amd64", "arm64"], var.architecture)
    error_message = "architecture deve ser amd64 ou arm64."
  }
}

variable "build_subnet_id" {
  description = "Subnet da instancia temporaria de build. Precisa de saida para a internet (NAT)."
  type        = string
}

variable "vpc_id" {
  description = "VPC onde o security group da instancia de build e criado"
  type        = string
}

variable "build_instance_type" {
  description = "Tipo da instancia temporaria de build. Precisa casar com a architecture."
  type        = string
  default     = "t3a.small"
}

variable "build_instance_type_arm64" {
  description = <<-EOT
    Tipo da instancia de build das imagens ARM64.

    PRECISA ser uma familia Graviton (t4g, m6g, c7g). A instancia de build
    executa a imagem-pai, e a arquitetura e assada na AMI - t3a nao consegue
    construir imagem arm64.
  EOT
  type        = string
  default     = "t4g.small"
}

variable "permissions_boundary_arn" {
  description = "ARN da permissions boundary obrigatoria para papeis criados por delegacao"
  type        = string
}

variable "root_volume_size" {
  description = "Tamanho do disco raiz da imagem, em GB"
  type        = number
  default     = 20
}

variable "arm64_root_volume_size" {
  description = <<-EOT
    Tamanho do disco raiz da imagem ARM64, em GB.

    Separado do root_volume_size porque a linhagem ARM pediu 30 GB. O disco da
    IMAGEM e o piso do disco da instancia: nao da para lancar instancia com
    disco menor que o da AMI, so maior.
  EOT
  type        = number
  default     = 30
}

variable "base_parent_ami_amd64" {
  description = <<-EOT
    AMI-pai da linhagem base amd64.

    FIXA DE PROPOSITO, e isto NAO e redundancia com o data source do SSM.

    O parametro publico da Canonical aponta para "a ATUAL", e muda sozinho
    quando ela republica - em 16/10/2026 isso aconteceu as 03:20. Como
    parent_image e ForceNew numa receita do Image Builder, um valor dinamico
    faz o Terraform querer SUBSTITUIR a receita a cada republicacao, sem
    ninguem ter mudado nada.

    E a substituicao FALHARIA: receita referenciada por imagem ja construida
    nao pode ser removida (ResourceDependencyException). O apply abortaria no
    meio.

    E o mesmo motivo pelo qual o ami_id das instancias e fixo - ver o
    comentario da variavel no modulo ec2-instance.

    ATUALIZAR E ATO DELIBERADO: trocar este valor substitui a receita, entao
    suba o recipe_version junto. Para descobrir qual e a atual, use o output
    parent_ami_ubuntu_disponivel.
  EOT
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.base_parent_ami_amd64))
    error_message = "Formato esperado: ami-0123456789abcdef0."
  }
}

variable "base_parent_ami_arm64" {
  description = <<-EOT
    AMI-pai da linhagem base arm64 (Graviton).

    Fixa pelo mesmo motivo do amd64 - ver acima. Precisa ser uma AMI arm64;
    imagem amd64 nao roda em t4g e vice-versa, porque a arquitetura e assada
    na AMI.
  EOT
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.base_parent_ami_arm64))
    error_message = "Formato esperado: ami-0123456789abcdef0."
  }
}

variable "base_arm64_ami_id" {
  description = <<-EOT
    AMI da NOSSA imagem base ARM64, usada como imagem-pai do host de container
    Graviton.

    MESMA LOGICA do base_ami_id, com a diferenca que importa: NAO DA PARA
    EMPILHAR ENTRE ARQUITETURAS. A arquitetura e assada na AMI, entao o host
    de container arm64 tem de partir da base arm64 - usar a base x86 como pai
    produziria imagem que nao sobe em t4g.

    POR QUE ESTA LINHAGEM EXISTE, decidido em 19/10: a operationalflow e t4g e
    teve Docker instalado A MAO depois do lancamento, porque nao havia imagem
    de host de container ARM. A consequencia pratica e que ela roda sem o
    daemon.json do componente - sem rotacao de log, num disco de 30 GB, o que
    e o modo de falha mais provavel daquela maquina.

    FIXO DE PROPOSITO, pelo mesmo motivo do base_ami_id.
  EOT
  type        = string
}

variable "base_ami_id" {
  description = <<-EOT
    AMI da NOSSA imagem base, usada como imagem-pai do host de container.

    Empilhar em vez de repetir componentes: a imagem de Docker e
    garantidamente a base mais Docker, nao "as duas construidas com os mesmos
    componentes em datas diferentes".

    FIXO DE PROPOSITO, mesmo motivo do ami_id das instancias. Um
    data "aws_ami" com most_recent = true parece conveniente e e perigoso:
    uma build nova da base mudaria o valor, e o proximo apply - mesmo um feito
    para outra coisa - substituiria a receita do host de container sem
    ninguem pedir.

    Trocar e ato deliberado: muda-se este valor sabendo que a receita sera
    substituida e que o recipe_version da linhagem do Docker precisa subir.

    Para descobrir a AMI mais recente da base:
      aws ec2 describe-images --owners self \
        --filters "Name=tag:ImageRole,Values=" "Name=name,Values=mb-base-ubuntu-*" \
        --query "sort_by(Images,&CreationDate)[-1].ImageId" --output text
  EOT
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.base_ami_id))
    error_message = "Formato esperado: ami-0123456789abcdef0."
  }
}

variable "common_tags" {
  description = "Tags da norma, aplicadas a todos os recursos via default_tags do provider"
  type        = map(string)
}

# ---------------------------------------------------------------------------
# Linhagem WINDOWS (legacy ERP / site SITE-A) - 23/10
# ---------------------------------------------------------------------------

variable "windows_parent_ami" {
  description = <<-EOT
    AMI-pai da base Windows Server 2025 ENGLISH, da AWS.

    FIXA DE PROPOSITO, mesma disciplina das AMIs Ubuntu: parent_image e
    ForceNew, entao valor que rastreia "a mais recente" faria o Terraform
    querer substituir a receita a cada republicacao da AWS - e a substituicao
    falha se houver imagem referenciando.

    O IDIOMA INGLES VEM DAQUI, nao de um passo do componente. Tem de ser uma
    AMI Windows_Server-2025-English-Full-Base. Em 23/10 a atual era
    ami-0a1b2c3d4e5fb0005 (Windows_Server-2025-English-Full-Base-2026.10.14).

    Para descobrir a atual:
      aws ec2 describe-images --owners amazon `
        --filters "Name=name,Values=Windows_Server-2025-English-Full-Base-*" `
        --query "reverse(sort_by(Images,&CreationDate))[0].{AMI:ImageId,Nome:Name}" `
        --output json --profile acme-swe-prod --region us-west-2

    ATUALIZAR E ATO DELIBERADO: trocar este valor substitui a receita, entao
    suba o recipe_version junto.
  EOT
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.windows_parent_ami))
    error_message = "Formato esperado: ami-0123456789abcdef0."
  }
}

variable "windows_root_volume_size" {
  description = <<-EOT
    Tamanho do disco C: da imagem Windows, em GB.

    60 GB, que e o C: de todas as 7 VMs do pedido da legacy ERP. O disco da IMAGEM e
    o PISO do disco da instancia - nao da para lancar com C: menor que o da
    AMI, so maior.

    O disco E: (aplicacao, 50-150 GB conforme a VM) NAO entra aqui: e da
    INSTANCIA, ebs_block_device separado por maquina.
  EOT
  type        = number
  default     = 60
}

variable "windows_root_device_name" {
  description = <<-EOT
    Nome do dispositivo raiz da AMI Windows.

    E /dev/sda1 nas AMIs Windows da AWS, DIFERENTE do /dev/xvda das AMIs Linux
    desta conta. Errar faz a receita nao casar com a AMI-pai e a build falha
    no mapeamento de bloco.
  EOT
  type        = string
  default     = "/dev/sda1"
}

variable "windows_build_instance_type" {
  description = <<-EOT
    Tipo da instancia TEMPORARIA de build da imagem Windows.

    NAO pode ser t3a.small como a build Linux: Windows Server 2025 nao sobe
    de pe com pouca RAM, e a build trava no primeiro boot sem erro claro.
    m5.large (2 vCPU, 8 GB) e o minimo confortavel para build. x86
    obrigatorio - nao existe Windows Server em Graviton aqui.

    ISTO E A INSTANCIA DE BUILD, que vive ~1h e morre. NAO e o tipo das 7 VMs
    finais (m6i.2xlarge), que e decisao do diretorio instances/ e esta travada
    atras da definicao de orcamento - ver a conversa de 23/10.
  EOT
  type        = string
  default     = "m5.large"
}
