# Golden images — EC2 Image Builder

Pipeline que produz a **imagem base padronizada** da empresa, na conta
`acme-swe-prod` (111122223333), us-west-2.

Cartões **A41** (v1 mínima, feita) e **A42** (padrão da empresa, em discussão)
do plano de ação.

---

## O que é uma golden image

Uma AMI própria, construída a partir de uma AMI oficial, com as
customizações da empresa já aplicadas. Instância nova sobe pronta.

Se você pensa em Docker, a **imagem-pai** é o `FROM` e os **componentes** são
os `RUN`.

O que acontece numa build:

1. o Image Builder sobe uma instância EC2 **temporária** a partir da imagem-pai
2. aplica os componentes **na ordem da receita**, via SSM
3. roda a fase de teste numa instância lançada da AMI já construída
4. desliga, tira a AMI, **destrói as instâncias temporárias**

A instância de build é destruída **sempre** — em sucesso faz parte do ciclo, em
falha pelo `terminate_instance_on_failure = true`. O que persiste é a AMI e o
snapshot EBS dela.

---

## Estado atual

**QUATRO linhagens, as quatro construídas** — base e host de container, em x86 e arm64.

**QUATRO linhagens Ubuntu, mais a WINDOWS desde 23/10** — base e host de container em x86 e
arm64, e a base Windows Server 2025 para a legacy ERP.

| Linhagem | Receita | AMI atual | Disco | `Application` |
|---|---|---|---|---|
| `mb-base-ubuntu-2604` | 1.0.3 | `ami-0a1b2c3d4e5fb0003` | 20 GB | `ubuntu-2604-x86` |
| `mb-base-ubuntu-2604-arm64` | 1.0.1 | `ami-0a1b2c3d4e5fb0004` | 30 GB | `ubuntu-2604-arm64` |
| `mb-docker-host-ubuntu-2604` | 1.0.3 | `ami-0a1b2c3d4e5fb0011` | 20 GB | `docker-ubuntu-2604-x86` |
| `mb-docker-host-ubuntu-2604-arm64` | 1.0.0 | `ami-0a1b2c3d4e5fb0006` | 30 GB | `docker-ubuntu-2604-arm64` |
| `acme-base-windows-2025` | 1.0.0 | `ami-0a1b2c3d4e5fb0007` | 60 GB | `windows-2025` |

**As quatro Ubuntu** trazem a fonte de tempo da AWS (`mb-timezone` 1.0.1) e as AMIs-pai
republicadas pela Canonical em 16/10 — `ami-0a1b2c3d4e5fb0001` (amd64) e
`ami-0a1b2c3d4e5fb0002` (arm64). As duas filhas herdam fuso e relógio da base, por empilhamento.

**A Windows** (23/10) e outro mundo: codigo em `windows.tf` e `components/windows-base.yml`, nao
empilha, componente em PowerShell, Sysprep automatico (sem cleanup proprio), AMI-pai inglesa da
AWS (`ami-0a1b2c3d4e5fb0005`). O idioma ingles vem da AMI-pai. Serve as 7 VMs App do site SITE-A
(diretorio `instances/`, arquivos `windows-*.tf`). Validada: build AVAILABLE e instancia real
subida. Ver a secao Windows no diario de execucao.

**NÃO DÁ PARA EMPILHAR ENTRE ARQUITETURAS.** Cada host de container parte da base da **própria**
arquitetura — a arquitetura é assada na AMI, e imagem x86 não sobe em `t4g`. É por isso que são
quatro linhagens e não três.

**Retenção: quatro políticas `ENABLED`, `COUNT 2`** (baixado de 3 em 19/10, para limitar o teto de
~300 GB para ~200 GB preservando "a atual e a anterior"). Hoje existem duas versões anteriores
(`ami-0a1b2c3d4e5fb0008` e `ami-0a1b2c3d4e5fb0012`), que a retenção apara no próximo repique.

> **PASSO MANUAL OBRIGATÓRIO depois de cada build:** `tag-resource` no recurso *image* — ver
> "Depois de CADA build", abaixo. Enquanto o **A44** não existir, esquecer isso faz a imagem
> nascer **fora** da política de retenção, **em silêncio**.

Os quatro pipelines estão `ENABLED` **sem agendamento**. Build é disparo manual.

> **A retenção ainda NÃO foi exercitada.** `list-lifecycle-executions` retorna vazio nas quatro:
> nenhuma linhagem **excede** 2 versões, então a política executa e não faz nada — o que é
> correto e **indistinguível de "não funcionou"**. O teste real é no próximo repique.

### Por que existe a linhagem ARM64 de host de container

A `operationalflow` é `t4g`, nasceu da base arm64 e teve **Docker instalado à mão**, porque não
havia imagem de host de container ARM. A consequência: ela roda **sem o `daemon.json`** do
componente — sem rotação de log (`max-size 10m`, `max-file 3`) num disco de 30 GB. Container que
loga muito enche o disco e derruba a máquina, com sintoma "o servidor parou" sem causa óbvia.

**A linhagem resolve para máquina NOVA.** A `operationalflow` ainda precisa de correção à mão, ou
de ser recriada a partir da `ami-0a1b2c3d4e5fb0006` — decisão da engenharia, porque tem integração
em produção em cima.

**Os componentes não precisaram de adaptação.** O `docker.yml` monta a linha do repositório com
`$(dpkg --print-architecture)`, então resolve `arm64` sozinho; os componentes próprios são scripts
shell. **E a build ter chegado a `AVAILABLE` prova mais que "construiu":** a fase `validate` do
`mb-docker` reprova a build se o `daemon.json` não tiver surtido efeito — lê
`Live Restore Enabled: true` no `docker info` e sobe um container para conferir o `max-size`. Em
ARM isso nunca havia sido exercitado.

### Componentes próprios

| Componente | Versão | O que faz | Usado por |
|---|---|---|---|
| `mb-timezone` | **1.0.1** | fuso `America/Sao_Paulo` **e fonte de tempo da AWS** | as 2 bases |
| `mb-cleanup` | 1.0.2 | porta SSH 65022, `apt clean`, `bash_history` | as 4 |
| `mb-docker` | 1.0.2 | Docker Engine, `daemon.json` com `log-opts` e `live-restore` | os 2 hosts |

**Qual componente recebe uma mudança decide quantas receitas o apply substitui.** Pôr a correção
do relógio no `mb-timezone` em vez do `mb-cleanup` poupou duas substituições de receita em 19/10.

### `mb-base-ubuntu-2604` — imagem base x86

| | |
|---|---|
| AMI atual | **`ami-0a1b2c3d4e5fb0003`** (19/10), receita 1.0.3 |
| AMI anterior | `ami-0a1b2c3d4e5fb0008` (14/10), receita 1.0.2 — rollback |
| Imagem-pai | `ami-0a1b2c3d4e5fb0001` — Ubuntu 26.04 LTS (resolute) amd64 |
| Pipeline | `mb-base-ubuntu-2604`, **disparo manual** |
| Retenção | `acme-swe-prod-retention-ubuntu-2604-x86`, `ENABLED`, `COUNT 2` |

Passou no teste de boot (`simple-boot-test-linux`), então não é só "criada": é
comprovadamente inicializável.

