# ---------------------------------------------------------------------------
# images/terraform.tfvars
#
# Os VALORES das variaveis declaradas em variables.tf.
# Este arquivo esta no .gitignore e NAO vai para o repositorio.
# ---------------------------------------------------------------------------

# DelegatedAdministrator: necessario porque esta configuracao cria IAM.
aws_profile = "acme-swe-prod-admin"

region = "us-west-2"

# Padrao da empresa: Ubuntu 26.04 LTS (resolute), suporte ate 2031.
# USAR SOMENTE LTS - as intermediarias tem 9 meses de suporte.
ubuntu_version = "26.04"

# Padrao da empresa: x86_64. Para Graviton seria "arm64", e o
# build_instance_type teria de virar um t4g.
architecture        = "amd64"
build_instance_type = "t3a.small"

vpc_id = "vpc-0a1b2c3d4e5f60001"

# acme-swe-prod-private-d (10.20.1.0/24, us-west-2d)
build_subnet_id = "subnet-0a1b2c3d4e5f70001"

permissions_boundary_arn = "arn:aws:iam::111122223333:policy/DelegatedAdminBoundary"

root_volume_size = 20

# AMIs-pai das linhagens base, FIXAS de proposito.
#
# Estes sao os valores que as receitas usam HOJE - nao os que a Canonical
# publica agora. O parametro publico do SSM aponta para "a atual" e muda
# sozinho (aconteceu em 16/10 as 03:20); como parent_image e ForceNew numa
# receita, valor dinamico fazia o Terraform querer SUBSTITUIR as receitas a
# cada republicacao - e a substituicao falharia, porque ha imagens
# referenciando.
#
# PARA ATUALIZAR: rode "terraform output" e compare "em_uso" com "disponivel".
# Trocar aqui SUBSTITUI a receita, entao suba o recipe_version junto em
# images.tf e apague antes as imagens que travem a remocao.
# AMIs-pai da Canonical, FIXAS de proposito.
#
# ATUALIZADAS EM 19/10/2026, no ciclo de rebuild. Antes:
#   amd64  ami-0a1b2c3d4e5fb0009   (em uso desde 14/10)
#   arm64  ami-0a1b2c3d4e5fb0010   (em uso desde 15/10)
#
# A Canonical republicou em 16/10 as 03:20. Trocar aqui SUBSTITUI a receita,
# porque parent_image e ForceNew - e por isso a troca foi feita junto com a
# subida do mb-timezone, pagando o custo da substituicao uma vez.
#
# POR QUE NAO VEM DO DATA SOURCE DO SSM: o parametro publico aponta para "a
# atual" e muda sozinho a cada republicacao. Com valor dinamico, o Terraform
# passaria a querer substituir as receitas sem ninguem ter mudado nada - e a
# substituicao falharia por ResourceDependencyException. O data source segue
# existindo, mas apenas como output informativo: comparar *_em_uso com
# *_disponivel em "terraform output".
base_parent_ami_amd64 = "ami-0a1b2c3d4e5fb0001"
base_parent_ami_arm64 = "ami-0a1b2c3d4e5fb0002"

# AMI da nossa imagem base, usada como imagem-pai do host de container.
# Construida em 14/10/2026, receita 1.0.2, aprovada no simple-boot-test-linux.
#
# FIXO DE PROPOSITO. Nao acompanha builds novas da base sozinho: atualizar
# aqui substitui a receita do host de container e exige subir o
# recipe_version dela em images.tf.
# AMIs-pai das linhagens de HOST DE CONTAINER - as nossas proprias bases.
#
# ATUALIZADAS EM 19/10, ciclo da fase 2:
#   base_ami_id        ami-0a1b2c3d4e5fb0008 -> ami-0a1b2c3d4e5fb0003  (x86 1.0.3)
#   base_arm64_ami_id  (nova)                -> ami-0a1b2c3d4e5fb0004  (arm 1.0.1)
#
# As duas trazem a correcao da fonte de tempo e a AMI-pai republicada em 16/10.
#
# NAO DA PARA EMPILHAR ENTRE ARQUITETURAS: cada host de container parte da base
# da PROPRIA arquitetura. Imagem x86 nao sobe em t4g.
#
# Trocar qualquer um destes SUBSTITUI a receita correspondente, porque
# parent_image e ForceNew - e obriga a subir o recipe_version junto.
base_ami_id       = "ami-0a1b2c3d4e5fb0003"
base_arm64_ami_id = "ami-0a1b2c3d4e5fb0004"

# Tags da norma (ticketing-system standard), aplicadas via default_tags a todos os recursos.
# Chave com dois-pontos PRECISA estar entre aspas em HCL.
common_tags = {
  ManagedBy = "terraform"

  "acme:cost-allocation:Project"     = "best-practices"
  "acme:cost-allocation:Application" = "golden-image"
  "acme:cost-allocation:Department"  = "swe"
  "acme:cost-allocation:CostCenter"  = "h370infra"
  "mb:automation:Environment"        = "prod"
  "mb:data:DataClassification"       = "interno"

  Owner      = "platform-team@acme.example"
  ChargeType = "dedicated"
}

# ---------------------------------------------------------------------------
# Linhagem WINDOWS (legacy ERP / site SITE-A) - 23/10
# ---------------------------------------------------------------------------

# Windows Server 2025 English Full Base, da AWS. Lida em 23/10:
#   Windows_Server-2025-English-Full-Base-2026.10.14
# O IDIOMA INGLES vem daqui, nao de passo do componente. FIXA de proposito,
# como as AMIs-pai Ubuntu: parent_image e ForceNew.
windows_parent_ami = "ami-0a1b2c3d4e5fb0005"

# C: de 60 GB - o C: de todas as 7 VMs do pedido. E o piso do disco da
# instancia. O E: (aplicacao) e por VM, no diretorio instances/.
windows_root_volume_size = 60

# /dev/sda1 nas AMIs Windows da AWS, nao /dev/xvda das Linux desta conta.
windows_root_device_name = "/dev/sda1"

# Instancia TEMPORARIA de build - vive ~1h e morre. m5.large porque Windows
# Server 2025 nao sobe em t3a.small. NAO e o tipo das 7 VMs finais
# (m6i.2xlarge), que esta travado atras do orcamento.
windows_build_instance_type = "m5.large"
