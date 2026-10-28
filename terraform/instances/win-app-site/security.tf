##################################################################
#_____ SECURITY GROUPS (um por instância) _______________________#
##################################################################
# Um SG por servidor, com regras definidas por instância em var.servers.
# Nome default = hostname (customizável via security_group_name).
# Ingress default vazio (acesso via SSM); egress default libera toda a saída.
resource "aws_security_group" "this" {
  for_each = var.servers

  name        = each.value.security_group_name != null ? each.value.security_group_name : each.key
  description = "SG for instance ${each.key} (${each.value.role})"
  vpc_id      = data.aws_subnet.selected.vpc_id

  dynamic "ingress" {
    for_each = each.value.ingress
    content {
      from_port       = ingress.value.from_port
      to_port         = ingress.value.to_port
      protocol        = ingress.value.protocol
      cidr_blocks     = ingress.value.cidr_blocks
      security_groups = ingress.value.security_groups
      description     = ingress.value.description
    }
  }

  dynamic "egress" {
    for_each = each.value.egress
    content {
      from_port        = egress.value.from_port
      to_port          = egress.value.to_port
      protocol         = egress.value.protocol
      cidr_blocks      = egress.value.cidr_blocks
      ipv6_cidr_blocks = egress.value.ipv6_cidr_blocks
      description      = egress.value.description
    }
  }

  tags = {
    Name = each.value.security_group_name != null ? each.value.security_group_name : each.key
  }
}
