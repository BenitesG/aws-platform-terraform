##################################################################
#_____ IAM — acesso S3 escopado por instância __________________#
##################################################################
# Cada instância recebe sua própria role + instance profile. A policy concede:
#   - ListBucket restrito (via s3:prefix) a shared/* e <hostname>/*
#   - leitura em shared/*            (software compartilhado, somente leitura)
#   - leitura/escrita em <hostname>/* (backup individual)
# Como o prefixo de escrita muda por instância, não dá para compartilhar uma
# única role — por isso tudo abaixo usa for_each sobre var.servers.

# Trust policy comum: o serviço EC2 pode assumir a role.
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    sid     = "EC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  for_each = var.servers

  name               = "${each.key}-s3-access"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Policy de acesso ao S3, uma por instância (cada uma com seu próprio prefixo).
data "aws_iam_policy_document" "s3" {
  for_each = var.servers

  # ListBucket age sobre o ARN do bucket; a condition s3:prefix restringe a
  # listagem apenas às pastas shared/ e da própria instância.
  statement {
    sid       = "ListOwnAndShared"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["shared/*", "shared", "${each.key}/*", each.key]
    }
  }

  # Software compartilhado: somente leitura.
  statement {
    sid       = "ReadShared"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/shared/*"]
  }

  # Backup individual: leitura, escrita e remoção dentro do próprio prefixo.
  statement {
    sid    = "ReadWriteOwn"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.this.arn}/${each.key}/*"]
  }
}

resource "aws_iam_role_policy" "s3" {
  for_each = var.servers

  name   = "s3-scoped-access"
  role   = aws_iam_role.instance[each.key].id
  policy = data.aws_iam_policy_document.s3[each.key].json
}

resource "aws_iam_instance_profile" "instance" {
  for_each = var.servers

  name = "${each.key}-profile"
  role = aws_iam_role.instance[each.key].name
}

# Habilita acesso via SSM (Session Manager / Fleet Manager) sem precisar de RDP
# exposto nem da chave .pem. O SSM Agent já vem instalado no Windows Server 2025.
resource "aws_iam_role_policy_attachment" "ssm" {
  for_each = var.servers

  role       = aws_iam_role.instance[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
