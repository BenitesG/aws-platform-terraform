##################################################################
# terraform.tfvars - linux-erp-site PROD
#
# VERSIONADO por decisao (26/10). ATENCAO aos dois CIDRs abaixo: sao infra de
# TERCEIRO (conta de producao 444455556666). Isolados no topo de proposito -
# se um dia a decisao mudar, sao estas duas linhas a limpar.
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
common_tags = {
  ManagedBy                         = "terraform"
  "acme:cost-allocation:Department" = "swe"
  "acme:cost-allocation:CostCenter" = "h370infra"
  "mb:data:DataClassification"      = "interno"
  Owner                             = "platform-team@acme.example"
  ChargeType                        = "dedicated"
}

##################################################################
#_____ SERVERS (3 maquinas PROD) ________________________________#
##################################################################
# AMI arm_docker (host de container, com rotacao de log), valor de 26/10:
#   arm_docker = ami-0a1b2c3d4e5fb0006
servers = {
  # Bancada de trabalho. Fala com o legacy ERP pela client SG, sem regra propria.
  SWE-P-CAG01 = {
    name          = "acme-swe-prod-cagworkbench"
    ami_id        = "ami-0a1b2c3d4e5fb0006" # arm_docker
    instance_type = "t4g.medium"
    key_name      = "acme-swe-prod-cagworkbench"

    project     = "erpflow"
    application = "cagworkbench"
    environment = "prod"
    request_id  = "ticketing-system-4944"
  }

  # Producao da integracao legacy ERP. ~1.500 conexoes/dia, Docker instalado a mao.
  # ULTIMA a migrar via state mv, com janela: no 3b o egress 443/80 e recriado
  # no apply pos-mv (janela de segundos). Fazer com a maquina parada.
  SWE-P-OPFLOW01 = {
    name          = "acme-swe-prod-operationalflow"
    ami_id        = "ami-0a1b2c3d4e5fb0006" # arm_docker
    instance_type = "t4g.large"
    key_name      = "acme-swe-prod-operationalflow01"

    project     = "erpflow"
    application = "operationalflow"
    environment = "prod"
    request_id  = "ticketing-system-4939"
  }

  # Simulador de protocolo industrial. Regras apontam para o Studio 5000 (/32).
  # A 65022 (SFTP) vem do legacy ERP pela client SG, nao daqui.
  SWE-P-ATB01 = {
    name             = "acme-swe-prod-atb"
    ami_id           = "ami-0a1b2c3d4e5fb0006" # arm_docker
    instance_type    = "t4g.large"
    key_name         = "acme-swe-prod-atb"
    root_volume_size = 50

    project     = "erpflow"
    application = "atb"
    environment = "prod"
    request_id  = "ticketing-system-4942"

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
