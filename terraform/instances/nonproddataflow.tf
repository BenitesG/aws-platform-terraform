# instances/nonproddataflow.tf - see README.md > "Recorded decisions"

# LABEL RENAMED ON 10/21, from "dataflow" to "nonproddataflow", to match the
# file name and the machine name.
#
# DONE WITH A "moved" BLOCK, which is what makes this safe - and the block was
# removed after the apply, because there is a single state and the move applies
# to everyone. Same pattern as the moved blocks from the 10/15 refactor into
# modules.
#
#   moved {
#     from = module.dataflow
#     to   = module.nonproddataflow
#   }
#
# WHY THE BLOCK WAS NEEDED: the address in the state IS the resource's identity.
# Renaming the label without "moved" would make Terraform see a new address
# (create) and an orphaned address in the state (destroy) - 14 resources,
# including the instance with the disk, the hand-installed Docker and the legacy
# ERP integration container.
#
# With the block, the plan gave 0 to add, 0 to change, 0 to destroy and 14
# moves, and the apply confirmed it: 0 added, 0 changed, 0 destroyed.
#
# A CONTRAST WORTH KEEPING: renaming a FILE needs nothing, because the file name
# is not part of the address. Renaming a LABEL needs "moved".

# DEVELOPMENT instance of the legacy ERP integration - slug "dataflow-dev" in
# the start/stop scheduler logs. It receives real production traffic: nonprod is
# its role in the topology, not its criticality.
#
# The key_name says "prod" and the machine is nonprod - a leftover from when it
# was going to become production. NOT FIXED on purpose: key_name is ForceNew,
# there is no renaming a key pair on AWS, and changing it would replace the
# instance, taking the disk with it. After launch the key_name is just metadata;
# what works is the authorized_keys on the disk. Same trade-off the module makes
# with the SG description - a cosmetic fix is not worth a replacement.
module "nonproddataflow" {
  source = "./modules/ec2-instance"

  name     = "acme-swe-nonprod-dataflow"
  hostname = "SWE-N-FLOW01" # only acts on a new instance

  ami_id        = var.arm_ami_id # pinned: "latest" would recreate the machine
  instance_type = "t4g.small"    # Graviton, required for the arm64 AMI

  subnet_id        = var.private_subnet_id # private-d; the public ones have no egress
  vpc_id           = var.vpc_id
  instance_profile = var.instance_profile # without it SSM does not register

  root_volume_size = 30                          # minimum = arm64 AMI disk
  key_name         = "acme-swe-nonprod-dataflow" # immutable: changing it replaces

  enable_termination_protection = true

  # THE LEGACY ERP RULES LEFT HERE ON 10/21 - they moved to the client SG, in
  # clientsg.tf, attached below. They were not removed: they were CENTRALIZED.
  #
  # WHY: the legacy ERP rules do not belong to this machine, they belong to the
  # INTERLOCUTOR, and every machine in the fleet talks to the legacy ERP. Kept
  # per machine, they were duplicated across two files and missing from two, and
  # revoking the legacy ERP's access would mean remembering four places.
  #
  # WHAT THE PLAN SHOWS: this SG's 6 ingress and 3 egress rules are DESTROYED and
  # recreated on the new SG. There is no "moved" block for this - the parent SG
  # changes, and "moved" only rewrites an address within the same resource. A
  # rule is recreatable in seconds, so the cost is the WINDOW, not the resource:
  # that is why the apply is done in two steps, the additive one first.
  #
  # THIS SG'S INGRESS GOES BACK TO BEING EMPTY, and the egress back to just
  # 443/80 to 0.0.0.0/0 - which the module declares as fixed, not this file.
  #
  # WHAT WAS PRESERVED IN THE MOVE, recorded in clientsg.tf:
  #   - the 10/21 fix to the descriptions of 443 and 80, which were swapped
  #   - the question of who initiates the connection, closed by finding: the
  #     symmetry between ingress and egress is CORRECT, the communication is
  #     bidirectional on the same ports. It was not a symptom of "we do not know
  #     who initiates the connection"
  #
  # WHAT WAS NOT PRESERVED, on purpose: the legacy ERP ICMP ingress. REMOVED on
  # 10/21, not forgotten - no automated validation depended on it, the ping was
  # a manual check in the console. This also closes the "they ping us, we do not
  # ping them" asymmetry that was an open decision: the rule no longer exists.
  # Bringing it back is one line in local.erp_ingress_rules.
  integration_ingress_rules = {}
  integration_egress_rules  = {}

  # Client SG (legacy ERP), shared by the nonprod machines - see clientsg.tf.
  # WATCH OUT: a rule added there applies to all THREE nonprod machines.
  extra_security_group_ids = [aws_security_group.nonprod_client.id]

  # Project, Application and Environment are a per-machine question, never
  # inheritance. They override the provider's default_tags.
  tags = merge(var.common_tags, {
    "acme:cost-allocation:Project"     = "erp-integration"
    "acme:cost-allocation:Application" = "dataflow"
    "acme:automation:Environment"      = "nonprod"
    "acme:automation:AutoWake"         = "true"
  })
}
