# instances/prodprotosim.tf - see README.md > "The protosim protocol ports"

module "prodprotosim" {
  source = "./modules/ec2-instance"

  name     = "acme-swe-prod-protosim"
  hostname = "SWE-P-PROTOSIM01" # only acts on a new instance

  ami_id        = var.arm_docker_ami_id # pinned: "latest" would recreate the machine
  instance_type = "t4g.large"           # Graviton, required for the arm64 AMI

  subnet_id        = var.private_subnet_id # private-d; the public ones have no egress
  vpc_id           = var.vpc_id
  instance_profile = var.instance_profile # without it SSM does not register

  root_volume_size = 50                       # minimum = arm64 AMI disk
  key_name         = "acme-swe-prod-protosim" # immutable: changing it replaces

  enable_termination_protection = true

  # Client SG (legacy ERP), shared by the prod machines - see clientsg.tf.
  # This machine's 65022 comes from THERE, pointing at the legacy ERP. This
  # machine is born in the new pattern: it never had its own 65022 rule to move.
  extra_security_group_ids = [aws_security_group.prod_client.id]

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
    #
    # THERE IS NO sftp_plc_workstation HERE, and that is not an omission: this
    # machine's 65022 comes from the client SG, pointing at the legacy ERP.
    #
    # The text about "sftp_plc_workstation REMOVED ON 10/21" that is in
    # nonprodprotosim.tf does NOT apply to this file - there the rule existed and
    # was removed, here it never existed, because the machine is born in the new
    # pattern. It came by copy and was fixed. Same problem as the descriptions of
    # 443 and 80 that arrived swapped on the production dataflow: a copied
    # comment describing history that did not happen misleads whoever reviews it
    # later.
    #
    # The reasoning about port 65022 - why it is not 22, why the SG does not
    # distinguish SFTP from shell, and why opening the port is only half the way
    # without the public key in authorized_keys - is in the erp_sftp rule in
    # clientsg.tf.
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
    "acme:automation:Environment"      = "prod"
    "RequestId"                        = "req-4942"
    "acme:automation:AutoWake"         = "true"
  })
}
