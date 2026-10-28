# VPC peering com a conta de produção

Conexão entre a VPC da conta `acme-swe-prod` (111122223333) e a VPC de produção,
ambas em **us-west-2**. Cartões **A33 → A34** do plano de ação.

---

## Estado atual

| | |
|---|---|
| Conexão | **`pcx-0a1b2c3d4e5f90002`** |
| Estado | **`active`** — criada e aceita em 16/10/2026 |
| Nosso lado | `vpc-0a1b2c3d4e5f60001` — `10.20.0.0/16` |
| Lado da produção | conta `444455556666` · **`vpc-0a1b2c3d4e5f60002`** · **`172.31.0.0/16`** |
| Rota na `rt-private` | **`172.31.0.0/16 → pcx-0a1b...`, `active`** — criada **à mão**, ver "Divergência" |
| Resolução de DNS nossa | **`false`** — a etapa 2 ainda não foi aplicada |
| Resolução de DNS deles | `null` — não habilitado **ou** não visível daqui |

Criada em 16/10/2026. **Custo zero:** peering não tem cobrança por hora.

### A conexão anterior foi apagada — e por quê

A primeira conexão, **`pcx-0a1b2c3d4e5f90001`** (criada e aceita em 15/10, para
`vpc-0a1b2c3d4e5f60003` / `172.16.0.0/16`), foi **apagada em 16/10**.

**Motivo:** aquela VPC não tinha **recurso nenhum** atribuído. O peering estava
tecnicamente correto e o destino era inútil — não havia com o que conversar.

**Por que não foi possível manter as duas em paralelo.** A recomendação inicial
era essa: peering é gratuito, e manter a antiga preservaria um caminho pronto
enquanto a nova era aceita. Não deu, e o motivo é concreto: **as duas rotas
iriam para a mesma `rt-private`**, e route table não aceita duas rotas para o
mesmo destino. A substituição não foi escolha.

> Na época a informação era de que a VPC nova usava **o mesmo** CIDR. Acabou
> não usando — ver abaixo. Com os CIDRs diferentes, coexistir **teria** sido
> possível. A decisão foi tomada com a informação disponível, e fica
> registrada assim.

**Apagar foi irreversível:** o `pcx-0a1b...` não volta, e o aceite que a produção
havia dado em 15/10 morreu com ele. Refazer exigiu nova rodada de aceite.

### O CIDR estava errado — o erro mais caro do dia

**`172.16.0.0/16` era o CIDR da VPC ANTERIOR.** A `vpc-0a1b2c3d4e5f60002` usa
**`172.31.0.0/16`** — confirmado na fonte depois do aceite, com `CidrBlockSet`
trazendo um único bloco, sem faixa secundária.

A primeira rota foi criada com o valor errado, e **o estado parecia saudável**:

```
pcx-0a1b2c3d4e5f90002   active
172.16.0.0/16 -> pcx-0a1b2c3d4e5f90002   active
```

Peering `active`, rota `active`, e **nada funcionaria**. Tráfego para os
servidores reais (`172.31.x.x`) não encontraria rota específica, cairia no
`0.0.0.0/0` e sairia pelo **NAT para a internet**. Tráfego para `172.16.x.x`
entraria na conexão e não acharia ninguém. Nos dois casos: **timeout sem
mensagem de erro.**

**A causa raiz não foi técnica:** `172.16.0.0/16` era informação **repassada**,
nunca verificada. E não havia como verificar antes — enquanto a conexão está
`pending-acceptance` a AWS devolve `null` em `AccepterVpcInfo.CidrBlock`. Só
depois do aceite dá para confirmar.

**É por isso que "conferir o CIDR na fonte" é passo separado do checklist, e
não formalidade.** Foi conferido, divergiu, e a rota foi corrigida à mão.

### Suspeita a confirmar: isso parece ser a VPC default deles

Três sinais juntos: ID de **8 caracteres** (formato pré-2016), CIDR
**`172.31.0.0/16`** e **nenhuma faixa secundária**. É a assinatura de **VPC
default da AWS** — toda conta nasce com uma, nessa faixa.

Importa saber porque VPC default vem com **Internet Gateway e IP público
automático**, desenho oposto ao nosso — foi exatamente por isso que as VPCs
default das 17 regiões desta conta foram apagadas. Produção rodando em VPC
default é plausível em conta antiga, mas vale saber que é isso que estamos
alcançando, e não uma VPC desenhada para o papel.

