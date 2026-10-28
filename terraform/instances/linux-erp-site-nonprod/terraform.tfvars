##################################################################
# terraform.tfvars - linux-erp-site NONPROD
#
# VERSIONADO por decisao (26/10). ATENCAO aos dois CIDRs abaixo: sao infra de
# TERCEIRO (conta de producao 444455556666). Isolados no topo de proposito -
# se um dia a decisao mudar, sao estas duas linhas a limpar (e exigiria
# reescrever historico de git, que e por isso pratico-irreversivel).
##################################################################

##################################################################
#_____ CIDRs DE INFRA DE TERCEIRO (conta 444455556666) __________#
##################################################################
erp_host_cidr = "172.31.62.51/32" # host do legacy ERP, via peering
plc_host_cidr = "172.31.50.50/32" # host do Studio 5000, via peering

##################################################################
#_____ PROVIDER / BACKEND _______________________________________#
##################################################################
# DelegatedAdministrator (nao PowerUser): instance profile exige iam:PassRole.
aws_profile = "acme-swe-prod-admin"
region      = "us-west-2"

##################################################################
#_____ REDE / BASELINE __________________________________________#
##################################################################
vpc_id            = "vpc-0a1b2c3d4e5f60001"    # acme-swe-prod-vpc
private_subnet_id = "subnet-0a1b2c3d4e5f70001" # acme-swe-prod-private-d
instance_profile  = "delegated-ec2-ssm"

##################################################################
#_____ TAGS COMUNS (viram default_tags) _________________________#
##################################################################
# So o genuinamente comum. Project/Application/Environment variam por maquina
# e vao no mapa servers.
common_tags = {
  ManagedBy                         = "terraform"
  "acme:cost-allocation:Department" = "swe"
  "acme:cost-allocation:CostCenter" = "h370infra"
  "mb:data:DataClassification"      = "interno"
  Owner                             = "platform-team@acme.example"
  ChargeType                        = "dedicated"
}

##################################################################
#_____ SERVERS (3 maquinas NONPROD) _____________________________#
##################################################################
# AMIs: fixas de proposito. arm_docker (host de container) tem Docker com
# rotacao de log; arm (base) nao. Valores de 26/10:
#   arm_ami    = ami-0a1b2c3d4e5fb0004
#   arm_docker = ami-0a1b2c3d4e5fb0006
servers = {
  # Bancada de trabalho. Fala com o legacy ERP pela client SG, sem regra propria.
  SWE-N-CAG01 = {
    name          = "acme-swe-nonprod-cagworkbench"
    ami_id        = "ami-0a1b2c3d4e5fb0006" # arm_docker
    instance_type = "t4g.small"
    key_name      = "acme-swe-nonprod-cagworkbench"

    project     = "erpflow"
    application = "cagworkbench"
    environment = "nonprod"
    request_id  = "ticketing-system-4943"
  }

  # Desenvolvimento da integracao legacy ERP. Base (sem Docker da imagem - Docker foi
  # instalado a mao historicamente). key_name diz "prod" por residuo; NAO
  # corrigir (ForceNew substituiria a maquina).
  SWE-N-OPFLOW01 = {
    name          = "acme-swe-nonprod-operationalflow"
    ami_id        = "ami-0a1b2c3d4e5fb0004" # arm (base)
    instance_type = "t4g.small"
    key_name      = "acme-swe-prod-operationalflow"

    project     = "erpflow"
    application = "operationalflow"
    environment = "nonprod"
    # sem request_id (a maquina original nao tinha no bloco)
  }

  # Simulador de protocolo industrial. Regras de protocolo apontam para o
  # Studio 5000 (/32). ENTRADA = ATB escravo; SAIDA = ATB mestre.
  # A 65022 (SFTP) desta maquina vem do legacy ERP pela client SG, nao daqui.
  SWE-N-ATB01 = {
    name          = "acme-swe-nonprod-atb"
    ami_id        = "ami-0a1b2c3d4e5fb0006" # arm_docker
    instance_type = "t4g.small"
    key_name      = "acme-swe-nonprod-atb"

    project     = "erpflow"
    application = "atb"
    environment = "nonprod"
    request_id  = "ticketing-system-4940"

    integration_ingress_rules = {
      modbus_slave_low = {
        description = "Modbus TCP: slaves simulados, faixa baixa"
        ip_protocol = "tcp"
        from_port   = 400
        to_port     = 1000
        cidr_ipv4   = "172.31.50.50/32"
      }
      modbus_slave_high = {
        description = "Modbus TCP: slaves simulados, faixa alta"
        ip_protocol = "tcp"
        from_port   = 4000
        to_port     = 6000
        cidr_ipv4   = "172.31.50.50/32"
      }
      enip_slave_tcp = {
        description = "EtherNet/IP: sessoes explicitas nos slaves simulados"
        ip_protocol = "tcp"
        from_port   = 44800
        to_port     = 44900
        cidr_ipv4   = "172.31.50.50/32"
      }
      enip_slave_udp = {
        description = "EtherNet/IP: I/O implicito nos slaves simulados"
        ip_protocol = "udp"
        from_port   = 44800
        to_port     = 44900
        cidr_ipv4   = "172.31.50.50/32"
      }
      bacnet_slave = {
        description = "BACnet/IP: dispositivos simulados"
        ip_protocol = "udp"
        from_port   = 47808
        to_port     = 47907
        cidr_ipv4   = "172.31.50.50/32"
      }
    }

    integration_egress_rules = {
      modbus_master = {
        description = "Modbus TCP: ATB consultando equipamento real"
        ip_protocol = "tcp"
        from_port   = 502
        to_port     = 502
        cidr_ipv4   = "172.31.50.50/32"
      }
      enip_master_tcp = {
        description = "EtherNet/IP: sessao explicita para equipamento real"
        ip_protocol = "tcp"
        from_port   = 44818
        to_port     = 44818
        cidr_ipv4   = "172.31.50.50/32"
      }
      enip_master_io = {
        description = "EtherNet/IP: I/O implicito para equipamento real"
        ip_protocol = "udp"
        from_port   = 2222
        to_port     = 2222
        cidr_ipv4   = "172.31.50.50/32"
      }
      bacnet_master = {
        description = "BACnet/IP: ATB consultando dispositivo real"
        ip_protocol = "udp"
        from_port   = 47808
        to_port     = 47808
        cidr_ipv4   = "172.31.50.50/32"
      }
    }
  }
}