| Componente | Origem |
|---|---|
| `update-linux` | AWS |
| `mb-timezone` | próprio — `America/Sao_Paulo` |
| `amazon-cloudwatch-agent-linux` | AWS — instala, **não configura** |
| `mb-cleanup` | próprio — porta SSH 65022, `apt clean`, `bash_history` |

### `mb-docker-host-ubuntu-2604` — host de container

| | |
|---|---|
| AMI atual | **`ami-0a1b2c3d4e5fb0011`** (19/10/2026), receita 1.0.3 |
| AMI anterior | `ami-0a1b2c3d4e5fb0012` (15/10), receita 1.0.2 — rollback |
| Imagem-pai | **`ami-0a1b2c3d4e5fb0003`** — a nossa base x86 atual |
| Pipeline | `mb-docker-host-ubuntu-2604`, disparo manual |
| Retenção | `acme-swe-prod-retention-docker-ubuntu-2604-x86`, `ENABLED`, `COUNT 2` |

Em 19/10 a receita foi **repontada** da base 1.0.2 para a 1.0.3, o que trouxe por herança a
correção da fonte de tempo e a AMI-pai republicada. Foi isso que liberou a
`ami-0a1b2c3d4e5fb0008` de ser imagem-pai — ela segue existindo apenas como rollback da linhagem
base.

As duas falhas da versão 1.0.x valem mais que o tempo que custaram, e estão em "Armadilhas": a
`1.0.0/1` caiu por **ordem dos passos** (bug real) e a `1.0.1/1` pelo **próprio verificador** (um
`grep -A3` cortava antes do `max-size` e reprovou configuração correta). Das três falhas de build
desta linhagem, **uma foi bug e duas foram o código de validação** — daí a regra de preferir uma
checagem simples que prova o efeito.

### `mb-docker-host-ubuntu-2604-arm64` — host de container ARM64

| | |
|---|---|
| AMI atual | **`ami-0a1b2c3d4e5fb0006`** (19/10/2026), receita 1.0.0, **30 GB** |
| Imagem-pai | **`ami-0a1b2c3d4e5fb0004`** — a nossa base arm64 atual |
| Infrastructure | a ARM, com `t4g.small` |
| Retenção | `acme-swe-prod-retention-docker-ubuntu-2604-arm64`, `ENABLED`, `COUNT 2` |

**Linhagem criada em 19/10**, a quarta e última do padrão. Existe porque a `operationalflow` é
`t4g` e teve Docker instalado à mão, por falta de imagem ARM — e portanto roda **sem o
`daemon.json`** com rotação de log, num disco de 30 GB.

| Componente | Origem |
|---|---|
| `update-linux` | AWS — pega patches posteriores à build da base |
| `mb-docker` | próprio — mesmo componente da x86, sem adaptação |
| `mb-cleanup` | próprio — **de novo**, ver a nota sobre empilhar |

**O `mb-docker` não precisou de versão ARM.** Ele monta a linha do repositório com
`$(dpkg --print-architecture)`, então resolve `arm64` sozinho.

**E a build ter chegado a `AVAILABLE` prova a rotação de log em ARM**, porque a fase `validate`
reprova se o `daemon.json` não tiver surtido efeito.

### `mb-base-ubuntu-2604-arm64` — base ARM64 (Graviton)

| | |
|---|---|
| AMI atual | **`ami-0a1b2c3d4e5fb0004`** (19/10/2026), receita 1.0.1, **30 GB** |
| AMI anterior | `ami-0a1b2c3d4e5fb0013` (15/10) — **APAGADA em 19/10**, ver abaixo |
| Imagem-pai | `ami-0a1b2c3d4e5fb0002` — Canonical arm64. **Não** empilha sobre a base amd64 |
| Infrastructure | própria, com `t4g.small` — a instância de build também precisa ser Graviton |
| Retenção | `acme-swe-prod-retention-ubuntu-2604-arm64`, `ENABLED`, `COUNT 2` |

**Não é variação das outras: é linhagem própria**, porque a arquitetura é assada na AMI e
imagem amd64 não roda em `t4g`. Os componentes próprios são scripts shell e **funcionaram em
ARM sem adaptação** — confirmado na `operationalflow`, que nasceu da versão anterior desta
linhagem: `uname -m` deu `aarch64`, o fuso saiu `America/Sao_Paulo` e o SSH na 65022.

> **A `ami-0a1b2c3d4e5fb0013` foi apagada em 19/10**, mesmo sendo a AMI de onde a
> `operationalflow` nasceu. Isso foi possível porque o módulo `ec2-instance` ganhou
> `lifecycle { ignore_changes = [ami] }` — a variável passou a apontar para a imagem atual e a
> máquina existente seguiu na dela, sem o plan propor recriação. **Desregistrar AMI não afeta
> instância rodando nem parada:** a AMI só é consultada no lançamento, e o volume raiz é
> independente. Verificado na ocasião.

| Componente | Origem |
|---|---|
| `update-linux` | AWS |
| `mb-timezone` | próprio — **1.0.1**, com a fonte de tempo da AWS |
| `amazon-cloudwatch-agent-linux` | AWS — tem versão arm64 |
| `mb-cleanup` | próprio |

### Como a imagem de Docker se relaciona com a base

**É empilhada, não repetida.** A imagem-pai é a AMI da nossa base, então ela é
*garantidamente* a base mais Docker — não "as duas construídas com os mesmos
componentes em datas diferentes", que poderiam partir de níveis de patch
distintos. A frase que se quer poder dizer é "todo servidor é a imagem base;
alguns têm mais coisa".

**Não repete `mb-timezone` nem o agente do CloudWatch:** já vieram da base e
estão no disco. Esse é o ganho de empilhar.

**Mas repete o `mb-cleanup`, e isso é fácil de esquecer ao empilhar.** A
instância de build desta imagem nasce da AMI base e gera identidade **nova** no
primeiro boot — chaves de host SSH, `machine-id`, estado do cloud-init. Sem
rodar a limpeza outra vez, essa identidade iria para o snapshot.

**Docker não entra na imagem base, de propósito:** o daemon roda como root e
pertencer ao grupo `docker` equivale a ser root — dá para montar o filesystem
do host dentro de um container. Não deve estar em servidor que não precisa.

**Fora das imagens, de propósito:** runtime e dependências da aplicação (é
específico de aplicação, não baseline) e hardening agressivo (ver pendências).

### A cadeia

```
Ubuntu 26.04 da Canonical   (parâmetro público do SSM)
        │
        ▼
mb-base-ubuntu-2604         update-linux · timezone · cloudwatch-agent · cleanup
        │   ami-0a1b2c3d4e5fb0008
        ▼
mb-docker-host-ubuntu-2604  update-linux · docker · cleanup
```

**A cadeia tem um custo:** a imagem de Docker é tão antiga quanto a base de onde
partiu, e repicar a base **não** atualiza a filha sozinho. Atualizar é ato
deliberado — trocar `base_ami_id` no `tfvars` e subir o `recipe_version` da
linhagem do Docker.

---

## Pré-requisitos

Terraform >= 1.10. AWS CLI com SSO configurada — ver o README da raiz.

```powershell
$env:AWS_PROFILE = "acme-swe-prod"
```

