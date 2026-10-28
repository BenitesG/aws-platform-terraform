# linux-erp-site — PROD

Instâncias Linux do site legacy ERP, ambiente **prod**. State próprio, isolado do
nonprod (`linux-erp-site-nonprod`) e do `instances/` raiz.

## Arquitetura

Idêntica à nonprod (ver README de lá). Estilo mapa + `for_each`, egress
restrito a 443/80 (R07), client SG do legacy ERP, 2 alarmes de status por máquina
(A28), IMDSv2, credit standard.

**Diferença da nonprod:** esta pasta hospeda o `aws_ssm_parameter.cw_agent_config`
(`alarms.tf`) — config do agente CloudWatch, recurso **único** compartilhado
pelas 6 Linux (prod + nonprod). Mora aqui por ser Linux e por prod ser o lar
mais estável; a nonprod não o referencia (o agente lê do SSM por nome).

## Estrutura

| Arquivo | Conteúdo |
|---------|----------|
| `provider.tf` | `terraform{}` (versões, backend S3 key própria) e `provider` |
| `variables.tf` | schema `servers` + variáveis de infra + validações |
| `terraform.tfvars` | valores concretos: 3 máquinas prod no mapa |
| `data.tf` | tópico SNS dos alarmes |
| `main.tf` | SG (dynamic inline), instância, tag da ENI |
| `alarms.tf` | 2 alarmes de status por máquina + `cw_agent_config` (SSM) |
| `clientsg.tf` | SG do legacy ERP prod (recursos de regra separados) |
| `outputs.tf` | mapas chaveados por hostname |

## Máquinas

| Hostname | Nome | Tipo | Papel |
|----------|------|------|-------|
| `SWE-P-CAG01` | acme-swe-prod-cagworkbench | t4g.medium | bancada |
| `SWE-P-OPFLOW01` | acme-swe-prod-operationalflow | t4g.large | **produção integração legacy ERP** |
| `SWE-P-ATB01` | acme-swe-prod-atb | t4g.large | simulador protocolo |

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

- `tfvars` versionado com CIDRs reais de infra de terceiro (decisão 26/10).
- Migração via `state mv` a partir de `instances/terraform.tfstate`. Ordem:
  prod-cagworkbench → prod-atb → **prod-operationalflow por ÚLTIMO, com janela**.
- **`SWE-P-OPFLOW01` (operationalflow)**: no 3b, o egress 443/80 é recriado no
  apply pós-mv — janela de segundos sem a regra de saída. Fazer com a máquina
  **parada** (o erp-vmwaker a cicla) ou em janela combinada. É a de ~1.500
  conexões/dia.
- `cw_agent_config` migra junto com esta leva (recurso único, estava no state
  `instances/`).
