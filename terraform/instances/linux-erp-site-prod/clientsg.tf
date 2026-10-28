##################################################################
# clientsg.tf - security group da integracao com o CLIENT (legacy ERP), PROD
#
# Um SG por AMBIENTE, carregando as regras do legacy ERP que valem para TODA maquina
# do parque. Anexado as instancias por attach_client_sg (main.tf).
#
# MESMAS REGRAS QUE O NONPROD HOJE, por pedido - e sao dois SGs de proposito,
# nao um compartilhado. Serem iguais hoje nao e invariante: com SG unica,
# alterar a regra para testar em nonprod aplicaria em producao no mesmo apply,
# e perde-se o unico lugar onde o erro e barato.
#
# O PRECO: acrescentar regra aqui concede acesso a TODAS as maquinas prod de
# uma vez. Regra que valha para UMA maquina so vai em
# integration_ingress_rules, no mapa daquela maquina.
#
# ESTRUTURA EM RECURSOS SEPARADOS, nao inline: casa com o state atual
# (instances/clientsg.tf -> prod_client) para o state mv fechar em No changes.
##################################################################

locals {
  prod_client_sg_name = "acme-swe-prod-client-sg"

  # ENTRADA do legacy ERP. NAO RENOMEAR CHAVE depois de aplicada.
  erp_ingress_rules = {
    erp_sftp = {
      description = "legacy ERP file transfer ssh"
      ip_protocol = "tcp"
      from_port   = 65022
      to_port     = 65022
      cidr_ipv4   = var.erp_host_cidr
    }

    erp_hub = {
      description = "erphub"
      ip_protocol = "tcp"
      from_port   = 5020
      to_port     = 5023
      cidr_ipv4   = var.erp_host_cidr
    }

    google_hub = {
      description = "googlehub (ip legacy ERP)"
      ip_protocol = "tcp"
      from_port   = 5160
      to_port     = 5161
      cidr_ipv4   = var.erp_host_cidr
    }

    erp_tcp_443 = {
      description = "legacy ERP https"
      ip_protocol = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_ipv4   = var.erp_host_cidr
    }

    erp_tcp_80 = {
      description = "legacy ERP http"
      ip_protocol = "tcp"
      from_port   = 80
      to_port     = 80
      cidr_ipv4   = var.erp_host_cidr
    }
  }

  erp_egress_rules = {
    erp_sftp = {
      description = "legacy ERP file transfer ssh"
      ip_protocol = "tcp"
      from_port   = 65022
      to_port     = 65022
      cidr_ipv4   = var.erp_host_cidr
    }

    erp_hub = {
      description = "erphub"
      ip_protocol = "tcp"
      from_port   = 5020
      to_port     = 5023
      cidr_ipv4   = var.erp_host_cidr
    }

    google_hub = {
      description = "googlehub (ip legacy ERP)"
      ip_protocol = "tcp"
      from_port   = 5160
      to_port     = 5161
      cidr_ipv4   = var.erp_host_cidr
    }
  }

  client_tags = {
    "acme:cost-allocation:Project"     = "erpflow"
    "acme:cost-allocation:Application" = "client"
    "mb:automation:Environment"        = "prod"
  }
}

resource "aws_security_group" "client" {
  name        = local.prod_client_sg_name
  vpc_id      = var.vpc_id
  description = "Regras da integracao com o client (legacy ERP) - prod"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.client_tags, {
    Name = local.prod_client_sg_name
  })
}

resource "aws_vpc_security_group_ingress_rule" "client" {
  for_each = local.erp_ingress_rules

  security_group_id = aws_security_group.client.id
  description       = each.value.description
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = each.value.cidr_ipv4

  tags = merge(local.client_tags, {
    Name = "acme-swe-prod-client-in-${each.key}"
  })
}

resource "aws_vpc_security_group_egress_rule" "client" {
  for_each = local.erp_egress_rules

  security_group_id = aws_security_group.client.id
  description       = each.value.description
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = each.value.cidr_ipv4

  tags = merge(local.client_tags, {
    Name = "acme-swe-prod-client-out-${each.key}"
  })
}
