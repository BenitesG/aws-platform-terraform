# linux-erp-site — NONPROD

Instâncias Linux do site legacy ERP, ambiente **nonprod**. State próprio, isolado do
prod (`linux-erp-site-prod`) e do `instances/` raiz.

## Arquitetura

Estilo **mapa + `for_each`** (base: `win-app-site`), adaptado ao que a Linux
tem de diferente do Windows:

- **Egress restrito a 443/80** (R07, movimento lateral) — fixo no SG de cada
  máquina, não `0.0.0.0/0`. Inviolável por construção (não é campo do schema).
- **Client SG do legacy ERP** compartilhada no ambiente, anexada por
  `attach_client_sg` (ver `clientsg.tf`).
- **Regras de integração por máquina** (`integration_*_rules`) — ex.: protocolo
  industrial do ATB apontando para o Studio 5000.
- **2 alarmes de status por máquina** (A28) via `for_each` (`alarms.tf`).
- **IMDSv2 obrigatório** (A05), `credit_specification = standard`.

Criar máquina nova = uma entrada no mapa `servers` do `terraform.tfvars`.

## Estrutura

| Arquivo | Conteúdo |
|---------|----------|
| `provider.tf` | `terraform{}` (versões, backend S3 key própria) e `provider` |
| `variables.tf` | schema `servers` + variáveis de infra + validações |
| `terraform.tfvars` | valores concretos: 3 máquinas nonprod no mapa |
| `data.tf` | tópico SNS dos alarmes |
| `main.tf` | SG (dynamic inline), instância, tag da ENI |
| `alarms.tf` | 2 alarmes de status por máquina |
| `clientsg.tf` | SG do legacy ERP nonprod (recursos de regra separados) |
| `outputs.tf` | mapas chaveados por hostname |

## Máquinas

| Hostname | Nome | Tipo | AMI | Papel |
|----------|------|------|-----|-------|
| `SWE-N-CAG01` | acme-swe-nonprod-cagworkbench | t4g.small | arm_docker | bancada |
| `SWE-N-OPFLOW01` | acme-swe-nonprod-operationalflow | t4g.small | arm (base) | dev integração legacy ERP |
| `SWE-N-ATB01` | acme-swe-nonprod-atb | t4g.small | arm_docker | simulador protocolo |

## Uso

```powershell
$env:AWS_PROFILE = "acme-swe-prod"   # backend não herda profile
terraform init
terraform fmt
terraform validate
terraform plan
# apply só com o plan revisado
```

## Pendências / notas

- **`tfvars` versionado com CIDRs reais** de infra de terceiro (decisão de
  26/10). Isolados no topo do arquivo.
- **`cw_agent_config` (SSM) NÃO está nesta pasta**: é recurso único
  compartilhado pelas 6 Linux (prod+nonprod). Permanece no state `instances/`.
  O agente CloudWatch lê o parâmetro direto do SSM por nome, não via Terraform.
- Esta pasta recebe as **3 máquinas nonprod via `state mv`** a partir de
  `instances/terraform.tfstate` — ver o procedimento de migração. O `plan` tem
  que fechar em **No changes** após cada `mv`.
