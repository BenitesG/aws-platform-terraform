# instances/proddataflow.tf - see README.md > "Recorded decisions"

module "proddataflow" {
  source = "./modules/ec2-instance"

  name     = "acme-swe-prod-dataflow"
  hostname = "SWE-P-FLOW01" # only acts on a new instance

  ami_id        = var.arm_docker_ami_id # pinned: "latest" would recreate the machine
  instance_type = "t4g.large"           # Graviton, required for the arm64 AMI

  subnet_id        = var.private_subnet_id # private-d; the public ones have no egress
  vpc_id           = var.vpc_id
  instance_profile = var.instance_profile # without it SSM does not register

  root_volume_size = 30                         # minimum = arm64 AMI disk
  key_name         = "acme-swe-prod-dataflow01" # immutable: changing it replaces

  enable_termination_protection = true

  # THE LEGACY ERP RULES LEFT HERE ON 10/21 - they moved to the client SG, in
  # clientsg.tf, attached below. They were not removed: they were CENTRALIZED.
  # The full reasoning is in clientsg.tf and in the nonprod one.
  #
  # WHAT THE PLAN SHOWS: this SG's 6 ingress and 3 egress rules are DESTROYED and
  # recreated on the new SG. No "moved" block is possible - the parent SG
  # changes, and "moved" only rewrites an address within the same resource.
  #
  # THIS IS THE INTEGRATION'S PRODUCTION MACHINE. The cost of the change is the
  # WINDOW between destroying the old rule and creating the new one, not the
  # resource itself. That is why the apply goes in two steps, the ADDITIVE one
  # first: create the new SG with the rules and attach it, verify, and only then
  # empty this map. In a single apply Terraform does not guarantee the order
  # between the two.
  #
  # PRESERVED in clientsg.tf: the 10/21 fix to the descriptions of 443 and 80,
  # which were swapped by copying from nonprod; and the question of who initiates
  # the connection, closed by finding - the symmetry between ingress and egress
  # is CORRECT, the communication is bidirectional on the same ports.
  #
  # REMOVED on purpose: the legacy ERP ICMP ingress. No automated validation
  # depended on it - it was a manual check in the console. This also closes the
  # "they ping us, we do not ping them" asymmetry that was open.
  integration_ingress_rules = {}
  integration_egress_rules  = {}

  # Client SG (legacy ERP), shared by the prod machines - see clientsg.tf.
  extra_security_group_ids = [aws_security_group.prod_client.id]

  # Project, Application and Environment are a per-machine question, never
  # inheritance. They override the provider's default_tags.
  tags = merge(var.common_tags, {
    "acme:cost-allocation:Project"     = "erp-integration"
    "acme:cost-allocation:Application" = "dataflow"
    "acme:automation:Environment"      = "prod"
    "RequestId"                        = "req-4939"
    "acme:automation:AutoWake"         = "true"
  })
}
