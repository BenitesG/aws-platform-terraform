# _templates — molde para stack nova de instâncias

Esqueleto no estilo mapa + `for_each` (base: `win-app-site` / `linux-erp-site`),
para criar uma pasta de instâncias nova sem copiar de um stack real (e arrastar
as regras/tags dele junto).

## Como usar

1. Copie a pasta inteira:
   ```powershell
   Copy-Item -Recurse instances\_templates instances\meu-site
   ```
2. **`backend.tf`** — troque a `key` por uma única (`instances/<conta-env>/<stack>/...`).
3. **`terraform.tfvars`** — copie de `terraform.tfvars.example`, preencha.
4. Remova o que não se aplica:
   - Não fala com o legacy ERP? Apague `clientsg.tf`, as refs a `aws_security_group.client`
     no `main.tf`, e `erp_host_cidr`/`plc_host_cidr` do `variables.tf`.
5. `$env:AWS_PROFILE="acme-swe-prod"; terraform init; terraform fmt; terraform validate; terraform plan`

## Estrutura

| Arquivo | Conteúdo |
|---------|----------|
| `backend.tf` | backend S3 com key **placeholder** |
| `provider.tf` | versões pinadas + `default_tags` |
| `variables.tf` | infra comum + schema `servers` |
| `data.tf` | tópico SNS dos alarmes |
| `locals.tf` | tags por máquina (`per_server_tags`, `root_device_tags`) |
| `main.tf` | SG (egress 443/80 fixo + integração inline), instância, ENI |
| `alarms.tf` | 2 alarmes de status por máquina (A28) |
| `clientsg.tf` | SG do legacy ERP (opcional — remova se não usa) |
| `outputs.tf` | mapas chaveados por hostname |

## Decisões de arquitetura

Ver `docs/instances-decisoes.md` (ARQUIVO vs PASTA, quando criar state novo,
egress 443/80 / R07, state mv, etc.).
