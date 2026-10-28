##################################################################
# win-app-site — Infraestrutura App (Windows Server 2025)
# Autor: @contributor
##################################################################

##################################################################
#_____ KEY PAIRS (uma por instância) ____________________________#
##################################################################
# A chave privada (.pem) é gerada fora do Terraform e NÃO entra no state nem no
# repositório; o Terraform importa apenas a chave pública de keys/<hostname>.pub.
# Gerar com: ssh-keygen -t rsa -b 2048 -m PEM -f keys/<HOSTNAME>
resource "aws_key_pair" "this" {
  for_each = var.servers

  key_name   = each.value.key_name != null ? each.value.key_name : each.key
  public_key = file("${path.module}/keys/${each.value.key_name != null ? each.value.key_name : each.key}.pub")
}

##################################################################
#_____ VIRTUAL MACHINES (App / Windows Server 2025) ___________#
##################################################################
resource "aws_instance" "this" {
  for_each = var.servers

  # AMI informada na maquina vence; senao, a golden image resolvida no data.tf.
  ami                    = each.value.ami_id != null ? each.value.ami_id : data.aws_ssm_parameter.win2025.value
  instance_type          = each.value.instance_type
  key_name               = aws_key_pair.this[each.key].key_name
  subnet_id              = var.network.subnet_id
  vpc_security_group_ids = [aws_security_group.this[each.key].id]

  iam_instance_profile = aws_iam_instance_profile.instance[each.key].name

  root_block_device {
    volume_size = each.value.root_volume_size
    volume_type = each.value.volume_type
    encrypted   = true

    tags = {
      Name = "${each.key}-C"
    }
  }

  user_data = templatefile("${path.module}/templates/userdata.ps1.tftpl", {
    hostname = each.key
  })

  tags = {
    Name = each.key
    Role = each.value.role
  }

  # A AMI é resolvida via SSM e muda quando a AWS publica uma nova imagem.
  # Ignoramos para não recriar instâncias já provisionadas.
  lifecycle {
    ignore_changes = [ami]
  }
}

##################################################################
#_____ DATA VOLUMES (E:, F:, ...) _______________________________#
##################################################################
resource "aws_ebs_volume" "data" {
  for_each = local.data_disks

  availability_zone = aws_instance.this[each.value.host].availability_zone
  size              = each.value.size
  type              = each.value.volume_type
  encrypted         = true

  tags = {
    Name = "${each.value.host}-${each.value.device_name}"
  }
}

resource "aws_volume_attachment" "data" {
  for_each = local.data_disks

  device_name = each.value.device_name
  volume_id   = aws_ebs_volume.data[each.key].id
  instance_id = aws_instance.this[each.value.host].id
}