O `terraform.tfvars` aponta `aws_profile = "acme-swe-prod-admin"` porque este
diretório **cria papel e instance profile**, e o `PowerUserAccess` não tem
`iam:GetRole` nem `iam:GetInstanceProfile`. Sem essas **leituras** o `apply`
falha *depois* de criar o recurso, deixando objeto órfão fora do estado.

O **backend**, por outro lado, usa a variável de ambiente `AWS_PROFILE`: ele só
precisa de S3, que o PowerUser tem. Configuração explícita no provider vence
variável de ambiente, então as duas metades convivem.

---

## Uso

```powershell
terraform init
terraform plan
terraform apply
```

Disparar uma build — **build é ação, não estado**, por isso não sai do
Terraform:

```powershell
aws imagebuilder start-image-pipeline-execution `
  --image-pipeline-arn "arn:aws:imagebuilder:us-west-2:111122223333:image-pipeline/mb-base-ubuntu-2604" `
  --profile acme-swe-prod
```

Acompanhar (`BUILDING` → `TESTING` → `AVAILABLE`, 15 a 25 min):

```powershell
aws imagebuilder list-image-pipeline-images `
  --image-pipeline-arn "arn:aws:imagebuilder:us-west-2:111122223333:image-pipeline/mb-base-ubuntu-2604" `
  --query "imageSummaryList[].{Versao:version,Estado:state.status,Motivo:state.reason}" `
  --output table --profile acme-swe-prod
```

### Depois de CADA build: taguear o recurso *image* — PASSO OBRIGATÓRIO

**Build não termina em `AVAILABLE`.** Termina depois disto, e esquecer não dá erro nenhum.

```powershell
aws imagebuilder tag-resource `
  --resource-arn "arn:aws:imagebuilder:us-west-2:111122223333:image/<nome>/<versao>/1" `
  --tags "acme:cost-allocation:Application=<linhagem>" `
  --profile acme-swe-prod
```

Linhagens válidas, que **têm de casar** com as chaves de `retention_lineages` em
`lifecycle.tf`:

```
ubuntu-2604-x86 . ubuntu-2604-arm64 . docker-ubuntu-2604-x86
```

**Por que isto existe:** a política de retenção seleciona por tag no **recurso *image*** do
Image Builder — não na AMI de saída —, e o recurso *image* **nasce sem tags**. Não propaga do
pipeline nem da receita. Imagem sem tag fica **fora** da política: ela roda, não encontra nada,
não apaga nada e **não reclama**.

**Conferir, e só este comando serve:**

```powershell
aws imagebuilder list-tags-for-resource `
  --resource-arn "arn:aws:imagebuilder:us-west-2:111122223333:image/<nome>/<versao>/1" `
  --profile acme-swe-prod
```

> **ARMADILHA: `describe-images` não serve para esta verificação.** Desde 16/10 o `ami_tags`
> está alinhado no código, então toda build nasce com a **AMI corretamente tagueada** e o
> **recurso *image* vazio**. Olhar a AMI dá **confiança falsa** — ela parece certa e a camada
> que a política avalia está fora. Antes, as duas estavam erradas juntas e qualquer uma
> revelava o problema; agora só a de cima revela.

**A Lambda do A44 automatiza isso** lendo as tags da receita e copiando para a imagem, de forma
genérica. Não foi implementada. **Enquanto for manual, não ligue o agendamento** dos pipelines:
build agendada ninguém acompanha, e o esquecimento é silencioso por desenho.

### Quando falhar

O `state.reason` diz qual componente falhou. Para achar o **passo**:

```powershell
aws imagebuilder list-workflow-step-executions `
  --workflow-execution-id "wf-xxxxxxxx" `
  --query "steps[?status=='FAILED'].outputs" --output text --profile acme-swe-prod
```

O log completo dos componentes está no CloudWatch Logs, grupo
`/aws/imagebuilder/mb-base-ubuntu-2604`, stream igual à versão (ex.: `1.0.2/1`).

Para investigar por dentro da máquina, trocar
`terminate_instance_on_failure` para `false` temporariamente.

---

## Acrescentar uma imagem nova

Uma imagem são **três blocos `module`** — receita, distribuição e pipeline — em
`images.tf`. Não se copia arquivo.

São três e não um porque receita, distribuição e pipeline têm **ciclos de vida
diferentes**: receita nova não exige distribuição nova, e uma distribuição pode
ser compartilhada.

```hcl
module "exemplo_recipe" {
  source = "./modules/recipe"

  name           = "mb-exemplo-ubuntu-2604"
  description    = "O que esta imagem contém"
  recipe_version = "1.0.0"

  # AMI pública da Canonical, ou a AMI da nossa base para EMPILHAR
  parent_image     = local.parent_ami_ubuntu
  root_volume_size = var.root_volume_size

  component_arns = [
    "arn:aws:imagebuilder:${var.region}:aws:component/update-linux/x.x.x",
    module.component_timezone.arn,
    module.component_cleanup.arn, # SEMPRE O ÚLTIMO
  ]
}

module "exemplo_distribution" {
  source = "./modules/distribution"

  name           = "mb-exemplo-ubuntu-2604"
  region         = var.region
  recipe_version = module.exemplo_recipe.version
  parent_image   = module.exemplo_recipe.parent_image
  common_tags    = var.common_tags
}

module "exemplo_pipeline" {
  source = "./modules/pipeline"

  name               = "mb-exemplo-ubuntu-2604"
  recipe_arn         = module.exemplo_recipe.arn
  infrastructure_arn = module.build_infrastructure.arn

  # OBRIGATÓRIO. Sem distribution a AMI e o snapshot nascem sem as tags da
  # norma, e a política de retenção — que seleciona por tag — não os encontra.
  distribution_arn = module.exemplo_distribution.arn

  schedule = null # disparo manual
}
```

Para **empilhar** sobre a base, troque só o `parent_image` pela AMI dela — e
leia a nota sobre o `mb-cleanup` em "Estado atual": ele precisa rodar de novo.

O `x.x.x` nos ARNs de componentes gerenciados **não é placeholder**: é a
sintaxe do Image Builder para "a versão mais recente".

---

## Disparar a build do host de container

```powershell
terraform output -raw docker_host_pipeline_arn
```

```powershell
aws imagebuilder start-image-pipeline-execution `
  --image-pipeline-arn "arn:aws:imagebuilder:us-west-2:111122223333:image-pipeline/mb-docker-host-ubuntu-2604" `
  --profile acme-swe-prod
```

**O que esperar de diferente da build da base.** O componente `mb-docker` tem
fase `validate` que **reprova a build** se o daemon não tiver lido o
`daemon.json` — ela confere `Live Restore Enabled: true` no `docker info` e
sobe um container para verificar que herdou o `max-size`. Se falhar ali, a
mensagem no log é explícita (`ERRO: o daemon.json nao surtiu efeito`) e a AMI
não chega a existir. É intencional: imagem errada não deve ficar disponível
para ninguém lançar.

**Risco conhecido, registrado no A24:** repositórios de terceiros atrasam para
publicar pacote para codinome de LTS novo. O Ubuntu 26.04 é `resolute`. O
componente **detecta** se a Docker tem canal para ele e, se não tiver, cai em
`noble` (24.04 LTS) — o codinome efetivo fica no log da build, em
`AddDockerRepository`. Se a build falhar na instalação, é o primeiro lugar a
olhar.

---

## Armadilhas

