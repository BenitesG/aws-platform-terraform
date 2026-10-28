# ---------------------------------------------------------------------------
# bootstrap/main.tf
#
# O bucket que guarda o estado do Terraform.
#
# Note que "um bucket" sao CINCO recursos: o bucket mais quatro de
# configuracao. Versionamento, criptografia, bloqueio publico e lifecycle nao
# sao campos do bucket: sao recursos separados que apontam para ele. Versoes
# antigas do provider aceitavam tudo inline, e mudou - se encontrar exemplo na
# internet com "versioning { }" dentro do aws_s3_bucket, e material
# desatualizado.
#
# Convencao do repositorio: IDENTIFICADORES EM INGLES, comentarios e tags em
# portugues.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = "acme-swe-prod-tfstate"

  # Impede que um "terraform destroy" apague o bucket que contem o proprio
  # estado desta configuracao. Sem isso, o destroy se auto-sabota: apaga o
  # registro no meio da operacao e deixa recursos orfaos.
  lifecycle {
    prevent_destroy = true
  }

  # Chave de tag com dois-pontos PRECISA estar entre aspas em HCL. Sem aspas,
  # o parser le "mb" como nome do atributo e falha no init.
  tags = {
    Name      = "acme-swe-prod-tfstate"
    ManagedBy = "terraform"

    "acme:cost-allocation:Project"     = "best-practices"
    "acme:cost-allocation:Application" = "terraform-state"
    "acme:cost-allocation:Department"  = "swe"
    "acme:cost-allocation:CostCenter"  = "h370infra"
    "mb:automation:Environment"        = "prod"

    # "sensivel" de proposito: o state pode passar a conter valor sensivel em
    # texto claro se o Terraform criar recurso com segredo (senha inicial de
    # RDS, por exemplo). Nascer na classificacao mais alta evita precisar
    # lembrar de subir depois.
    "mb:data:DataClassification" = "sensivel"

    Owner      = "platform-team@acme.example"
    ChargeType = "dedicated"
  }
}

# Versionamento: cada apply grava uma versao nova do estado. Se um estado
# corromper, ou se alguem rodar um destroy indevido, da para restaurar a
# versao anterior e recuperar o controle dos recursos. E o desfazer do
# Terraform - por isso aqui o versionamento e obrigatorio, nao opcional.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (AES256), nao KMS. Chave gerenciada pela AWS evita o custo e o ponto
# de falha de uma CMK - mesmo raciocinio da decisao do cartao A04.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Apenas higiene: limpa upload interrompido, que fica cobrado e nao aparece
# na listagem normal de objetos.
#
# NAO colocar expiracao de versao antiga aqui. No bucket de flow logs a
# retencao faz sentido porque o volume cresce; aqui cada versao tem poucos KB,
# e apagar versao antiga joga fora a capacidade de recuperacao.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "abortar-multipart-7d"
    status = "Enabled"

    # filter vazio nao e descuido: e como se diz "aplica a todos os objetos".
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# Blocos "moved": renomeacao sem destruir nada
#
# O nome do recurso ("estado") e a CHAVE no state. Mudar para "state" sem
# avisar faria o Terraform concluir que o antigo foi removido e o novo precisa
# ser criado - ou seja, tentaria DESTRUIR E RECRIAR o bucket.
#
# O bloco "moved" diz: "este recurso trocou de nome, e o mesmo objeto". O
# proximo apply so atualiza o state, sem tocar na AWS. O plan mostra as
# mudancas como "moved", nao como create/destroy - confira antes de aplicar.
#
# Depois do apply bem-sucedido estes blocos podem ser removidos do arquivo.
# ---------------------------------------------------------------------------

moved {
  from = aws_s3_bucket.estado
  to   = aws_s3_bucket.state
}

moved {
  from = aws_s3_bucket_versioning.estado
  to   = aws_s3_bucket_versioning.state
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.estado
  to   = aws_s3_bucket_server_side_encryption_configuration.state
}

moved {
  from = aws_s3_bucket_public_access_block.estado
  to   = aws_s3_bucket_public_access_block.state
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.estado
  to   = aws_s3_bucket_lifecycle_configuration.state
}

# ---------------------------------------------------------------------------
# outputs: valores que o Terraform imprime ao final do apply.
# ---------------------------------------------------------------------------

output "state_bucket" {
  description = "Nome do bucket de estado, para usar no bloco backend"
  value       = aws_s3_bucket.state.id
}
