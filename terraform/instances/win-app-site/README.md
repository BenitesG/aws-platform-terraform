# win-app-site

Infraestrutura Terraform do site App (System Platform / APP) em Windows Server 2025. Provisiona
as instâncias EC2 do ambiente, cada uma com disco raiz (C:) e, quando aplicável, um ou mais discos
de dados (E:, F:, ...), todos criptografados.

## Arquitetura

- **AMI:** Windows Server 2025 resolvida via SSM Parameter público da AWS (`data.tf`). As
  instâncias usam `lifecycle.ignore_changes = [ami]` para não serem recriadas quando a AWS publica
  uma imagem nova.
- **Servidores:** descritos de forma orientada a dados no mapa `servers` em `terraform.tfvars`,
  chaveados por hostname. Cada servidor é um objeto independente; campos omitidos usam o default
  do schema em `variables.tf` (`instance_type` default `t3a.micro`, root 60 GB, `gp3`).
- **Discos de dados:** modelados como lista de objetos (`data_disks`) por servidor. Um `local`
  (`locals.tf`) achata (servidor x disco) em uma coleção única para criar `aws_ebs_volume` e
  `aws_volume_attachment` com `for_each`, suportando 0, 1 ou N discos sem mudar o contrato.

## Estrutura

```
provider.tf        # terraform{}, provider AWS (~> 6.0), backend S3
variables.tf       # Contratos de entrada (aws_configs, network, s3_bucket_name, servers)
terraform.tfvars   # Valores concretos: tags, rede e os servidores
data.tf            # AMI Windows Server 2025 via SSM; VPC derivada da subnet
locals.tf          # Achatamento servidor x disco de dados
main.tf            # Key pairs, EC2, volumes EBS e attachments
security.tf        # Security group por instância (regras vêm de cada servidor)
iam.tf             # Role + instance profile por instância (acesso S3 + SSM)
s3.tf              # Bucket de software compartilhado e backups
outputs.tf         # IDs e IPs das instâncias, IDs dos volumes, SGs, roles
keys/              # Chaves públicas SSH (.pub); a privada .pem NÃO vai pro repo
templates/
  userdata.ps1.tftpl  # user_data PowerShell (define hostname)
```

## Uso

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

## Pendências antes do apply

- Preencher `network.subnet_id` (e `vpc_id` se necessário).
- Definir `key_name` / `instance_profile` por servidor no `servers`, se for usar.
- Confirmar o tamanho do disco E: do `WIN-APP-HS11` (veio truncado na especificação original).
- Ajustar `bucket` / `key` / `dynamodb_table` do backend em `provider.tf` conforme a conta.

## Adicionar um segundo disco a um servidor

Basta adicionar outro objeto em `data_disks` com um `device_name` distinto:

```hcl
WIN-APP-GR11 = {
  role = "App Repository & License Server"
  data_disks = [
    { size = 150, device_name = "xvdf" }, # E:
    { size = 200, device_name = "xvdg" }, # F:
  ]
}
```

## Guia de uso do S3 (devs / operadores)

Cada instância tem acesso a um bucket S3 compartilhado (`win-app-site`) **sem precisar de
credenciais** — o acesso vem da IAM role anexada à própria máquina (instance profile). Basta usar a
AWS CLI de dentro da instância.

### Propósito das pastas

| Pasta | Quem acessa | Permissão | Para quê |
|-------|-------------|-----------|----------|
| `shared/` | todas as instâncias | somente leitura | baixar software/instaladores comuns do site |
| `<HOSTNAME>/` | só a própria instância | leitura e escrita | backup individual de arquivos daquela máquina |

Ou seja: a `WIN-APP-GR11` lê de `shared/` e lê/escreve em `WIN-APP-GR11/`, mas **não** enxerga a
pasta `WIN-APP-HS11/` de outra máquina. Esse isolamento é intencional.

### Pré-requisitos (uma vez por máquina)

A AWS CLI já costuma vir instalada nas imagens. Confirme com:

```powershell
aws --version
```

Se o comando não for reconhecido logo após instalar, abra um **novo** terminal (o PATH só é
recarregado em sessões novas). Não rode `aws configure` nem configure chaves de acesso — o acesso é
pela role. Para confirmar qual identidade está em uso:

```powershell
aws sts get-caller-identity
# O campo "Arn" deve conter: assumed-role/<HOSTNAME>-s3-access/<id-da-instancia>
```

### Listar (ls)

```powershell
# Conteúdo da pasta compartilhada
aws s3 ls s3://win-app-site/shared/

# Conteúdo da pasta de backup da própria máquina (troque pelo hostname real)
aws s3 ls s3://win-app-site/WIN-APP-GR11/
```

> Use sempre a barra final (`shared/`). Sem a barra, o S3 interpreta como outro prefixo e retorna
> Access Denied.

### Baixar de shared/ (download)

```powershell
# Baixar um arquivo específico para a pasta atual
aws s3 cp s3://win-app-site/shared/App-setup.exe .

# Baixar para um caminho específico
aws s3 cp s3://win-app-site/shared/App-setup.exe C:\temp\App-setup.exe

# Baixar uma pasta inteira (recursivo)
aws s3 cp s3://win-app-site/shared/ C:\temp\shared\ --recursive
```

### Enviar backup para a pasta da própria máquina (upload)

```powershell
# Enviar um arquivo para a pasta de backup desta máquina
aws s3 cp E:\backup\app.zip s3://win-app-site/WIN-APP-GR11/

# Enviar com um nome/subpasta no destino (data no nome ajuda a versionar)
aws s3 cp E:\backup\app.zip s3://win-app-site/WIN-APP-GR11/2026-10-23/app.zip

# Enviar uma pasta inteira de backup (recursivo)
aws s3 cp E:\backup\ s3://win-app-site/WIN-APP-GR11/ --recursive
```

> O bucket tem versionamento ligado, então sobrescrever um arquivo mantém a versão anterior
> recuperável. Ainda assim, prefira nomear backups com data para facilitar.

### Erros comuns

| Mensagem | Causa provável |
|----------|----------------|
| `'aws' is not recognized` | CLI recém-instalada; abra um novo terminal para recarregar o PATH |
| `AccessDenied` ao acessar `<outro-host>/` | esperado: cada máquina só acessa a própria pasta e `shared/` |
| `AccessDenied` em `shared` (sem barra) | use a barra final: `shared/` |
| comando trava / timeout | a subnet pode não ter rota de saída para o S3 (NAT ou VPC endpoint) |