Todas descobertas na prática, cada uma custou uma build ou um `apply`.

### CRLF substitui os componentes — incidente de 16/10

**O pior desta lista, porque o `git status` mostra a árvore limpa.**

Depois do `git init` e do rebase do primeiro push, o `plan` passou de `No changes` para:

```
Plan: 9 to add, 5 to change, 6 to destroy
```

Querendo substituir **as três receitas e os três componentes**.

**Causa:** o rebase reescreveu a árvore de trabalho e o `core.autocrlf = true` — padrão do Git
no Windows — converteu `components/*.yml` de LF para **CRLF**. Este módulo lê esses arquivos com
`file()` e joga o conteúdo no atributo `data` do componente. Em componente **todo argumento é
ForceNew**, então bytes diferentes viram substituição — e em cascata, porque componente
substituído muda o ARN e o ARN faz parte da receita.

**Por que não dá para confiar no `git status` aqui:** o git **normaliza** terminações ao
comparar, então ele não vê diferença nenhuma. O Terraform vê. Duas ferramentas lendo o mesmo
arquivo e discordando sobre o conteúdo.

**O que aplicar teria causado:** as três AMIs referenciam as receitas, e remover receita
referenciada devolve `ResourceDependencyException`. Com `create_before_destroy` a remoção vem por
último — o apply criaria componente e receita novos, falharia no destroy e deixaria estado
parcial com recurso `tainted`.

**Correção:** arquivos de volta para LF e **`.gitattributes` na raiz do repositório** com
`*.yml text eol=lf`, para não repetir em clone novo. Depois disso o plan voltou a
`3 to add, 2 to change, 0 to destroy`.

**Como conferir rápido se é isto**, quando um plan propuser substituir componente sem ninguém ter
mexido em YAML:

```powershell
# conta CRLF nos componentes - esperado ZERO
Get-ChildItem components\*.yml | ForEach-Object {
  $b = [IO.File]::ReadAllBytes($_.FullName)
  $crlf = 0
  for ($i=1; $i -lt $b.Length; $i++) { if ($b[$i] -eq 10 -and $b[$i-1] -eq 13) { $crlf++ } }
  "{0}: CRLF={1}" -f $_.Name, $crlf
}
```

**A regra geral:** arquivo cujo **conteúdo vira atributo de recurso** não pode depender da
configuração de checkout de quem clonou. A classe de risco é a dos arquivos lidos por `file()` ou
`templatefile()` — neste diretório, só `components/*.yml`.

#### A recaída de 19/10, e duas lições que custaram o diagnóstico de novo

A correção de 16/10 ficou **incompleta** e ninguém percebeu por três dias. O script de conversão
terminava o pipeline com `Select-Object -First 15`, para limitar a saída na tela — e no PowerShell
isso **interrompe o pipeline a montante**, não apenas a exibição. A conversão parou em 15
arquivos; **33 ainda estavam em CRLF** quando foi reconferido.

Passou porque os `components/*.yml` estavam entre os 15 primeiros: o `plan` deste diretório fechou
em `No changes` e deu a impressão de sucesso completo. O que seguia quebrado era
`instances/main.tf`, e lá o CRLF é **pior** — o `user_data` é um heredoc, então alterá-lo exige
**parar e iniciar a instância**. O plan propunha um stop/start em produção por causa de fim de
linha.

**`Select-Object -First N` não é `head`.** Para limitar só a exibição, guardar numa variável e
exibir depois, ou gravar com `Out-File` e ler o arquivo.

**E `terraform validate` não substitui `terraform plan` na busca de drift.** Validate olha sintaxe
e tipos, sem falar com a AWS nem ler o estado. Encerrar uma sessão com `validate` nos quatro
diretórios dá uma sensação de cobertura que ele não entrega.

**Descartado por teste:** suspeitei do `terraform fmt` reescrever com CRLF no Windows. Converti um
arquivo para LF, rodei `fmt`, e ele permaneceu LF. Não é o `fmt`.

### O SG de build tem zero ENIs e NÃO está órfão — incidente de 16/10

O `acme-swe-prod-images-build-sg`, criado por este código, foi **apagado pelo console** em 16/10 às
09:35. Sem ele **nenhuma build funciona**: é o security group da instância de build.

**A confusão que causou:** o SG aparece com **zero ENIs**, igual a um SG órfão. Mas a instância
de build é **efêmera** — existe só durante a build. Zero ENIs aqui significa "nenhuma build
rodando agora", não "ninguém usa".

No mesmo dia havia sido registrado que o `acme-swe-prod-app01-sg` ficara **genuinamente** órfão,
também com zero ENIs. Os dois casos são indistinguíveis na tela do console.

**Como distinguir:** olhar quem criou. O CloudTrail mostra
`APN/1.0 HashiCorp/1.0 Terraform/1.16.2` na criação deste, contra console no outro. Ou, mais
simples, procurar o nome no `terraform state list` antes de apagar qualquer coisa.

**A recuperação é barata** — `3 to add, 2 to change, 0 to destroy`: recria o SG e as duas regras,
e atualiza as duas infrastructure configurations **in-place**, porque `security_group_ids` é
alterável. O ID novo não tem consequência: é referenciado por variável, não fixado.

### A AMI-pai não pode vir do parâmetro SSM — descoberto em 16/10

O parâmetro público da Canonical aponta para **"a atual"** e muda sozinho quando
ela republica. Em 16/10/2026 isso aconteceu às 03:20:

```
amd64   ami-0a1b2c3d4e5fb0009  →  ami-0a1b2c3d4e5fb0001
arm64   ami-0a1b2c3d4e5fb0010  →  ami-0a1b2c3d4e5fb0002
```

Como `parent_image` é **ForceNew** numa receita, usar o valor do data source
direto fazia o Terraform querer **substituir as receitas base** — sem ninguém
ter mudado nada. E a substituição **falharia**, porque receita referenciada por
imagem já construída não pode ser removida.

É uma mina que dispara sozinha a cada poucas semanas, e aparece como
`must be replaced` num `plan` que você rodou para outra coisa.

**Correção:** `base_parent_ami_amd64` e `base_parent_ami_arm64`, fixas no
`tfvars`. O data source continua, mas só como **output informativo**:

```powershell
terraform output   # compare *_em_uso com *_disponivel
```

É o mesmo motivo pelo qual o `ami_id` das instâncias e o `base_ami_id` do host
de container já eram fixos — a receita tem a mesma característica e o código
tratava diferente.

**Atualizar é ato deliberado:** trocar o valor substitui a receita, então suba
o `recipe_version` junto e apague antes as imagens que travem a remoção.

### Mudar tag de AMI no console não basta

`ami_tags` da distribution configuration é o **único** lugar que tagueia a AMI
e o snapshot — o `default_tags` do provider não alcança nenhum dos dois, porque
quem os cria é o serviço.

Mudar a tag no console corrige o recurso que já existe, mas **a próxima build
volta com o valor do código**. Aconteceu em 16/10: as três AMIs foram
retagueadas à mão e o `ami_tags` seguia com `golden-image`.

**E tag de AMI não alcança a política de retenção.** A seleção avalia tags no
**recurso *image*** do Image Builder, que é uma terceira camada e **nasce sem
tags**. Ver a nota ao fim de `lifecycle.tf`.

### As quatro camadas de tag, e quem lê o quê — consolidado em 16/10

