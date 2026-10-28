##################################################################
# linux-erp-site (NONPROD) - instancias Linux do site legacy ERP
#
# Estilo mapa + for_each (base: win-app-site / @contributor), ADAPTADO para o
# que a Linux tem de diferente do Windows:
#   - egress RESTRITO a 443/80 (R07, movimento lateral) - NAO 0.0.0.0/0
#   - client SG do legacy ERP compartilhada, anexada via extra_security_group_ids
#   - regras de integracao por maquina (integration_*_rules)
#   - 2 alarmes de status por maquina (A28) - ver alarms.tf
#   - IMDSv2 obrigatorio (A05), credit standard
#
# AS TRES COISAS QUE TORNAM A INSTANCIA INACESSIVEL SE ERRADAS:
#   1. subnet - precisa ser a PRIVADA-D (as publicas nao tem saida, SSM nao
#      registra). Instancia NAO muda de subnet: errar = recriar
#   2. instance_profile - sem ele o agente SSM nao registra, e nao ha key pair
#      nem porta 22 como entrada alternativa
#   3. metadata (IMDSv2) - o agente obtem credencial pelo IMDS
##################################################################

##################################################################
#_____ SECURITY GROUP (um por instancia, dynamic inline) ________#
##################################################################
# UM SG POR MAQUINA (decisao de 16/10): SG compartilhado e REGRA compartilhada.
# A unica excecao deliberada e o client SG do legacy ERP (clientsg.tf), anexado por
# extra_security_group_ids - porque a regra do legacy ERP e do INTERLOCUTOR, nao da
# maquina.
#
# REGRAS INLINE (dynamic), nao recursos separados: decisao 3b. O Terraform
# assume posse de TODAS as regras deste SG - o que e seguro aqui porque TODAS
# as regras do legacy ERP foram centralizadas no client SG; este SG so tem o baseline
# 443/80 e as de protocolo industrial, todas no codigo.
resource "aws_security_group" "this" {
  for_each = var.servers

  name        = "${each.value.name}-sg"
  description = "Security group da instancia ${each.value.name}"
  vpc_id      = var.vpc_id

  # --- EGRESS 443/80 FIXO (R07) - inviolavel por construcao ---
  # Mitiga MOVIMENTO LATERAL: com o peering ativo, a instancia nao alcanca
  # banco da producao em 3306/1433/5432. NAO e 0.0.0.0/0 aberto - e o range do
  # peering (172.31.0.0/16) esta DENTRO do 0.0.0.0/0, entao egress aberto
  # desfaria a mitigacao pela rota do peering, nao pelo NAT.
  # DNS (Route 53 Resolver) e NTP (169.254.169.123) nao sao filtrados por SG.
  egress {
    description = "APIs AWS, SSM, npm, APIs do Google"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Repositorios apt do Ubuntu (pacotes assinados por GPG)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # --- EGRESS de integracao especifico da maquina (ex.: ATB mestre) ---
  dynamic "egress" {
    for_each = each.value.integration_egress_rules
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.ip_protocol
      cidr_blocks = [egress.value.cidr_ipv4]
    }
  }

  # --- INGRESS: vazio por padrao (A18). Cada excecao e declarada em
  # integration_ingress_rules (ex.: ATB escravo). Acesso normal e por SSM, que
  # abre a conexao de dentro para fora. ---
  dynamic "ingress" {
    for_each = each.value.integration_ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.ip_protocol
      cidr_blocks = [ingress.value.cidr_ipv4]
    }
  }

  lifecycle {
    # Obrigatorio quando o SG e substituido: sem isto o destroy do antigo falha
    # com DependencyViolation (ainda anexado a ENI) e o apply morre no meio.
    create_before_destroy = true
  }

  tags = merge(local.per_server_tags[each.key], {
    Name = "${each.value.name}-sg"
  })
}

##################################################################
#_____ INSTANCIAS _______________________________________________#
##################################################################
resource "aws_instance" "this" {
  for_each = var.servers

  ami           = each.value.ami_id
  instance_type = each.value.instance_type
  subnet_id     = var.private_subnet_id

  # SG proprio + client SG do legacy ERP (clientsg.tf) quando attach_client_sg.
  vpc_security_group_ids = concat(
    [aws_security_group.this[each.key].id],
    each.value.attach_client_sg ? [aws_security_group.client.id] : [],
  )

  associate_public_ip_address = false
  iam_instance_profile        = var.instance_profile
  key_name                    = each.value.key_name != "" ? each.value.key_name : null
  disable_api_termination     = each.value.enable_termination_protection

  # IMDSv2 obrigatorio (A05). required recusa consulta sem token (anti-SSRF);
  # hop_limit 1 impede container na instancia de alcancar o IMDS (R18).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = each.value.root_volume_size
    encrypted             = true
    delete_on_termination = true

    # root_block_device NAO herda default_tags: precisa do conjunto completo.
    tags = merge(local.root_device_tags[each.key], {
      Name = "${each.value.name}-root"
    })
  }

  # Hostname no primeiro boot (a limpeza da imagem zerou o estado do cloud-init).
  # Hostname = a chave do mapa.
  user_data = <<-EOT
    #cloud-config
    hostname: ${each.key}
    preserve_hostname: false
  EOT

  user_data_replace_on_change = false

  lifecycle {
    # "ami" e ForceNew: a variavel ami_id acompanha a imagem ATUAL da linhagem
    # para maquina NOVA nascer em dia, mas a existente NAO deve ser recriada.
    # Trocar a imagem de uma existente e ato explicito:
    #   terraform apply -replace='aws_instance.this["SWE-N-CAG01"]'
    ignore_changes = [ami]
  }

  # Modo standard (nao unlimited): em carga previsivel, unlimited e conta
  # surpresa quando a CPU estoura o credito.
  credit_specification {
    cpu_credits = "standard"
  }

  tags = merge(local.per_server_tags[each.key], {
    Name = each.value.name
  })
}

##################################################################
#_____ TAG Name DA ENI PRIMARIA _________________________________#
##################################################################
# aws_instance nao tem argumento para taguear a ENI primaria que cria
# implicitamente. aws_ec2_tag fecha a lacuna sem recriar a instancia.
resource "aws_ec2_tag" "eni_name" {
  for_each = var.servers

  resource_id = aws_instance.this[each.key].primary_network_interface_id
  key         = "Name"
  value       = "${each.value.name}-eni"
}
