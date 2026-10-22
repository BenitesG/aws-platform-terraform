# instances/nonprodworkbench.tf - see README.md > "The workbench is born with empty ingress and egress"

module "nonprodworkbench" {
  source = "./modules/ec2-instance"

  name     = "acme-swe-nonprod-workbench"
  hostname = "SWE-N-WORKBENCH01" # only acts on a new instance

  ami_id        = var.arm_docker_ami_id # pinned: "latest" would recreate the machine
  instance_type = "t4g.small"           # Graviton, required for the arm64 AMI

  subnet_id        = var.private_subnet_id # private-d; the public ones have no egress
  vpc_id           = var.vpc_id
  instance_profile = var.instance_profile # without it SSM does not register

  root_volume_size = 30                           # minimum = arm64 AMI disk
  key_name         = "acme-swe-nonprod-workbench" # immutable: changing it replaces

  enable_termination_protection = true

  # OWN INGRESS EMPTY - the empty-ingress design holds HERE, on the machine's SG.
  #
  # Nothing reaches this machine through its own SG: access is through Session
  # Manager, and the SSM agent opens the connection from the INSIDE out. The
  # 443/80 egress to 0.0.0.0/0 that the module declares is enough for AWS APIs,
  # SSM and apt.
  #
  # WHAT CHANGED ON 10/21: the legacy ERP rules apply to this machine again, but
  # they did NOT come over here - they are in the client SG in clientsg.tf,
  # attached below.
  #
  # ON 10/20 THEY WERE REMOVED from here, with the reason "they came by copying
  # the dataflow block and had no reason: this machine is a workbench, it does
  # not take part in the integration".
  #
  # THAT REASON WAS WRONG. The workbench talks to the legacy ERP too, and it
  # should have had the rule. The wrong reasoning was treating "it came by copy"
  # as proof that the code should not be there - the ORIGIN of the code does not
  # answer whether it is NECESSARY. The right question was "does this machine
  # talk to the legacy ERP?". Full record in clientsg.tf.
  #
  # To access a web interface without opening any port:
  #   aws ssm start-session --target <id> \
  #     --document-name AWS-StartPortForwardingSession \
  #     --parameters "portNumber=80,localPortNumber=8080"
  #
  # An SG rule is mutable IN PLACE, so adding one later is cheap and does not
  # replace the security group.
  integration_ingress_rules = {}
  integration_egress_rules  = {}

  # Client SG (legacy ERP), shared by the nonprod machines - see clientsg.tf.
  extra_security_group_ids = [aws_security_group.nonprod_client.id]

  # Project, Application and Environment are a per-machine question, never
  # inheritance. They override the provider's default_tags.
  tags = merge(var.common_tags, {
    "acme:cost-allocation:Project"     = "erp-integration"
    "acme:cost-allocation:Application" = "workbench"
    "acme:automation:Environment"      = "nonprod"
    "RequestId"                        = "req-4943"
    "acme:automation:AutoWake"         = "true"
  })
}