É a confusão que mais custou tempo nesta linhagem, então vale a tabela:

| Camada | Vem de onde | A retenção lê? | Serve para |
|---|---|---|---|
| recurso *image* | **`tag-resource` manual** | **SIM — só esta** | a política de retenção |
| AMI de saída | `ami_tags` da distribution | não | inventário e Cost Explorer |
| snapshot | `ami_tags`, propagado | não | **rateio de custo** — é aqui que o custo está |
| pipeline | `tags` no módulo (`extra_tags`) | não | inventário apenas |

A assimetria que importa: **taguear só a AMI não alcança a retenção; taguear só o recurso
*image* já basta para ela.**

**O snapshot recebe as tags do `ami_tags`** — verificado no `snap-0a1b2c3d4e5fc0001`, que veio
com as treze. A documentação anterior dizia que precisaria de EventBridge mais Lambda para
isso, e **estava errada**.

### Tag de pipeline: mutável, mas o Terraform desfaz — 16/10

Ao contrário de receita e componente, **o pipeline é mutável**: a API tem
`UpdateImagePipeline` e aceita `tag-resource`. Mudar tag nele é alteração in-place, sem replace
e sem cascata — o `plan` de 16/10 confirmou (`0 to add, 3 to change, 0 to destroy`, com
`14 unchanged attributes hidden`).

**Mas mudar à mão tem prazo de validade**, e o gatilho é diferente do da AMI:

| Camada | Quem desfaz a mudança manual |
|---|---|
| AMI | a **próxima build** (volta com o `ami_tags` do código) |
| pipeline | o **próximo apply**, inclusive um feito para outra coisa |

E **não serve para a retenção**: tag de pipeline não propaga para o recurso *image*. Nem para
rateio: pipeline é **definição, não recurso cobrado** — não aparece na fatura. Serve para
inventário.

Por isso a `Application` por linhagem do pipeline foi para o código, via `extra_tags` do módulo
`pipeline`, em vez de ser ajustada no console.

### `daemon.json` tem de ser escrito antes do `apt install` — build 1.0.0/1

**Configuração que só vale para recursos criados depois dela não se aplica ao
que o daemon já criou.**

O `apt install docker-ce` **já sobe o daemon**. Escrevendo o `daemon.json`
depois e reiniciando, o que o daemon criou na primeira subida permanece — foi
o que derrubou a build 1.0.0/1, quando o componente ainda fixava
`default-address-pools`: o `docker0` já existia em `172.17.0.0/16` e não era
recriado no `restart`.

Escrevendo antes, a primeira subida já lê a configuração e nem é preciso
reiniciar. O diretório `/etc/docker` é criado em `InstallPrereqs` para isso.

Vale hoje mesmo sem o pool customizado: é mais simples e elimina a classe de
erro inteira.

### O pool de endereços voltou ao padrão — decisão de 15/10

A versão 1.0.0 fixava `default-address-pools` em `10.100.0.0/16` e
`10.101.0.0/16`. **Foi revertido, e a justificativa original estava errada.**

**O que se dizia:** o pool padrão do Docker colide com a VPC de produção.

**Por que está errado:** o Docker aloca a partir de `172.17.0.0/16` e sobe —
`172.18`, `172.19`, até `172.31` — e depois passa para `192.168.0.0/20` em
diante. A produção é `172.16.0.0/16`, que **não está no caminho de alocação**.
Risco zero.

**As colisões que existem de fato, e por que não justificavam:**
`172.31.0.0/16` (em uso, ver `CIDRs.txt`) exige **15 redes** criadas antes; as
faixas `192.168.x` do escritório exigem mais de 15. Cada projeto
`docker-compose` cria uma rede — chegar a 15 simultâneas significa dezenas de
stacks no mesmo host, o que não é o caso aqui.

**E o mecanismo não é o que a intuição sugere.** O tráfego que sai do container
passa por **MASQUERADE** e chega ao destino com o IP do host, então o IP do
container nunca aparece na rede. O problema seria de **destino**: uma rota local
`172.x dev docker0` é mais específica que a rota da VPC e capturaria tráfego que
deveria sair pela `eth0`. Mas isso exige a sobreposição acontecer — e ela exige
as 15 redes.

**O que pesou para voltar ao padrão:** menos peça para manter, e divergir do
padrão tem custo próprio — quem for depurar roteamento espera `172.17` e
estranha qualquer outra coisa.

**Se um dia precisar voltar a fixar:** o motivo legítimo seria uma instância
precisar **alcançar** faixa `192.168.x` do escritório (hoje o fluxo é o
contrário: escritório → ALB → instância) ou peering novo com VPC em
`172.17`–`172.31`.

### A validação verifica o EFEITO, não a configuração

O passo `ValidateDaemonTookEffect` existe porque `cat daemon.json` prova apenas
que o arquivo está no disco. Foi essa distinção que pegou o bug da 1.0.0/1: o
arquivo estava correto e a configuração não estava valendo.

`Live Restore Enabled: true` no `docker info` só aparece se veio do
`daemon.json` — o padrão do Docker é `false`. Serve como prova de leitura. O
passo também sobe um container de verdade e confere que ele herdou
`max-size: 10m`, que é o campo que previne o disco de 20 GB encher.

### Mudar componente exige subir DUAS versões, e a build que falhou atrapalha

Subir o componente de 1.0.0 para 1.0.1 **muda o ARN dele**, e o ARN entra na
receita — então o `recipe_version` sobe junto. Esquecer faz o `apply` não mudar a
receita e a build continuar usando a versão antiga, **sem erro nenhum**.

E há um segundo efeito: componente e receita são imutáveis, então versão nova é
**replace**. Com `create_before_destroy = true` a ordem é criar o novo, apontar o
pipeline, remover o antigo — mas **a remoção falha se existir versão de imagem
que referencie o antigo, inclusive uma build que FALHOU**:

```
ResourceDependencyException
```

Apagar o registro da build falha antes de aplicar:

```powershell
aws imagebuilder delete-image `
  --image-build-version-arn "arn:aws:imagebuilder:us-west-2:111122223333:image/mb-docker-host-ubuntu-2604/1.0.0/1" `
  --profile acme-swe-prod
```

É seguro: a build falhou, não gerou AMI nem snapshot, e nada a referencia. A
ordem de remoção é sempre de dentro para fora — **imagem, receita, componente**.

### Chaves duplas colidem com a sintaxe do AWSTOE — descoberto em 15/10

**Não use `docker ... --format` num componente.** O AWSTOE usa chaves duplas
como sintaxe própria de parâmetro, e Go template do Docker usa a mesma coisa.
Com `--format '{{ range .IPAM.Config }}'`, o AWSTOE tenta resolver `.IPAM` como
parâmetro dele e **a criação do componente falha** — nem chega a rodar build:

```
InvalidParameterValueException: The value supplied for parameter 'data' is
not valid. Parameter validation failed for document index '0' phase
'validate' step 'ValidateAddressPools'.
Error: Parameter 'IPAM' not declared but referenced.
```

Contorno: extrair do JSON sem template. A linha do `docker network inspect` é
`"Subnet": "10.100.0.0/24",`, então os campos separados por aspas dão o valor
no quarto:

```bash
docker network inspect bridge | grep '"Subnet"' | head -1 | cut -d'"' -f4
```

