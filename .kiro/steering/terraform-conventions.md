---
inclusion: fileMatch
fileMatchPattern: '**/*.{tf,tfvars}'
---

# Convenções Terraform (base: win-app-site)

Guia de estilo e boas práticas para o código Terraform deste repositório. Combina as
recomendações oficiais da HashiCorp (Style Guide / Module Development) com os padrões já
estabelecidos na instância de referência `instances/win-app-site`. Ao criar ou editar
`.tf`/`.tfvars`, siga estas convenções e espelhe os padrões dessa instância.

## Princípios gerais (HashiCorp)

- **Sempre rode `terraform fmt`** antes de commitar. Indentação de 2 espaços, alinhamento de `=`
  em blocos de atribuições consecutivas.
- **Rode `terraform validate`** depois de `fmt` e antes de `plan`. Fluxo padrão:
  `init → fmt → validate → plan → apply`.
- **Nomes em `snake_case`** para recursos, variáveis, outputs e locals (minúsculas, `_` como
  separador). Nunca repita o tipo do recurso no nome (use `aws_instance "this"`, não
  `aws_instance "instance"`).
- **Use `this` como nome** quando há um único recurso daquele tipo no arquivo/módulo; use nomes
  descritivos quando há vários do mesmo tipo.
- **Fixe versões**: `required_version` no bloco `terraform{}` e `version` com pessimista (`~>`)
  em cada provider. Commite o `.terraform.lock.hcl`.
- **Prefira recursos a dados hardcoded**: resolva valores dinâmicos via `data` sources (ex.: AMI
  via SSM Parameter) em vez de colar IDs no código quando possível.
- **Comente o "porquê", não o "o quê"**. Explique decisões não óbvias (ex.: por que
  `ignore_changes`, por que `for_each` em vez de `count`).

## Organização de arquivos

Separe por responsabilidade, um arquivo por domínio (padrão desta instância):

| Arquivo | Conteúdo |
|---------|----------|
| `provider.tf` | bloco `terraform{}` (versões, backend) e `provider` |
| `variables.tf` | contratos de entrada (schema + validações + descrições) |
| `terraform.tfvars` | valores concretos do ambiente |
| `data.tf` | data sources (AMI, subnet, policy documents) |
| `locals.tf` | transformações e valores derivados |
| `main.tf` | recursos principais do domínio |
| `security.tf` / `iam.tf` / `s3.tf` | recursos agrupados por serviço |
| `outputs.tf` | saídas do módulo/stack |
| `README.md` | arquitetura, estrutura, uso e pendências |

Cabeçalhos de seção usam o padrão de banner já adotado:

```hcl
##################################################################
#_____ TÍTULO DA SEÇÃO __________________________________________#
##################################################################
```

## Variáveis (`variables.tf`)

- **Toda variável tem `type` e `description`.** A descrição explica o propósito em PT-BR.
- **Modele entradas estruturadas como `object()`** e agrupe coleções em `map(object())` chaveado
  por uma chave de negócio estável (nesta instância, o `hostname`). Mapas são preferíveis a listas
  para `for_each` porque dão endereços de state estáveis.
- **Use `optional(tipo, default)`** para campos com padrão, de modo que o resource consuma
  `each.value.*` diretamente, sem `merge` com defaults externos. Exemplo real:

  ```hcl
  instance_type    = optional(string, "t3a.micro")
  root_volume_size = optional(number, 60)
  volume_type      = optional(string, "gp3")
  data_disks       = optional(list(object({ ... })), [])
  ```

- **Valide entradas** com blocos `validation` e mensagens de erro claras (em PT-BR). Padrões já
  usados: regex de região AWS, regex de nome de bucket S3, chave do mapa só com `[A-Z0-9]`,
  tamanho de disco `> 0`. Prefira `alltrue([for ...])` para validar coleções.
- Defina `default` apenas quando o valor fizer sentido fora do `.tfvars` (ex.: `s3_bucket_name`).

## Padrões de recurso (`main.tf` e afins)

