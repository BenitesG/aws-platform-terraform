##################################################################
#_____ S3 BUCKET (software compartilhado + backups) _____________#
##################################################################
# Estrutura lógica de prefixos dentro do bucket:
#   shared/              -> software comum (somente leitura para as instâncias)
#   <HOSTNAME>/          -> backup individual de cada instância (leitura/escrita)
resource "aws_s3_bucket" "this" {
  bucket = var.s3_bucket_name

  tags = {
    Name = var.s3_bucket_name
  }
}

# Bloqueia qualquer forma de acesso público.
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versionamento ligado (protege backups contra sobrescrita/exclusão acidental).
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Criptografia em repouso (SSE-S3 gerenciada pela AWS).
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# "Pastas" são apenas prefixos no S3; objetos-marcador criam a pasta shared/ e
# uma pasta por instância, úteis para visualização e para garantir que o prefixo
# exista antes do primeiro upload.
resource "aws_s3_object" "shared_prefix" {
  bucket       = aws_s3_bucket.this.id
  key          = "shared/"
  content_type = "application/x-directory"

  # Objetos S3 aceitam no máximo 10 tags; como o provider aplica 15 default_tags,
  # desligamos a herança nestes marcadores de pasta (que não precisam de tags).
  override_provider {
    default_tags {
      tags = {}
    }
  }
}

resource "aws_s3_object" "instance_prefix" {
  for_each = var.servers

  bucket       = aws_s3_bucket.this.id
  key          = "${each.key}/"
  content_type = "application/x-directory"

  override_provider {
    default_tags {
      tags = {}
    }
  }
}