Vale para qualquer comando com Go template — `docker inspect`, `docker ps
--format`, `kubectl -o go-template`.

### Validar o YAML localmente exige Linux

O erro acima teria sido pego antes do `apply`. A validação é a ferramenta
oficial, a mesma que o serviço usa:

```bash
curl -O https://awstoe-us-west-2.s3.us-west-2.amazonaws.com/latest/linux/amd64/awstoe
chmod +x awstoe
./awstoe validate --documents components/docker.yml
```

**O binário de Windows não serve** para componentes Linux: ele valida para a
plataforma do host e recusa `ExecuteBash` com
`Unsupported action ExecuteBash for os platform windows` — inclusive em
componentes que já construíram com sucesso, o que confunde.

No Windows, rodar por **WSL**. O que funcionou aqui: baixar o binário de Linux
pelo PowerShell (o Debian do WSL não tinha `curl`), copiar para dentro do WSL e
validar de lá. Os três componentes retornaram `validationStatus: success`.

### `include_resources` exige `containers` explícito — descoberto em 15/10

Na política de retenção, omitir `containers` faz o `apply` falhar com:

```
Error: Provider produced inconsistent result after apply
... produced an unexpected new value: .policy_detail: planned set element
... "containers":cty.UnknownVal(cty.Bool) ... does not correlate with any
element in actual.
This is a bug in the provider.
```

O provider planeja `containers` como **unknown**, a API devolve `false`, e como
`policy_detail` é um **set** o elemento planejado não correlaciona com o
retornado.

**O recurso É criado na AWS mesmo com o erro** — o apply aborta depois da
criação. Conferir com `list-lifecycle-policies` antes de supor que falhou, e
lembrar que o Terraform marca o recurso como **`tainted`**, o que faz o plan
seguinte querer substituí-lo. Como o recurso está correto, `terraform untaint`
resolve sem destruir nada.

Correção definitiva: declarar `containers = false` junto de `amis` e
`snapshots`.

### E `is_public = false` também — mesmo bug, outro campo

Depois do `untaint`, o plan ainda mostrava `1 to change`: o `policy_detail`
sendo removido e recriado, por causa de uma linha só:

```
- is_public = false -> null
```

A API devolve `is_public = false` dentro de `exclusion_rules.amis`. Sem declarar,
o elemento do **set** `policy_detail` difere do que está no estado, e o plan fica
com **diff perpétuo** — toda execução mostra a mesma alteração e `No changes`
nunca mais aparece. Aplicar não causa dano (é reescrita da definição, não toca em
AMI), mas o ruído passa a esconder mudanças reais.

**A regra geral, válida para qualquer bloco que o provider trate como set:**
declare explicitamente todo campo booleano que a API preenche por padrão. Se o
plan insiste numa alteração que você já aplicou, procure um `-> null` no diff —
é um campo que a API devolve e o código não declara.

No nosso caso `false` também é o valor correto por desenho: as AMIs nunca são
públicas (o A06 bloqueia acesso público na conta), então a regra "não apague AMI
pública" não teria efeito.

### `description` também é ForceNew — descoberto em 15/10

Em `aws_imagebuilder_component` e `aws_imagebuilder_image_recipe`, **todo**
argumento força substituição, inclusive a descrição. Componente e receita são
imutáveis no serviço.

Na refatoração para módulos eu acrescentei `description` aos componentes
`mb-timezone` e `mb-cleanup`, que haviam sido criados sem ela. O `plan` acusou:

```
# module.component_timezone.aws_imagebuilder_component.this must be replaced
+ description = "Define o fuso horario..." # forces replacement
~ component_arn = "...component/mb-timezone/1.0.0/1" -> (known after apply) # forces replacement
# module.base_recipe.aws_imagebuilder_image_recipe.this must be replaced
```

A cascata é o que importa: substituir o componente muda o **ARN** dele, o ARN
faz parte da receita, então a receita base seria substituída também — e isso
falharia com `ResourceDependencyException`, porque a `ami-0a1b2c3d4e5fb0008`
referencia essa receita.

**Por isso os componentes existentes e a linhagem base ficaram sem
`description`**, e há comentário no código dizendo que não é esquecimento. A
linhagem do Docker, sendo nova, tem descrição normalmente.

**Lição geral:** ao mover recurso imutável para dentro de módulo, o diff tem de
ser **zero**. Qualquer "melhoria" cosmética de passagem vira substituição.

### A refatoração usou blocos `moved`

O nome do recurso no código é a **chave dele no estado**. Mover um recurso para
dentro de um módulo muda o endereço:

```
aws_imagebuilder_component.timezone
  →  module.component_timezone.aws_imagebuilder_component.this
```

Sem um bloco `moved`, o Terraform lê isso como "o antigo saiu do código e um
novo apareceu" e planeja **destruir e criar**. Aqui isso seria grave, pelo
mesmo encadeamento de dependência acima.

Os 13 blocos estão em `moved.tf`, e **podem ser removidos** depois de o `apply`
que os consome ser bem-sucedido — não antes, porque se o `apply` precisar ser
repetido eles são necessários.

**Para o `moved` ser um move e não um replace, o nome do recurso na AWS tem de
continuar idêntico.** Nomes preservados: `mb-timezone` 1.0.0, `mb-cleanup`
1.0.2, `mb-base-ubuntu-2604` (receita, distribuição e pipeline),
`delegated-imagebuilder`, `acme-swe-prod-images-build-sg` e
`acme-swe-prod-images-build`.

### Versão é manual, e são duas

Mudar o YAML de um componente **não cria versão nova sozinho**. É preciso subir
o `version` do `aws_imagebuilder_component` **e** o `version_number` da
chamada do módulo — porque o ARN do componente inclui a versão dele, então
mudar o componente muda a receita, e receita é imóvel.

Esquecer faz o `apply` não mudar nada e parecer que atualizou.

### Receita e componente ficam presos por quem os referencia

Uma receita não pode ser apagada enquanto o **pipeline** apontar para ela, nem
enquanto existir versão de imagem que a referencie — **inclusive uma build que
falhou**. O erro é `ResourceDependencyException`.

Por isso receita e componentes têm `lifecycle { create_before_destroy = true }`.
Sem isso o Terraform destrói antes de criar e a remoção falha.

Se o erro aparecer mesmo assim, é uma **imagem** segurando a dependência:

```powershell
aws imagebuilder delete-image `
  --image-build-version-arn <arn da imagem> --profile acme-swe-prod