- **Prefira `for_each` a `count`.** `for_each` sobre um mapa dá endereços de state estáveis e
  evita recriação em cascata ao adicionar/remover elementos. Todos os recursos por servidor
  nesta instância usam `for_each = var.servers`.
- **Achate relações N:N em `locals`** quando precisar de `for_each` sobre o produto de duas
  coleções. Padrão desta instância (servidor × disco), com chave composta única:

  ```hcl
  locals {
    data_disks = merge([
      for host, cfg in var.servers : {
        for disk in cfg.data_disks :
        "${host}:${disk.device_name}" => { host = host, size = disk.size, ... }
      }
    ]...)
  }
  ```

- **Use `dynamic` blocks** para blocos repetíveis dirigidos por dados (ex.: `ingress`/`egress`
  de um security group vindos de `each.value.ingress`).
- **Resolva valores "vencedor"/fallback com ternário**: valor explícito na entrada vence, senão
  cai no default derivado. Ex.: `each.value.ami_id != null ? each.value.ami_id : data....value`
  e `key_name = each.value.key_name != null ? each.value.key_name : each.key`.
- **`lifecycle { ignore_changes = [...] }`** para atributos que mudam fora do Terraform e não
  devem recriar recursos (ex.: `ami` resolvida via SSM). Sempre comente o motivo.

## Segurança (default-seguro)

- **Criptografia sempre ligada**: `encrypted = true` em todo `root_block_device` e
  `aws_ebs_volume`; SSE em buckets S3 (`aws_s3_bucket_server_side_encryption_configuration`).
- **Bloqueie acesso público a buckets** com `aws_s3_bucket_public_access_block` (todos os quatro
  flags `true`).
- **Versionamento ligado** em buckets que guardam dados/backup.
- **Menor privilégio no IAM**: policies escopadas por recurso/prefixo (ex.: `s3:prefix` em
  `ListBucket`, ARNs com prefixo `<hostname>/*`). Uma role + instance profile por instância
  quando o escopo difere entre elas.
- **Acesso administrativo via SSM**, não RDP/SSH exposto: anexe
  `AmazonSSMManagedInstanceCore` e mantenha `ingress` default vazio. `egress` liberado apenas
  o necessário para o SSM funcionar.
- **Nunca** comite segredos no repo nem no state. Chaves privadas (`.pem`) ficam fora do
  Terraform; só a chave pública (`.pub`) é referenciada via `file()`. Mantenha-as no
  `.gitignore`.

## Backend e state

- **Backend remoto S3** com `encrypt = true` e lock nativo (`use_lockfile = true`, sem DynamoDB).
- A `key` do state segue o caminho lógico do ambiente, ex.:
  `instances/<conta-env>/<stack>/terraform.tfstate`.
- **Nunca** edite o state à mão nem comite `terraform.tfstate` / diretórios `.terraform/`.

## Tags

- **Tags comuns via `default_tags`** no provider (aplicadas a todos os recursos que suportam
  tags). Centralize-as em `aws_configs.default_tags` no `.tfvars`.
- **Tags específicas do recurso** (ex.: `Name`, `Role`) no próprio bloco do recurso.
- Atenção a limites do serviço: objetos S3 aceitam no máximo 10 tags — use
  `override_provider { default_tags { tags = {} } }` em marcadores de pasta para não herdar as
  15 default_tags.

## Outputs (`outputs.tf`)

- **Todo output tem `description`.** Exponha IDs, ARNs, IPs e nomes úteis para consumo externo
  ou debugging.
- Para recursos criados com `for_each`, exponha como mapa chaveado pela mesma chave:
  `value = { for k, v in aws_instance.this : k => v.id }`.

## `.tfvars`

- Mantenha o mesmo banner de seções do resto do código.
- Comente campos que dependem de confirmação com `# TODO:` e o que falta decidir.
- Deixe exemplos de blocos futuros comentados (ex.: servidores ainda não provisionados) para
  servir de template — mantendo o contrato explícito.

## Documentação

- Todo stack/módulo tem `README.md` com: **Arquitetura**, **Estrutura** (tabela de arquivos),
  **Uso** (comandos), **Pendências antes do apply** e guias operacionais relevantes.