### Uma reversão que vale registrar

O levantamento de setembro **supunha `172.31.0.0/16`**, e isso ficou nos
documentos como suposição errada quando apareceu o `172.16.0.0/16` em 15/10.

Com **duas VPCs** na conta de produção, cada informação se referia a uma. Para
a VPC que de fato importa, **o levantamento estava certo**. A conclusão "o
levantamento errou" é que estava incompleta.

### Consequência nova para o Docker — risco mudou de status

`172.31.0.0/16` **está no caminho de alocação do Docker** (`172.17` subindo até
`172.31`), e é a última faixa antes de ele passar para `192.168`.

A decisão de 15/10 de manter o pool no padrão se apoiava em **risco zero**: a
produção era `172.16.0.0/16`, fora do caminho. Agora:

```
risco ZERO  ->  risco BAIXO E REAL
```

Probabilidade segue baixa — exige **15 redes** criadas antes no mesmo host, o
que são dezenas de stacks `docker-compose`. **Não foi revertido.** Mas se
aparecer "o host de container não fala com a produção", **esta é a primeira
hipótese**: rede de container cria **rota local**, rota local vence a rota da
VPC, e a rede local não escapa — ela **engole**.

Ver `CIDRs.txt`, seção do Docker.

### Divergência: a rota está fora do Terraform

A rota `172.31.0.0/16 → pcx-0a1b2c3d4e5f90002` foi criada **à mão**, e o
`terraform state list` deste diretório tem **só** a conexão:

```
aws_vpc_peering_connection.production
```

**Consequência:** descomentar a etapa 2 e aplicar falharia com
`RouteAlreadyExists` — o Terraform tentaria criar uma rota que já existe.

**O caminho recomendado é `import`**, não apagar e recriar: traz a rota
existente para o estado sem tocar no tráfego.

```powershell
$env:AWS_PROFILE = "acme-swe-prod"
# 1. descomentar a etapa 2 do main.tf (o import exige o recurso no codigo)
# 2. importar a rota que ja existe
terraform import aws_route.to_production "rtb-0a1b2c3d4e5f80001_172.31.0.0/16"
# 3. plan: esperado 1 to add (so as opcoes de DNS) e NENHUMA mudanca na rota
terraform plan
```

O `plan` depois do import é a verificação que importa: se ele quiser **alterar**
a rota, é porque o valor importado difere do código — e aí o suspeito é o
`production_vpc_cidr` no `tfvars`.

### A etapa 2 foi aplicada em 15/10

Nada a rodar aqui. O `terraform plan` retorna `No changes` com exit code 0 —
reconferido em 16/10 —, e o estado contém `aws_route.to_production`
(`r-rtb-0a1b2c3d4e5f800013246677288`) e
`aws_vpc_peering_connection_options.requester`.

**Nosso lado do A34 está completo.** O que falta é do lado deles, abaixo.

### Para testar, agora existe instância

A **`operationalflow`** (`i-0a1b2c3d4e5fa0001`, `10.20.1.10`) está no ar e
`Online` no SSM. O teste de conectividade pode ser feito de dentro dela:

```bash
nc -vz <ip-da-producao> <porta>
```

**Mas leia isto antes de interpretar o resultado:** a saída do SG daquela
máquina está restrita a **443/80**. Um teste em porta de banco
(3306/1433/5432) falha **por desenho**, não por erro de rede — e confundir as
duas coisas é o jeito mais rápido de diagnosticar errado. Se a integração for
em 443, dá para testar já.

**Se falhar com tudo aparentemente certo**, a ordem de suspeita é: rota do lado
deles → NACL do lado deles (é *stateless* e avaliada separadamente do SG) →
regra de SG.

O **Reachability Analyzer** agora também serve, já que exige origem e destino
concretos — antes não havia instância para usar como origem.

---

## Por que são dois `apply`

A rota e as opções de DNS exigem que a conexão esteja **`active`**. Com ela em
`pending-acceptance`, o `apply` falharia no meio — com a solicitação já criada
e o estado parcialmente aplicado. Por isso a etapa 2 fica **comentada** no
`main.tf` até o aceite sair, no mesmo padrão de `instances/main.tf`.

