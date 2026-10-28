# Decisões — diretório `instances/`

Histórico de decisões de arquitetura do diretório `instances/`. Extraído dos
comentários do antigo `instances/main.tf` em 26/10, quando as 6 máquinas Linux
migraram para `linux-erp-site-{nonprod,prod}` e a raiz passou a ser índice +
scaffold (`_templates/`).

> Documento versionado. Há uma cópia em `docs/` por decisão de 26/10.

---

## Mapa atual do diretório

```
instances/
  _templates/                  molde para criar stack nova (copie e ajuste)
  linux-erp-site-nonprod/      3 Linux do site legacy ERP, nonprod + client SG
  linux-erp-site-prod/         3 Linux do site legacy ERP, prod + client SG + cw_agent_config
  win-app-site/              VMs App (Windows Server 2025), site SITE-A
  backend.tf provider.tf       a raiz em si (state com data sources compartilhados)
  main.tf variables.tf
```

Cada **site** é uma pasta com state próprio. As Linux do legacy ERP ficam separadas
por ambiente (nonprod/prod) — a fronteira de state é a fronteira de
blast-radius: um apply/destroy errado no nonprod não alcança produção.

---

## ARQUIVO versus PASTA — o critério, que NÃO é o tipo de recurso

**ARQUIVO NOVO**: para cada unidade que se lê e edita junto. Arquivo é
organização HUMANA: o Terraform concatena todos os `.tf` do diretório antes de
interpretar, e o endereço no state não tem nome de arquivo dentro. Mover bloco
entre arquivos, ou renomear o arquivo, não muda nada no state.

**PASTA NOVA** (= state novo, key nova no backend): a pergunta que decide é

> **"CONSIGO RECRIAR ISTO A PARTIR DO CÓDIGO?"**

| RECRIÁVEL — errar custa minutos | NÃO RECRIÁVEL — errar custa DADO |
|---|---|
| EC2 da golden image | RDS |
| security group | S3 com conteúdo |
| ALB, target group | EFS |
| launch template | volume EBS de DADOS |
| disco raiz (`delete_on_termination`) | zona Route 53 com registros |

O que não é recriável vai para pasta própria, SEMPRE. Não por elegância: um
`terraform destroy` numa pasta não tem como alcançar outra. É o único
isolamento que não depende de alguém estar atento.

**Por que não "uma pasta por tipo de recurso":** o tipo é um bom indício e erra
nos dois sentidos. Um volume EBS de DADOS é família EC2, mesmo tipo da
instância, e pertence ao lado protegido. Um ALB é recurso grande, caro e
visível, e é totalmente recriável.

**O motivo comportamental, que é o decisivo:** se 90% dos plans são mudança
rotineira de máquina, aprende-se a passar o olho. Em 20/10 um "14 to destroy"
por troca de key_name só foi pego porque alguém leu a LISTA de recursos, não o
resumo. Misturar recurso de consequência alta com rotina treina o hábito de
leitura errado.

**Os outros dois gatilhos**, quando o recurso é recriável mas ainda assim
separa:

- **CADÊNCIA.** O que muda junto fica junto. As imagens repicam por mês, as
  instâncias mudaram quatro vezes em dois dias, o peering quase nunca.
- **CREDENCIAL OU DONO DIFERENTE.** IAM exige o perfil admin por causa do
  `iam:PassRole`; rede depende de outra equipe. Fronteira de permissão é
  fronteira de state, e é o gatilho mais objetivo dos três.

A divisão por diretório segue o critério, não o tipo:

```
bootstrap/        o bucket do state - tem de existir ANTES de tudo
images/           pipeline de imagem, cadência mensal
instances/        as máquinas - todas recriáveis
network-peering/  depende de outra conta e de outra equipe
```

**Quando chegar RDS ou bucket de aplicação:** pasta própria, com as travas do
recurso junto da parede de state —
`deletion_protection = true` (a AWS recusa o delete),
`skip_final_snapshot = false` (exige snapshot antes de apagar),
`lifecycle { prevent_destroy = true }` (falha NO PLAN, antes de chamar a AWS).
O `prevent_destroy` é o mais útil dos três: pega destroy E replace.

E a regra de acesso ao banco mora no diretório do BANCO, descobrindo o SG da
máquina por data source — não por ID copiado, e não com `terraform_remote_state`,
que acopla um state aos detalhes internos do outro.

**O custo de pasta nova, que é real:** backend, provider e variables
duplicados; e sobretudo os valores compartilhados (vpc_id, subnet,
instance_profile, AMIs, common_tags) copiados em cada terraform.tfvars. O jeito
de tornar a divisão barata é descobrir o compartilhado por data source em vez
de copiar ID:

```hcl
data "aws_subnet" "private_d" {
  filter {
    name   = "tag:Name"
    values = ["acme-swe-prod-private-d"]
  }
}
```

Note o contraste com a AMI, onde data source é PROIBIDO: lá o problema é
rastrear "a mais recente", porque `ami` é ForceNew e recriaria a instância. VPC
e subnet não mudam, então o raciocínio não se aplica.

---

## Rename de ARQUIVO vs rename de LABEL (comprovado)

- Renomear **arquivo** não precisa de nada — o nome do arquivo não entra no
  endereço do state. Comprovado em 21/10 e 23/10 com plan No changes.
- Renomear **label** de módulo (`module.X`) precisa de bloco `moved`, senão o
  Terraform destrói e recria. Comprovado no rename de `operationalflow` →
  `nonprodoperationalflow` (21/10): 0 added, 0 changed, 0 destroyed, 14
  movimentos.

---

## Migração das 6 Linux para `linux-erp-site-*` (26/10)

As 6 Linux saíram do módulo `ec2-instance` (um arquivo por máquina) para o
estilo mapa + `for_each` do `win-app-site`, em duas pastas com state próprio.

- **Mudança de representação, não de posse:** `state mv` cross-state recurso a
  recurso, não import — as máquinas já estavam no state. Backup de state antes
  de cada passo, plan `No changes` como critério a cada máquina.
- **nonprod primeiro** (ensaio barato), **prod-operationalflow por último.**
- **0 destroy / 0 replace** em todo o processo. Os 21 updates aplicados por
  ambiente foram cosméticos (tags explícitas migrando para `default_tags`,
  `tags_all` idêntico).
- **Egress 443/80** (R07) preservado — confirmado vivo na AWS após a limpeza do
  state antigo.
- As regras de SG separadas do estilo antigo (`aws_vpc_security_group_*_rule`)
  viraram blocos `egress`/`ingress` inline no novo SG (decisão "3b"). No
  `state mv` elas ficaram órfãs no state antigo e foram removidas com
  `state rm` (sem tocar a AWS — a regra segue viva, possuída pelo bloco inline).

---

## O MODELO de máquina

O bloco de exemplo para criar máquina nova vive agora em
`instances/_templates/`. Copie a pasta `_templates/`, não um arquivo solto, e
ajuste backend key, tfvars e o mapa `servers`.
