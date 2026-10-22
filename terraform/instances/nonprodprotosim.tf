# instances/nonprodprotosim.tf - see README.md > "The protosim protocol ports"

module "nonprodprotosim" {
  source = "./modules/ec2-instance"

  name     = "acme-swe-nonprod-protosim"
  hostname = "SWE-N-PROTOSIM01" # only acts on a new instance

  ami_id        = var.arm_docker_ami_id # pinned: "latest" would recreate the machine
  instance_type = "t4g.small"           # Graviton, required for the arm64 AMI

  subnet_id        = var.private_subnet_id # private-d; the public ones have no egress
  vpc_id           = var.vpc_id
  instance_profile = var.instance_profile # without it SSM does not register

  root_volume_size = 30                          # minimum = arm64 AMI disk
  key_name         = "acme-swe-nonprod-protosim" # immutable: changing it replaces

  enable_termination_protection = true

  # Client SG (legacy ERP), shared by the nonprod machines - see clientsg.tf.
  # This machine's 65022 lives THERE since 10/21, pointing at the legacy ERP.
  extra_security_group_ids = [aws_security_group.nonprod_client.id]

  # ===========================================================================
  # PROTOSIM INDUSTRIAL PROTOCOL PORTS
  #
  # Single source and destination: the industrial engineering workstation host,
  # as a /32. It is in the PRODUCTION account (172.31.0.0/16), reached through
  # the peering - see the note in var.plc_workstation_host_cidr.
  #
  # INGRESS = PROTOSIM as a SLAVE: it simulates equipment and receives polling.
  # EGRESS  = PROTOSIM as a MASTER: it queries real equipment.
  #
  # THE INGRESS RANGES ARE WIDE ON PURPOSE, because each simulated slave listens
  # on its own port. Worth knowing what that includes: 400-1000/TCP covers 443,
  # 445, 500, 514, 636, 873, 993 and 995. The risk is contained because the
  # source is ONE host as a /32 - it is not an open range. If one day the ports
  # actually used are known, narrowing them reduces the surface at no cost.
  #
  # EGRESS MAKES AN EXCEPTION TO THE LATERAL MOVEMENT RISK, which restricts
  # egress to 443/80 to mitigate lateral movement. The ESSENTIAL mitigation
  # still holds: no database port (3306/1433/5432) was opened, and the
  # destination is a single host.
  #
  # DO NOT RENAME THE map KEYS after they are applied: the key becomes part of
  # the resource's address in the state, and renaming destroys and recreates the
  # rule.
  # ===========================================================================

  integration_ingress_rules = {
    # ONLY THE PROTOCOL RULES, all for the industrial engineering workstation.
    # The only one that was NOT a protocol rule was removed from here:
    #
    # sftp_plc_workstation REMOVED ON 10/21, by decision. PROTOSIM's 65022 now
    # comes from the legacy ERP, through the client SG in clientsg.tf - PROTOSIM
    # will do file transfer with the legacy ERP, not with the industrial
    # engineering workstation.
    #
    # RECORDED CONSEQUENCE: the host 172.31.20.11/32 no longer reaches 65022 on
    # this machine. If req-4940 planned a transfer ORIGINATING from the
    # industrial engineering workstation, it stops working. Reverting is ONE
    # rule, mutable in place - it does not replace the SG nor the instance.
    #
    # IT WAS NOT A TECHNICAL DUPLICATE: an SG rule is a UNION across the SGs
    # attached to the ENI, and the two sources (the legacy ERP's /32 and the
    # industrial engineering workstation's /32) would coexist without conflict,
    # being in different SGs - there would be no InvalidPermission.Duplicate. The
    # removal was a choice of WHO should have access, not a requirement from AWS.
    #
    # The reasoning about port 65022 - why it is not 22, why the SG does not
    # distinguish SFTP from shell, and why opening the port is only half the way
    # without the public key in authorized_keys - moved to the erp_sftp rule in
    # clientsg.tf, which is where the port now lives.
    modbus_slave_low = {
      description = "Modbus TCP: simulated slaves, low range"
      ip_protocol = "tcp"
      from_port   = 400
      to_port     = 1000
      cidr_ipv4   = var.plc_workstation_host_cidr
    }

    modbus_slave_high = {
      description = "Modbus TCP: simulated slaves, high range"
      ip_protocol = "tcp"
      from_port   = 4000
      to_port     = 6000
      cidr_ipv4   = var.plc_workstation_host_cidr
    }

    enip_slave_tcp = {
      description = "EtherNet/IP: explicit sessions on the simulated slaves"
      ip_protocol = "tcp"
      from_port   = 44800
      to_port     = 44900
      cidr_ipv4   = var.plc_workstation_host_cidr
    }

    enip_slave_udp = {
      description = "EtherNet/IP: implicit I/O on the simulated slaves"
      ip_protocol = "udp"
      from_port   = 44800
      to_port     = 44900
      cidr_ipv4   = var.plc_workstation_host_cidr
    }

    bacnet_slave = {
      description = "BACnet/IP: simulated devices"
      ip_protocol = "udp"
      from_port   = 47808
      to_port     = 47907
      cidr_ipv4   = var.plc_workstation_host_cidr
    }
  }

  integration_egress_rules = {
    modbus_master = {
      description = "Modbus TCP: PROTOSIM querying real equipment"
      ip_protocol = "tcp"
      from_port   = 502
      to_port     = 502
      cidr_ipv4   = var.plc_workstation_host_cidr
    }

    enip_master_tcp = {
      description = "EtherNet/IP: explicit session to real equipment"
      ip_protocol = "tcp"
      from_port   = 44818
      to_port     = 44818
      cidr_ipv4   = var.plc_workstation_host_cidr
    }

    enip_master_io = {
      description = "EtherNet/IP: implicit I/O to real equipment"
      ip_protocol = "udp"
      from_port   = 2222
      to_port     = 2222
      cidr_ipv4   = var.plc_workstation_host_cidr
    }

    bacnet_master = {
      description = "BACnet/IP: PROTOSIM querying a real device"
      ip_protocol = "udp"
      from_port   = 47808
      to_port     = 47808
      cidr_ipv4   = var.plc_workstation_host_cidr
    }
  }

  # Project, Application and Environment are a per-machine question, never
  # inheritance. They override the provider's default_tags.
  tags = merge(var.common_tags, {
    "acme:cost-allocation:Project"     = "erp-integration"
    "acme:cost-allocation:Application" = "protosim"
    "acme:automation:Environment"      = "nonprod"
    "RequestId"                        = "req-4940"
    "acme:automation:AutoWake"         = "true"
  })
}
