# Plataforma AWS em Terraform — fábrica de golden images, EC2 e rede entre contas

*[English version](README.md)*

Infraestrutura de uma conta AWS de produção, escrita em código: pipeline de
golden images com EC2 Image Builder, instâncias EC2 sem porta de entrada,
VPC peering entre contas e uma ferramenta própria de diagnóstico de VPC Flow
Logs.

Não é um laboratório. É uma conta que roda — com as decisões, e os erros, do
caminho registrados dentro do próprio código.

|  |  |
|---|---|
| **Configurações Terraform** | 4, com estado isolado por raio de destruição |
| **Módulos próprios** | 6 |
| **Linhagens de golden image** | 4 — base e host de container, em x86 e ARM/Graviton |
| **Componentes AWSTOE** | 3, escritos à mão em YAML |
| **Exposição de rede** | sem IP público, sem porta 22; entrada vazia por padrão, exceção sempre em `/32` |
| **Custo recorrente** | ~US$ 36/mês, com budget de US$ 150 |

---

## Em 30 segundos: o que este repositório mostra

**Imagens que se empilham, não que se repetem.** A imagem de host de container
usa a nossa própria AMI base como imagem-pai. Então ela *é* a base mais Docker,
no mesmo nível de patch — não duas imagens construídas em paralelo que podem
divergir. A frase que eu quero poder dizer: *todo servidor é a imagem base;
alguns têm mais coisa.*

**Um bug que o `git status` não mostrava.** Uma conversão de LF para CRLF em
arquivo YAML fez o Terraform planejar a substituição do pipeline de imagem
inteiro — `9 to add, 5 to change, 6 to destroy` — com a árvore de trabalho
limpa. Pego no `plan`, antes do `apply`, e resolvido no `.gitattributes`.

**Diagnóstico de rede com dado, não com palpite.** Flow logs em Parquet lidos
com duckdb deram o motivo real de o relógio das instâncias não sincronizar:
TCP 4460 barrado na saída do security group, não configuração de NTP. A
conclusão anterior, baseada em raciocínio sem medição, estava incompleta.

**Custo tratado como requisito, não como consequência.** Política de retenção
por linhagem de imagem, dimensionada para preservar rollback e derrubar o teto
de snapshot de ~300 GB para ~200 GB. Sem ela o custo cresce em silêncio, sem
alarme nenhum.

**Comentário que explica o porquê, não o quê.** Os `.tf` registram qual
armadilha cada argumento evita e qual `apply` falhou antes. É o contexto que
normalmente morre num chat e que aqui fica onde alguém vai ler de novo.