```
apply 1  ─ apaga a antiga, cria a solicitação nova   ← FEITO 16/10
   ↓
       o responsável da produção ACEITA               ← FEITO 16/10
   ↓
apply 2  ─ rota na rt-private + resolução de DNS      ← PENDENTE
```

**O mecanismo apareceu duas vezes, e a segunda ensinou mais.** Na troca de VPC,
`peer_vpc_id` é **ForceNew**: a conexão é destruída e recriada, e a nova nasce
`pending-acceptance`. Ou seja a etapa 2 **voltou** a ficar comentada depois de
já ter estado aplicada. Trocar a VPC de um peering não existe — é sempre
substituição.

O padrão vale para qualquer recurso que dependa de ação de terceiro no meio do
caminho.

---

## O que falta, e metade não é nossa

### Do nosso lado

1. **`import` da rota** criada à mão — ver "Divergência" no Estado atual.
2. **`apply` da etapa 2**, que liga a resolução de DNS do nosso lado (hoje
   `false`).

### Do lado da produção — três passos

1. ~~**Aceitar a solicitação**~~ — **FEITO em 16/10** para a
   `pcx-0a1b2c3d4e5f90002`.
2. **Rota de volta:** destino `10.20.0.0/16`, target a conexão de peering, na
   route table **das subnets envolvidas**. Informado como feito "na rota
   default" — **e isso precisa ser confirmado**, ver abaixo.
3. **Accepter DNS resolution** — Actions → Edit DNS settings, se a integração
   usar nome em vez de IP. Hoje `AccepterVpcInfo.PeeringOptions` retorna
   `null`, o que pode significar não habilitado **ou** não visível daqui.

Esses três **não podem estar neste código**: são recursos em outra conta, e não
temos credencial lá.

> ### A confirmar: "rota default" pode não ter efeito nenhum
>
> Route table só vale para as **subnets associadas a ela**. A route table
> **main** (a "default") é usada apenas pelas subnets que **ninguém associou
> explicitamente** a outra.
>
> Se as subnets dos servidores da integração têm associação explícita a outra
> route table, a rota na main **não faz nada** — e o sintoma é **timeout sem
> erro**, idêntico a rota ausente. Não há como distinguir os dois daqui.
>
> **Pergunta para ele:** as subnets onde estão os servidores usam essa route
> table? Se não souber, olhar a subnet do servidor e ver qual route table
> aparece associada.
>
> Por ser VPC default há chance razoável de que usem a main — VPC default vem
> assim de fábrica. Mas "provável" não é "verificado".

### Do nosso lado — como conferir

```powershell
$env:AWS_PROFILE = "acme-swe-prod"

aws ec2 describe-vpc-peering-connections `
  --filters "Name=status-code,Values=active,pending-acceptance" `
  --query "VpcPeeringConnections[].{Id:VpcPeeringConnectionId,Estado:Status.Code,CIDRDeles:AccepterVpcInfo.CidrBlock,DNSNosso:RequesterVpcInfo.PeeringOptions.AllowDnsResolutionFromRemoteVpc}" `
  --output table --profile acme-swe-prod
