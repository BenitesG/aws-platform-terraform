##################################################################
# clientsg.tf - security group da integracao com o CLIENT (legacy ERP), NONPROD
#
# Um SG por AMBIENTE, carregando as regras do legacy ERP que valem para TODA maquina
# do parque. Anexado as instancias por attach_client_sg (main.tf).
#
# POR QUE ESTE SG EXISTE: as regras do legacy ERP nao sao de uma maquina, sao do
# INTERLOCUTOR. Toda maquina do parque fala com o legacy ERP. Mantidas por maquina,
# estariam duplicadas e faltando em outras, e revogar o acesso exigiria
# lembrar de varios lugares.
#
# O PRECO: acrescentar regra aqui concede acesso a TODAS as maquinas nonprod
# de uma vez. Regra que valha para UMA maquina so vai em
# integration_ingress_rules, no mapa daquela maquina.
#
# ESTRUTURA EM RECURSOS SEPARADOS (aws_vpc_security_group_*_rule), nao inline:
# a gestao e por regra, e o plan mostra exatamente qual muda. Isto casa com o
# state atual (instances/clientsg.tf) para o state mv fechar em No changes.
##################################################################

locals {
  nonprod_client_sg_name = "acme-swe-nonprod-client-sg"

  # ENTRADA do legacy ERP. NAO RENOMEAR CHAVE depois de aplicada - a chave entra no
  # endereco do recurso no state.
  erp_ingress_rules = {
    # SFTP/SCP do legacy ERP. Porta 65022 porque a golden image move o sshd para la.
    # O SG nao distingue SFTP de shell (mesma porta/protocolo); abrir a porta e
    # metade do caminho - o outro lado precisa da chave publica no
    # authorized_keys.
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

    # 443 e 80 de ENTRADA sao do legacy ERP, nao baseline. O baseline e a SAIDA 443/80
    # para 0.0.0.0/0, fixa no SG de cada maquina (main.tf).
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

  # SAIDA para o legacy ERP, ALEM da 443/80 fixa de cada maquina. A simetria com a
  # entrada esta correta (A36): comunicacao bidirecional nas mesmas portas.
  # R07 preservado: nenhuma porta de banco, destino unico em /32.
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

  # Application = "client": o SG nao pertence a nenhuma maquina. Sem RequestId
  # de proposito - nao nasce de um chamado unico.
  client_tags = {
    "acme:cost-allocation:Project"     = "erpflow"
    "acme:cost-allocation:Application" = "client"
    "mb:automation:Environment"        = "nonprod"
  }
}

resource "aws_security_group" "client" {
  name        = local.nonprod_client_sg_name
  vpc_id      = var.vpc_id
  description = "Regras da integracao com o client (legacy ERP) - nonprod"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.client_tags, {
    Name = local.nonprod_client_sg_name
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
    Name = "acme-swe-nonprod-client-in-${each.key}"
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
    Name = "acme-swe-nonprod-client-out-${each.key}"
  })
}
