# Bootstrap — o bucket de estado do Terraform

Cria o bucket S3 `acme-swe-prod-tfstate`, que guarda o estado das demais
configurações do repositório.

**Roda uma vez.** Depois disso você provavelmente não volta aqui, a não ser
para mudar algo no bucket.

---

## Por que existe um diretório só para isto

Problema circular: o bucket que guarda o estado não pode ser gerenciado pelo
estado que ainda não existe.

A saída é fazer em **dois passos** — rodar com estado local primeiro, depois
mover o estado para dentro do bucket recém-criado. O resultado é um bucket
gerenciado por Terraform cujo estado mora dentro dele próprio. Parece
paradoxal, mas a ordem resolve. É o padrão que a maioria usa.

---

## Execução

```powershell
$env:AWS_PROFILE = "acme-swe-prod"
cd bootstrap
```

### Passo 1 — estado local

Este diretório **não tem** bloco `backend` neste momento, de propósito.

```powershell
terraform init      # sem backend: estado fica LOCAL
terraform plan      # confira: 5 to add
terraform apply
```

Vale abrir o `terraform.tfstate` que apareceu na pasta e dar uma olhada. É o
"caderno de obra" do Terraform: a ligação entre o nome que você deu no código
e o objeto real na AWS. Ver o conteúdo esclarece mais que explicação.

### Passo 2 — migrar para o bucket

Crie `backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket       = "acme-swe-prod-tfstate"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
```

```powershell
terraform init -migrate-state    # responda "yes"
terraform plan                   # tem de dizer "No changes"
```

O `No changes` é a prova de que o estado novo está íntegro e o Terraform
conseguiu ler do S3. Só então apague o resíduo local:

```powershell
Remove-Item terraform.tfstate, terraform.tfstate.backup -ErrorAction SilentlyContinue
```

---

## O que você precisa saber

### "Um bucket" são cinco recursos

Versionamento, criptografia, bloqueio público e lifecycle **não são campos do
bucket**: são recursos separados que apontam para ele. O Terraform espelha a
API do S3, onde `CreateBucket`, `PutBucketVersioning`, `PutBucketEncryption`,
`PutPublicAccessBlock` e `PutBucketLifecycleConfiguration` são operações
distintas. O formulário único do console esconde isso.

Se encontrar exemplo na internet com `versioning { }` dentro do
`aws_s3_bucket`, é material antigo — o provider mudou.

### O bloco `backend` não aceita variável

Nada de `var.*` ali. Tem de ser literal. É limitação do Terraform.

E ele **não herda** o `profile` do bloco `provider`: é inicializado antes, com
a própria cadeia de credenciais. Daí a variável de ambiente `AWS_PROFILE`.

### `use_lockfile` exige Terraform >= 1.10

Trava o estado usando o próprio S3, dispensando DynamoDB. Em versão anterior,
trocar por `dynamodb_table` e criar a tabela.

A trava evita que dois `apply` simultâneos — você e a esteira, por exemplo —
leiam o mesmo estado, os dois decidam criar, e o estado fique inconsistente.

### O versionamento aqui é obrigatório

Cada `apply` grava uma versão nova do estado. Se um estado corromper, ou se
alguém rodar um `destroy` indevido, dá para restaurar a versão anterior e
recuperar o controle dos recursos. **É o desfazer do Terraform.**

Por isso **não** há regra de expiração de versão antiga neste bucket, ao
contrário do bucket de flow logs. Cada versão tem poucos KB, e apagar versão
antiga jogaria fora a capacidade de recuperação.

### `prevent_destroy` no bucket

Impede que um `terraform destroy` apague o bucket que contém o próprio estado
desta configuração — o destroy se auto-sabotaria, apagando o registro no meio
da operação e deixando recursos órfãos.

### Blocos `moved`

Há blocos `moved` no `main.tf`, remanescentes da renomeação dos
identificadores de português para inglês. Eles dizem ao Terraform "este
recurso trocou de nome, é o mesmo objeto" — sem eles o Terraform concluiria
que o antigo foi removido e tentaria **destruir e recriar** o bucket.

**Podem ser removidos**, já que o `apply` que os consumiu foi bem-sucedido.
Ficaram como exemplo do mecanismo.

### O bucket não está no `.gitignore`, o estado está

`*.tfstate` e `*.tfvars` nunca vão para o git. O `.terraform.lock.hcl` vai.