```

A ordem de remoção é de dentro para fora: imagem, receita, componente.

### O Image Builder já sanitiza a imagem

O passo `RunSanitizeScript`, que roda automaticamente antes do snapshot, apaga
as chaves de host SSH e os `authorized_keys`, zera `/etc/machine-id` e
`/var/lib/dbus/machine-id`, remove `/var/lib/cloud/*`, o journal, o
`random-seed` e logs, e faz `sync`.

Ou seja: limpar identidade **à mão é redundante aqui**. É obrigatório em AMI
feita manualmente (`create-image` de uma instância configurada), não no Image
Builder. Os passos `RemoveSshHostKeys`, `ResetMachineId` e `CleanCloudInit` do
componente `mb-cleanup` sobraram dessa confusão e podem sair numa próxima
revisão.

### Ubuntu 24.04+ usa ativação por socket no SSH

`ssh.socket` enabled, `ssh.service` disabled. Nesse modo o `Port` do
`sshd_config` é **ignorado** — quem decide é o `ListenStream` da unidade
systemd. Mexer só no `sshd_config` faz a build passar e o SSH continuar na 22,
**sem erro nenhum**.

O componente escreve nos dois lugares. No override, `ListenStream=` vazio antes
do valor novo não é descuido: é o idioma do systemd para limpar a lista
herdada, senão a unidade escuta nas duas portas.

### `sshd -t` falha na build

Sai com 255 e `Missing privilege separation directory: /run/sshd`. `/run` é
tmpfs e o diretório só existe quando o serviço sobe — e o serviço está
desabilitado por causa da ativação por socket. **Não é erro de configuração.**
Para validar, `mkdir -p /run/sshd` antes.

### `update-linux` reclama do agente SSM

`E: Unable to locate package amazon-ssm-agent`. **Inofensivo**: no Ubuntu o
agente é snap e já vem na AMI da Canonical. A build segue normalmente.

### O `default_tags` do provider não alcança tudo

Ele vale para o que o **Terraform** cria. Recursos criados pelo **serviço**
precisam de campo próprio:

| Recurso | Campo |
|---|---|
| instância de build e volume dela | `resource_tags` na infrastructure configuration |
| AMI **e snapshot** | `ami_tags` na distribution configuration |

As tags do `ami_tags` **propagam** para o snapshot EBS — verificado.

### O `Name` da instância de build é do serviço

Sai como `Build instance for mb-base-ubuntu-2604`. Não é a norma, é o Image
Builder. Sobrescrever seria pior: a infrastructure configuration é
compartilhada entre imagens, então um `Name` fixo ali seria idêntico para toda
build.

### Prefixo `delegated-` é obrigatório em IAM

A permissions boundary `DelegatedAdminBoundary` só permite criar papel,
instance profile e política dentro desse prefixo. E **todo papel novo precisa
carregar a própria boundary** (`permissions_boundary`), senão o `CreateRole` é
negado com um erro que não menciona a boundary.

### Se faltar a AMI-pai no parâmetro SSM

O caminho do parâmetro público da Canonical pode mudar. Contorno: trocar o
`data` por uma variável com o ID da AMI.

---

## Trocar a versão do Ubuntu

```hcl
ubuntu_version = "26.04"   # terraform.tfvars
```

O nome da imagem é derivado da versão (`mb-base-ubuntu-2604`), então trocar
gera uma **linhagem nova** — receita, distribuição e pipeline novos. É o
comportamento correto: versão de SO diferente não é atualização da mesma
imagem.

**Usar somente LTS.** As intermediárias (24.10, 25.04, 25.10) têm 9 meses de
suporte e não servem para servidor. A 26.04 tem suporte até 2031.

**Risco do LTS mais recente:** repositórios de **terceiros** costumam atrasar
meses para publicar pacote para o codinome novo.

## Trocar a arquitetura

```hcl
architecture        = "arm64"      # ou "amd64"
build_instance_type = "t4g.small"  # precisa acompanhar
```

A arquitetura é **assada na AMI**: imagem `amd64` não roda em `t4g` e `arm64`
não roda em `t3a`. Padrão da empresa: **amd64**.

---

## Pendências

### Resolvida — histórico que vale manter

**Política de retenção (manter 3 versões): FUNCIONANDO desde 16/10.** São três políticas, uma
por linhagem, `ENABLED` e selecionando.

O caminho foi este, e cada etapa custou um diagnóstico:

1. **14/10 — bloqueada por permissão.** A `DelegatedAdminBoundary` restringia `iam:PassRole` a
   `ec2`, `lambda` e `ecs-tasks`, e a política passa o papel para
   `imagebuilder.amazonaws.com`. O `lifecycle.tf` ficou comentado.
2. **15/10 — destravada.** O administrador publicou a `v2` da boundary, com `StringLike` e
   `"image*"`. **Não exigiu relogin** — mudança em documento de política é avaliada na
   requisição, não fica no token da sessão. **Ressalva registrada:** o curinga alargou a
   boundary mais que o necessário; a versão estreita (`StringEquals` com os quatro principais
   exatos) daria o mesmo resultado funcional.
3. **16/10 — uma política por linhagem**, com `for_each`, resolvendo a ambiguidade do `COUNT`.
   Com uma política só para as três, havia o cenário de a base x86 — que é **imagem-pai** do
   host de container — ser apagada por ser a mais antiga do conjunto, quebrando a receita filha.
4. **16/10 — os recursos *image* tagueados**, que é o que faltava para a seleção encontrar algo.

**O que continua pendente é a automação, não a política:** o `tag-resource` é manual. Ver
"Depois de CADA build", acima, e a nota ao fim de `lifecycle.tf`.

**Descartado, e por quê:** fazer a retenção com **Lambda agendada por EventBridge** em vez de
esperar a liberação da boundary. `lambda.amazonaws.com` estava na lista permitida, então era
viável — mas seria escrever e manter código para substituir um recurso gerenciado por causa de
uma linha de policy. A liberação veio em um dia.

### Ainda bloqueada por permissão

**Esteira do GitLab com OIDC.** A boundary não permite
`iam:CreateOpenIDConnectProvider`. O papel da esteira você cria (sendo
`delegated-*`); o provedor de identidade, não. Até lá, o `apply` roda da
máquina com o perfil SSO.

### A decidir (cartão A42)

**Imagem de host de container, com Docker — CONSTRUÍDA em 15/10/2026**,
`ami-0a1b2c3d4e5fb0012`, componente e receita em 1.0.2. Linhagem
`mb-docker-host-ubuntu-2604`, empilhada sobre a
base. O que está resolvido e por quê:

Docker **não entra na imagem base**: o daemon roda como root e pertencer ao
grupo `docker` equivale a ser root — monta o filesystem do host num container.
Não deve estar em servidor que não precisa. Receita separada, componente
`mb-cleanup` reutilizado.

**Componente próprio em vez do `docker-ce-ubuntu` gerenciado.** O gerenciado
(versão 1.0.1) instala, mas não configura `log-opts` nem `live-restore`, não
tem fase de validação própria, e não detecta o codinome do SO.

**O que o `daemon.json` traz, e por quê:** `log-opts` com `max-size: 10m` e
`max-file: 3` — previne container que loga muito encher o disco de 20 GB e
derrubar a máquina, com sintoma "o servidor parou" sem causa óbvia — e
`live-restore`, que mantém containers rodando quando o daemon reinicia.

**O pool de endereços ficou no padrão do Docker.** A tentativa de fixá-lo em
`10.100.0.0/16` e `10.101.0.0/16` foi revertida em 15/10 — ver "O pool de
endereços voltou ao padrão" em Armadilhas, que registra por que a justificativa
original estava errada.

**A fase `validate` não confia na configuração: ela confere o efeito.** Lê
`docker info` para provar que o `daemon.json` foi lido e sobe um container para
verificar que ele herdou o limite de log. A fase `test` repete na AMI final,
porque a configuração podia estar certa na build e não sobreviver ao snapshot.
É a diferença entre "configuramos" e "está valendo" — e foi ela que pegou um
bug real de ordem dos passos.

**Hardening ficou de fora desta imagem, deliberadamente.** O repositório da
equipe anuncia um componente de hardening com SSH na 65022 e
`unattended-upgrades`, mas o arquivo `hardening-component.yml` de lá é **cópia
byte a byte** do `docker-component.yml` — verificado por hash em 15/10
(`sha256` `3BC00136D82DD7AC`, 3.230 bytes nos dois, e o `name:` interno dos
dois é `InstallDocker`). O hardening anunciado não existe no código. A porta do
SSH já é tratada pelo nosso `mb-cleanup`, que escreve nos **dois** lugares
exigidos pelo Ubuntu 24.04+; `unattended-upgrades` entra quando for decidido
como item de baseline, não copiado às cegas.

**Imagem de Windows.** Receita separada, não variação: componentes diferentes,
disco mínimo maior (30 GB), build mais demorada e a imagem-pai é uma AMI
gerenciada da AWS com licença embutida, o que muda o custo das instâncias.

**Empilhar ou repetir componentes.** A própria golden image pode ser imagem-pai
de outra. Empilhando, o host de container é *garantidamente* a base mais
Docker e a build é mais rápida — em troca cria cadeia de dependência.
Repetindo, cada imagem é autônoma, mas duas builds em datas diferentes podem
partir de níveis de patch diferentes. Para padrão de empresa, empilhar é
preferível: a frase que se quer poder dizer é "todo servidor é a imagem base;
alguns têm mais coisa".

**Hardening.** Existe `stig-build-linux` (1.0.6) gerenciado — padrão do
Departamento de Defesa americano, **mais agressivo que o CIS**. Também há
`scap-compliance-checker-linux`. Não entra sem validação: aplicado às cegas
quebra coisas de forma difícil de diagnosticar, e não se descobre isso numa
imagem que vira padrão.

**Cadência de repique de patch.** Mensal é o usual, e define se o pipeline
passa a ter `schedule`. Depende de o item de retenção estar resolvido.

**Conta onde a imagem mora.** Imagem padrão da empresa na conta de um projeto é
dívida. O desenho correto é uma conta de serviços compartilhados distribuindo
as AMIs — e essa conta não existe, depende da estruturação de OU (A32).
**Construir aqui é provisório.** Distribuir entre contas exigirá **CMK**:
snapshot com a chave `aws/ebs` não é compartilhável.

**Varredura de CVE.** `inspector-test-linux` roda o Amazon Inspector na fase de
teste. Medir custo antes.

### Melhorias conhecidas

Simplificar o `mb-cleanup` para conter apenas a porta do SSH, o `apt clean` e a
remoção do `bash_history` — o resto duplica o sanitize do serviço. Vale fazer
junto com a próxima mudança real, não numa build só para isso.

~~Validar a porta 65022 em instância real.~~ **CONFIRMADO em 15/10/2026**, na
`acme-swe-nonprod-operationalflow` (arm64):

```
$ sudo ss -tlnp | grep ssh
LISTEN 0 4096 0.0.0.0:65022 0.0.0.0:* users:(("sshd",pid=747,fd=3),("systemd",pid=1,fd=63))
$ systemctl is-enabled ssh.socket
enabled
```

O `systemd` (pid=1) aparecendo ao lado do `sshd` é o que prova o mecanismo: a
ativação por socket está em uso **e** o override do `ListenStream` pegou. Era
exatamente o risco de o `sshd_config` sozinho fazer a build passar e o SSH
continuar na 22 sem erro nenhum.

---

## Estrutura

```
images/
├── README.md             este arquivo
├── provider.tf           versões e perfil (admin, por causa do IAM)
├── backend.tf            estado remoto
├── variables.tf          declaração das variáveis
├── terraform.tfvars      valores — NÃO vai para o git
├── main.tf               AMI-pai pública e os componentes próprios
├── infrastructure.tf     onde a build roda (IAM, SG, infra config)
├── images.tf             as linhagens: base e docker-host empilhada
├── moved.tf              refatoração — blocos `moved`, ver abaixo
├── outputs.tf            ARNs dos pipelines
├── lifecycle.tf          retenção — ATIVA, 3 políticas (uma por linhagem)
├── iam.tf.bak            conteúdo antigo do IAM, preservado (ver nota)
├── components/
│   ├── timezone.yml
│   ├── cleanup.yml
│   └── docker.yml
└── modules/
    ├── component/        um componente AWSTOE
    ├── infrastructure/   IAM + SG + infrastructure configuration
    ├── recipe/           imagem-pai + componentes + disco
    ├── distribution/     para onde a AMI vai e COMO É TAGUEADA
    ├── pipeline/         amarra os três
    └── image-pipeline/   OBSOLETO — substituído pelos cinco acima
```

**Sobre o `iam.tf.bak` e o `modules/image-pipeline/`:** este diretório ainda
**não está sob git**, então uma remoção não tem desfazer. Os dois ficaram no
disco de propósito. O Terraform lê apenas arquivos `.tf` e só inicializa
módulos referenciados, então nenhum dos dois tem efeito. **Podem ser apagados
depois que o apply da refatoração for bem-sucedido** — de preferência depois de
o repositório estar versionado.

### Cinco módulos, não um

A estrutura veio do repositório da equipe
([contributor/imagebuilder](https://github.com/contributor/imagebuilder)) e é
melhor que a anterior: o módulo `image-pipeline` embrulhava receita,
distribuição e pipeline num só lugar, e isso impedia empilhar imagem sem
duplicar código.

Receita, distribuição e pipeline têm **ciclos de vida diferentes**: receita
nova não exige distribuição nova, e uma distribuição pode ser compartilhada.
Por isso são três chamadas por imagem em vez de um módulo que embrulha tudo.

**Quatro adaptações em relação ao repositório de origem**, todas obrigatórias
aqui:

| O que | Por quê |
|---|---|
| `permissions_boundary` no papel | sem ela o `CreateRole` é **negado**, com um `AccessDenied` que não menciona a boundary |
| nomes com prefixo `delegated-` | a `DelegatedAdminBoundary` só permite criar IAM dentro dele. O módulo **valida no plan** |
| `subnet_id` e `security_group_ids` obrigatórios | o original os omite e cai na VPC default, que **não existe mais em nenhuma região desta conta** |
| módulo `distribution` | **não existe no original**, e sem ele a AMI e o snapshot nascem sem `ami_tags` — ver abaixo |

**Por que o módulo de distribuição é indispensável.** `ami_tags` é o único
lugar que tagueia a AMI **e o snapshot**; o `default_tags` do provider não
alcança nenhum dos dois, porque quem os cria é o serviço. Sem distribution
configuration a política de retenção também para de funcionar, porque ela
seleciona **por tag** — e o modo de falha é silencioso: a política roda, não
encontra imagem, não apaga nada e não reclama.

---

## Validar componentes localmente, antes do apply

Uma build custa 15 a 25 minutos para descobrir um erro de sintaxe. As duas
builds que falharam em 14/10 teriam sido evitadas aqui.

```bash
curl -O https://awstoe-us-west-2.s3.us-west-2.amazonaws.com/latest/linux/amd64/awstoe
chmod +x awstoe

./awstoe validate --documents components/docker.yml

# numa máquina descartável, nunca na sua:
sudo ./awstoe run --documents components/docker.yml --phases build,validate --trace
```

---