```

**Filtrar por `status-code`**, e não consultar sem filtro: conexão apagada
continua aparecendo como `deleted` por algumas horas, e numa lista sem filtro
isso confunde — foi o caso da `pcx-0a1b...` em 16/10.

**Por que o `CIDRDeles` importa:** enquanto a conexão está pendente a AWS não
revela o CIDR do outro lado. Depois do aceite ele aparece, e é a **única**
confirmação independente de que a rota aponta para a faixa certa. Em 16/10 essa
conferência pegou o erro de `172.16` contra `172.31`.

---

## O que este diretório deliberadamente não faz

**Não cria regra de security group.** É o cartão **A35**, e depende de duas
respostas da engenharia que ainda não existem: **quem inicia a conexão** e **em
qual porta**.

Foi por isso que criar o peering agora é seguro: **a conexão existir não faz
tráfego nenhum passar.** Quem decide isso é o security group, e o da
`operationalflow` (`acme-swe-nonprod-operationalflow-sg`,
`sg-0a1b2c3d4e5fd0001`) continua com entrada vazia e saída restrita a 443/80.

> **Nota de 16/10:** cada máquina passou a ter **SG próprio**, criado dentro do
> módulo `ec2-instance`. O `acme-swe-prod-app01-sg` do A18 ficou órfão. Isso
> muda o A35: a regra da integração entra **no SG da máquina que precisa**, não
> num SG compartilhado — que seria **regra compartilhada**, valendo para toda
> máquina que o usasse.

> **Atenção ao A35.** Abrir a porta da integração é fácil de reverter no papel e
> difícil na prática: depois que o tráfego real estiver passando, fechar derruba
> a integração. A hora de decidir o desenho é antes de passar tráfego.

Se a produção **puxa** da app01, reabre o **A18** (entrada hoje vazia por
desenho). Se a app01 **envia**, a saída em 443/80 não alcança banco em
3306/1433/5432 — e abrir essas portas desfaz a mitigação do risco **R07**.

---

## Fronteira com o resto do repositório

A VPC e a `rt-private` foram construídas **no console** e não estão no estado
do Terraform. Isso não impede a rota ficar em código:

**O `aws_route` gerencia UMA rota dentro de uma route table existente**,
referenciada por ID. Não exige que a tabela esteja sob gestão do Terraform. Por
isso a rota vai em código sem importar a rede e sem gerar drift na tabela.

A rota vai na **`rt-private`** (`rtb-0a1b2c3d4e5f80001`), associada
explicitamente a `private-c` e `private-d`. **Não vai na `rt-main`**, que fica
só com `local` de propósito — decisão do A15, para que "esquecer de associar"
falhe de forma segura.

---

## Armadilhas

### Rota é necessária nas DUAS contas

Meio caminho não funciona, e o sintoma é **timeout sem mensagem de erro** — não
"rota ausente". Nossa rota sozinha não faz nada.

### O peering NÃO resolve DNS privado por padrão

Precisa ser ligado **nos dois sentidos** se a integração usar nome em vez de IP.
O sintoma de faltar é **"o host não existe"**, que parece erro de aplicação e
não de rede.

### A solicitação pendente expira em 7 dias

Se expirar, o Terraform verá a conexão como `expired` e o próximo `plan`
proporá recriar. O comportamento é correto, mas significa combinar nova janela
com o outro lado.

### NACL do lado deles pode bloquear com tudo aparentemente certo

NACL é **stateless** e avaliada separadamente do security group. Não vale
levantar no pedido inicial — vale lembrar **se a conectividade falhar com
peering, rotas e SGs todos corretos**.

### O peering NÃO leva os usuários do escritório às instâncias

**Peering não é transitivo.** Ninguém do escritório chega às instâncias por ele.
Isso continua sendo o ALB da P5 (cartões A37–A40), assunto separado. Confusão
comum.

### Peering é por par de VPCs

A partir de três VPCs o número de conexões cresce como `n(n-1)/2` e o Transit
Gateway passa a ser o instrumento certo. Enquanto for produção ↔ `acme-swe-prod`,
peering é o mais simples e o mais barato.

### Trocar a VPC de um peering não existe — é substituição

`peer_vpc_id` é **ForceNew**. Mudar o valor destrói a conexão e cria outra, que
nasce `pending-acceptance` e exige **novo aceite** do outro lado. Aconteceu em
16/10 e custou uma rodada de coordenação.

A rota e as opções de DNS caem junto, porque dependem do ID da conexão. Isso é
correto, mas significa que a etapa 2 **volta** a ficar comentada — não dá para
trocar a VPC num único apply.

### Apagar conexão é irreversível, e o aceite morre com ela

O ID não volta, e a aceitação do outro lado se perde. Antes de apagar, vale
perguntar se **coexistir** resolve: peering é gratuito, e duas conexões para
VPCs diferentes são permitidas.

**O que impede coexistir** é CIDR igual ou sobreposto: duas rotas para o mesmo
destino não cabem na mesma route table. Essa foi a razão pela qual a
substituição de 16/10 pareceu obrigatória — com a informação de que os CIDRs
eram iguais. Eram diferentes, e coexistir teria sido possível.

### Conexão apagada continua aparecendo no `describe`

Por algumas horas, com `Status.Code = deleted`. Não conta para limite nem gera
custo, mas polui consulta sem filtro. Usar
`--filters "Name=status-code,Values=active,pending-acceptance"`.

### `peer_region` não é declarado

As duas VPCs estão em us-west-2 — confirmado em 16/10 pelo
`AccepterVpcInfo.Region` da conexão nova. Declarar `peer_region` igual à região
do provider cria peering **inter-região** e muda o custo: a transferência passa
a ser cobrada por GB.

### `auto_accept` só funciona na mesma conta

Entre contas diferentes a aceitação é obrigatoriamente manual, do outro lado.

---

## Relação com o Docker (cartão A42)

**Isto mudou em 16/10, com a troca de VPC. O que estava escrito aqui antes
valia para o CIDR anterior.**

O CIDR da produção é **`172.31.0.0/16`** (`vpc-0a1b2c3d4e5f60002`), e essa faixa **está
no caminho de alocação do Docker** — ele aloca de `172.17.0.0/16` subindo até
`172.31`, e esta é a última antes de passar para `192.168.0.0/20`.

```
risco ZERO (com 172.16.0.0/16)  ->  risco BAIXO E REAL (com 172.31.0.0/16)
```

**A decisão de 15/10 de manter o pool no padrão não foi revertida**, e continua
defensável: chegar a `172.31` exige **15 redes** criadas antes no mesmo host, o
que são dezenas de stacks `docker-compose`. Mas a justificativa daquela decisão
— "a produção não está no caminho de alocação" — **deixou de valer**.

**Se aparecer "o host de container não fala com a produção", esta é a primeira
hipótese.** O mecanismo: rede de container cria **rota local** no host, rota
local é mais específica que a rota da VPC, e a rede local não escapa — ela
**engole** o tráfego que deveria sair pela `eth0`.

**O que o tráfego de saída do container faz não é o problema:** ele passa por
**MASQUERADE** e chega ao destino com o IP do host, então o IP do container
nunca aparece na rede. O problema é de **destino**.

**Se um dia precisar fixar o pool**, agora há motivo legítimo — e o caminho
está em `images/README.md`, seção "O pool de endereços voltou ao padrão":
escrever o `daemon.json` **antes** do `apt install`, porque
`default-address-pools` não se aplica à rede `bridge` que o daemon já criou.

**Nota histórica:** a tentativa original de fixar o pool foi revertida em 15/10
porque a justificativa estava errada — supunha colisão com `172.16.0.0/16`,
confundindo `172.16.0.0/12` (dezesseis /16) com o /16 da produção. A reversão
continua certa pelos motivos dela; o que mudou é que agora existe uma colisão
de verdade, com outra faixa.

**Para a escolha de faixas futuras, a regra não mudou:** evitar
`172.17`–`172.31` ao criar VPC ou sub-rede nova. O que mudou é que agora há um
caso concreto dentro dessa faixa.

---

## Tags — divergência deliberada deste diretório

| Tag | Aqui | Nos outros diretórios |
|---|---|---|
| `acme:cost-allocation:Project` | `infrastructure` | `best-practices` |
| `acme:cost-allocation:Application` | `network-traffic` | `golden-image`, `terraform-state`, `app01` |

A `Application` descreve **o que o recurso é**, não o projeto — por isso varia por
diretório e não deve ser padronizada entre eles.

A `Project` **acompanha o escopo do que está sendo construído** e também varia: aqui a
conexão é infraestrutura de rede, não entregável do projeto de aprendizado. Isso é o
critério definido em 15/10, não uma exceção — a uniformidade anterior
(`best-practices` nos três diretórios) era circunstancial. Consequência no Cost
Explorer é nula de todo modo, porque **peering não tem custo**: a tag aqui serve para
inventário, não para rateio.

Trocado em 15/10/2026, **antes** de as tags de alocação de custo serem ativadas na
conta de gerenciamento. Isso é o que torna a troca limpa: depois da ativação, o mesmo
recurso apareceria sob dois valores dependendo do mês, e não se reescreve histórico de
faturamento.

---

## Estrutura

```
network-peering/
├── README.md                    este arquivo
├── provider.tf                  versões e perfil (PowerUser basta: não há IAM)
├── backend.tf                   estado remoto, key própria
├── variables.tf                 declaração das variáveis, com validações
├── terraform.tfvars             valores — NÃO vai para o git
├── terraform.tfvars.example     modelo versionável
└── main.tf                      etapa 1 e etapa 2, as duas aplicadas
```

O `terraform.tfvars` guarda identificadores de **outra conta AWS**. Não
versionar não é só higiene de segredo: é não publicar dado de infraestrutura de
equipe de terceiro.