> **Versão sanitizada.** Nomes de empresa, IDs de conta, endereços IP e nomes
> de sistemas internos foram trocados por valores de exemplo. A estrutura, os
> módulos e todo o raciocínio dos comentários estão intactos — detalhes no
> [fim do arquivo](#sobre-esta-versão-sanitizada).

---

## Arquitetura

```
                       conta acme-swe-prod (111122223333)
                                 us-west-2
  ┌──────────────────────────────────────────────────────────────────────┐
  │                                                                      │
  │  bootstrap/            S3 + versionamento + SSE + prevent_destroy    │
  │    └── guarda o estado das outras três configurações                 │
  │                                                                      │
  │  images/               EC2 Image Builder                             │
  │    Ubuntu 26.04 LTS (Canonical, via SSM público)                     │
  │        ├─► acme-base-ubuntu-2604         ──┐ update · timezone       │
  │        │        └─► docker-host-x86        │ cloudwatch · cleanup    │
  │        └─► acme-base-ubuntu-2604-arm64   ──┘                         │
  │                 └─► docker-host-arm64                                │
  │    + 4 lifecycle policies (COUNT=2, uma por linhagem)                │
  │                                                                      │
  │  instances/            4 × t4g (Graviton), subnet privada            │
  │    sem IP público · sem key pair por padrão · IMDSv2 obrigatório      │
  │    um security group por máquina · acesso por Session Manager        │
  │                                                                      │
  │  network-peering/      VPC peering ──────────────────────────────────┼──►  conta de produção
  │    requester + rota na rt-private + DNS resolution                   │     (444455556666)
  │                                                                      │     172.31.0.0/16
  │  tools/flowlog/        duckdb lendo Parquet do S3                    │
  │    diagnóstico de tráfego sem montar Athena                          │
  └──────────────────────────────────────────────────────────────────────┘
       VPC 10.20.0.0/16 · NAT Gateway · Flow Logs em Parquet (25 campos)
       rede construída no console, FORA do Terraform — e isso é deliberado
```

---

## Stack

**Terraform** >= 1.10 (backend S3 com `use_lockfile`, sem DynamoDB) ·
**AWS provider** ~> 5.0 · **EC2 Image Builder** + componentes AWSTOE em YAML ·
**EC2** Graviton · **IAM** com permissions boundary · **VPC peering** ·
**VPC Flow Logs** em Parquet · **Session Manager** · **Python + duckdb** ·
**Ubuntu 26.04 LTS**

---

## Decisões que valem explicar

Essas são as escolhas que eu defenderia numa revisão de código, com o motivo —
não com a preferência.

**Fronteira explícita entre console e Terraform.** A rede desta conta foi
construída no console antes de o Terraform entrar, e eu **não importei**. A
regra ficou: o que nasce daqui pra frente vai em código; o que já existe fica
no console, documentado. Fronteira explícita não gera drift. Fronteira
implícita gera — alguém muda no console o que o Terraform acha que controla, e
o próximo `apply` desfaz.

**Estado separado por configuração.** Quatro backends com `key` diferente. Um
`terraform destroy` em `instances/` não alcança o pipeline de imagem, e nenhum
deles alcança o bucket de estado. O Terraform não valida unicidade de `key`:
duas configurações apontando pro mesmo caminho fazem a segunda achar que é dona
dos recursos da primeira.

**Arquivo novo é organização; pasta nova é isolamento.** O critério está
escrito em `instances/main.tf` e não é o tipo de recurso. Arquivo separado é
decisão humana — o Terraform concatena todos os `.tf` do diretório antes de
interpretar, e o endereço no state não carrega nome de arquivo, então mover um
bloco entre arquivos não muda nada. Pasta nova significa **state novo**, e só
se justifica quando pelo menos uma destas três é verdadeira: raio de destruição
diferente (o que nunca deve ser alcançado por um apply feito para outra coisa),
cadência diferente (imagem repica por mês, instância muda por semana, peering
quase nunca) ou credencial/dono diferente (IAM exige o perfil admin por causa
do `iam:PassRole`; rede depende de outra equipe). "Uma pasta por tipo de
recurso" erra nos dois sentidos — uma instância, o volume dela e o EIP dela são
três tipos com o *mesmo* ciclo de vida.

O corolário disso apareceu na prática: renomear **arquivo** não exige nada,
porque o nome do arquivo não entra no endereço do state. Renomear o **label do
module** exige bloco `moved`, porque ali o endereço *é* a identidade do
recurso — sem ele o Terraform vê um endereço novo para criar e um órfão para
destruir. No rename de uma das máquinas isso eram 14 recursos, incluindo a
instância com o disco em uso. Com o bloco, o plan fechou em
`0 to add, 0 to change, 0 to destroy` e 14 movimentos.

**AMI fixa no tfvars, nunca `most_recent = true`.** Parece conveniente e é
perigoso. Com data source dinâmico, uma build nova de imagem muda o valor e o
próximo `apply` — mesmo um feito para outra coisa — **destrói e recria** a
instância, levando o disco com ela. Trocar de imagem tem de ser ato
deliberado, não efeito colateral.

**Imagens empilhadas em vez de componentes repetidos.** O host de container usa
a nossa própria AMI base como imagem-pai. Assim ele é *garantidamente* a base
mais Docker, não "as duas construídas com os mesmos componentes em datas
diferentes", que poderiam partir de níveis de patch distintos. O custo da
escolha é real e vale registrar: cria cadeia de dependência, porque a imagem de
container é tão antiga quanto a base de onde partiu, e repicar a base não
atualiza a filha sozinho.

**Um security group por máquina.** Antes as instâncias reaproveitavam um SG
compartilhado. O problema não era o nome: **SG compartilhado é regra
compartilhada** — abrir uma porta para uma máquina abriria para todas. O SG
ficou dentro do módulo, então "um por máquina" é o padrão e não depende de
alguém lembrar.

**Regras de SG como recursos separados, não blocos inline.** Com
`ingress`/`egress` inline o Terraform assume a posse de *todas* as regras do
grupo e remove qualquer uma criada fora dele. Separadas, a gestão é por regra.
Isso teve consequência real: nove regras de integração foram criadas à mão
durante uma urgência e o `plan` seguiu dizendo "No changes" — com blocos
inline, o apply seguinte teria apagado a integração inteira. Depois elas foram
importadas, porque regra fora do código é regra invisível.

**Retenção de imagem é requisito, não refinamento.** Cada build guarda um
snapshot EBS. Quatro linhagens × 3 versões = até 300 GB (~US$ 15/mês) de imagem
que ninguém usa, crescendo sem alarme nenhum. Baixei para `COUNT = 2` — o
mínimo que preserva rollback ("a atual e a anterior") — e o teto caiu pra
~US$ 10/mês. `COUNT = 1` foi descartado: apagaria justamente a versão que
funcionava no momento em que a nova entrasse.

**Instância sem porta de entrada, por padrão.** Sem IP público, sem key pair,
entrada do SG vazia, saída restrita a 443/80. O acesso é por Session Manager,
que funciona porque o agente SSM abre a conexão **de dentro pra fora**. IMDSv2
obrigatório com `hop_limit = 1`, o que impede um container na instância de
alcançar o metadata service.

Duas das quatro máquinas abriram entrada depois, para a integração com o
sistema legado. Cada regra é uma exceção declarada, restrita a um host em
`/32`, com a `description` dizendo por que a porta existe — porque é o único
lugar que registra o motivo para quem revisar depois. Nenhuma porta de banco
(3306/1433/5432) foi aberta, que era exatamente o que a restrição de saída
queria impedir.

---

## Problemas reais que eu diagnostiquei

A parte do repositório que eu mais gosto. Cada um desses custou tempo e deixou
uma lição que está escrita no código, não só aqui.

### CRLF substituindo infraestrutura, com o `git status` limpo

Depois de um rebase, o `core.autocrlf = true` (padrão do Git no Windows)
converteu os YAML dos componentes de LF para CRLF. O Terraform lê esses
arquivos com `file()` e joga o conteúdo no atributo `data` do componente — onde
**todo argumento é ForceNew**. A mudança de bytes virou substituição em
cascata: componente substituído muda o ARN, o ARN faz parte da receita, logo as
receitas também.

```
Plan: 9 to add, 5 to change, 6 to destroy
```

E aplicar aquilo falharia no meio, porque receita referenciada por imagem já
construída não pode ser removida. O pior detalhe: **`git status` mostrava a
árvore limpa**, porque o git normaliza terminações ao comparar. Duas
ferramentas lendo o mesmo arquivo e discordando sobre o conteúdo.

Correção: `.gitattributes` com `*.yml text eol=lf`. A regra geral que tirei
disso — *arquivo cujo conteúdo vira atributo de recurso não pode depender da
configuração de checkout da máquina.*

### Um CIDR repassado e nunca verificado

Peering `active`, rota `active`, e o tráfego para a outra conta dava timeout
**sem mensagem de erro**. A rota apontava `172.16.0.0/16`; a VPC de destino
usava `172.31.0.0/16`. O valor tinha vindo repassado numa conversa e nunca foi
conferido na fonte. Sem rota específica, o tráfego caía no `0.0.0.0/0` e saía
pelo NAT.

O detalhe que fecha a lição: enquanto a conexão está pendente, a AWS devolve
`null` nesse campo — só depois do aceite dá pra confirmar
(`AccepterVpcInfo.CidrBlock`). Conferir na fonte não é formalidade.

### O relógio que não sincronizava

`timedatectl` reportava `System clock synchronized: no` com
`NTP service: active`. O documento tinha concluído que o security group não
podia estar envolvido, porque o serviço de tempo da AWS fica em
`169.254.169.123`, link-local, que não é filtrado por SG. O raciocínio estava
**certo para o serviço da AWS e incompleto**.

O flow log mostrou 81 tentativas de saída em **TCP 4460** para seis destinos
`ntp-nts-*.canonical.com`. NTS é NTP autenticado por TLS, e a troca de chaves
roda na 4460 (RFC 8915). A imagem do Ubuntu vem com cinco pools da Canonical
marcados `prefer`; com várias fontes preferidas e só uma alcançável, o chrony
media a da AWS e não a usava para corrigir.

Correção: componente da golden image fixando `169.254.169.123` como fonte
única. A alternativa — abrir a 4460 — acoplaria a regra a seis `/32` de
terceiro e alargaria a restrição de saída.

### `ACCEPT` no flow log não significa "chegou"

Uma consulta por portas de banco devolveu `3306 ACCEPT`, `5432 ACCEPT`,
`1433 ACCEPT` — o que parece violação grave. Não era. Era varredura da internet
contra o Elastic IP do NAT: 9.725 fluxos, 3.510 origens distintas, 6.046
portas. O **NAT Gateway não tem security group**, então tudo que bate nele
aparece como `ACCEPT` e é descartado pelo próprio NAT depois.

`ACCEPT` é permissão, não entrega. Para avaliar a postura de uma instância,
filtre pelo ENI dela. Está escrito no topo do script, porque eu mesmo caí.

### Permissions boundary negando sem dizer o motivo

A conta é administrada por delegação, com uma boundary que só permite criar IAM
sob o prefixo `delegated-`. Criar a política de retenção falhava com:

```
AccessDeniedException: not authorized to perform iam:PassRole on
role/delegated-imagebuilder-lifecycle because no permissions boundary
allows the iam:PassRole action
```

A boundary restringia `iam:PassRole` a `ec2`, `lambda` e `ecs-tasks`, e a
política de lifecycle passa o papel para `imagebuilder.amazonaws.com`.
Diagnosticado com `simulate-principal-policy`, que confirma permissão sem
precisar tentar o `apply`. Depois da correção publicada pelo administrador, a
mesma sessão já valia — mudança em documento de política vale na próxima
chamada, não exige relogin.

Registrei uma ressalva junto: a correção usou `StringLike` com `"image*"`, o
que alargou a boundary mais que o necessário. A versão estreita daria o mesmo
resultado funcional.

### Verificador complicado vira fonte de falha

De três builds que falharam num componente, **uma foi bug real e duas foram o
próprio código de validação** — um `grep -A3` cuja janela cortava antes do
campo e reprovava configuração correta. Simplifiquei para uma única checagem
determinística. Validação que falha sozinha não é detector, é ruído.

---

## Como navegar

| Caminho | O que ler ali |
|---|---|
| [`terraform/README.md`](terraform/README.md) | convenções, tags, perfis de acesso, a fronteira console/código |
| [`terraform/bootstrap/`](terraform/bootstrap) | o problema circular do bucket de estado, resolvido em dois passos |
| [`terraform/images/`](terraform/images) | a fábrica de imagens: imutabilidade, `create_before_destroy`, retenção |
| [`terraform/instances/`](terraform/instances) | o módulo EC2, um arquivo por máquina e as decisões de segurança de rede |
| [`terraform/network-peering/`](terraform/network-peering) | peering entre contas e o episódio do CIDR errado |
| [`tools/flowlog/`](tools/flowlog) | diagnóstico de tráfego com duckdb, sem montar Athena |
| [`docs/network-built-in-console.md`](docs/network-built-in-console.md) | a metade da conta que **não** está em Terraform, e por quê |

> **Nota de idioma.** O repositório é em inglês: comentários, descriptions e os
> READMEs de diretório. Este arquivo é a tradução da página inicial — é o único
> documento em português.

Os comentários nos `.tf` são longos de propósito. Eles explicam *por que* o
código é daquele jeito — qual armadilha o argumento evita, qual apply falhou
antes. É o tipo de contexto que normalmente morre num chat e que aqui fica onde
alguém vai ler de novo.

---

## Rodando

Este repositório **não roda contra a minha conta** — os identificadores são de
exemplo. Para apontar para uma conta sua:

```powershell
# 1. Terraform >= 1.10 (o use_lockfile do backend S3 exige)
winget install HashiCorp.Terraform

# 2. acesso
aws configure sso
$env:AWS_PROFILE = "acme-swe-prod"   # o backend NÃO herda o profile do provider

# 3. preencher os valores
cd terraform/images
cp terraform.tfvars.example terraform.tfvars   # editar com os IDs da sua conta

# 4. ordem na primeira vez: bootstrap -> images -> instances
terraform init
terraform plan
```

Cada diretório tem o próprio `terraform.tfvars.example` com todas as variáveis
comentadas. Os `.tfvars` reais estão no `.gitignore` — eles carregam IDs de
infraestrutura e não deveriam estar em repositório nenhum.

---

## O que ficou pendente

Listo porque projeto sem pendência conhecida normalmente é projeto sem
inventário.

- **A retenção não seleciona nada ainda.** As políticas estão `ENABLED` e
  corretas, mas a seleção por tag avalia o *recurso image* do Image Builder, e
  ele nasce sem tags — não propaga do pipeline nem da receita. Hoje o
  `tag-resource` é manual depois de cada build. A Lambda que automatiza isso
  está desenhada e não implementada: com disparo manual e poucas imagens,
  taguear à mão é mais honesto que manter código.
- **Build agendada está desligada** de propósito, e continua assim até o
  tagueamento ser automático. Build que ninguém acompanha com retenção que não
  seleciona = snapshot de 20 GB acumulando em silêncio.
- **Esteira de CI por OIDC** depende de `iam:CreateOpenIDConnectProvider`, que
  ainda não foi liberado. Enquanto isso, nada de chave de acesso de longa
  duração guardada em variável.
- **A rota de volta do peering** existe do outro lado, mas falta confirmar em
  qual route table. Tabela main só vale para subnet sem associação explícita.
- **Faixas de porta largas** numa das máquinas (400–1000/TCP) por causa de
  simulação de protocolo industrial. O risco está contido porque a origem é um
  host em `/32`, não uma faixa — mas estreitar reduziria superfície sem custo,
  se as portas efetivamente usadas forem levantadas.

---

## Sobre esta versão sanitizada

Trocados por valores de exemplo: nome da empresa, IDs de conta AWS, IDs de VPC,
subnet, security group, route table, peering, AMI, ENI e snapshot, endereços IP
públicos e privados, e-mails, domínios, nomes de sistemas internos e
referências a tickets.

Mantidos: toda a estrutura do código, os módulos, os componentes, os
comentários técnicos, os diagnósticos e as decisões. As faixas de IP de exemplo
usam RFC 5737 (`203.0.113.0/24`) e os IDs de conta seguem a convenção da
documentação da AWS (`111122223333`).

---

## 📜 Licença

Este projeto é distribuído sob a Licença MIT. Veja [`LICENSE`](LICENSE) para
mais detalhes.

