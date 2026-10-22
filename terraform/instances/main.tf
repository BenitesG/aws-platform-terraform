# ---------------------------------------------------------------------------
# instances/main.tf - directory map and machine template.
#
# THIS FILE RECEIVES NO MACHINE. Each machine has its own file:
#
#   nonproddataflow.tf   acme-swe-nonprod-dataflow   (legacy ERP integration, dev)
#   proddataflow.tf      acme-swe-prod-dataflow      (legacy ERP integration, prod)
#   nonprodprotosim.tf   acme-swe-nonprod-protosim   (protocol simulator)
#   prodprotosim.tf      acme-swe-prod-protosim      (protocol simulator)
#   nonprodworkbench.tf  acme-swe-nonprod-workbench  (workbench)
#   prodworkbench.tf     acme-swe-prod-workbench     (workbench)
#
# THE RULE IS FOR THE FILE NAME TO MATCH THE module LABEL, so that when you read
# "module.nonprodprotosim.aws_instance.this" in a plan you know which file to
# open. All six match.
#
# AND ONE FILE THAT IS NOT A MACHINE:
#
#   clientsg.tf          security groups for the client (legacy ERP)
#                        integration, one per environment, shared by the
#                        machines through extra_security_group_ids
#
# It exists because the legacy ERP rule belongs to the INTERLOCUTOR, not the
# machine: it applies to the whole fleet. A rule that applies to a SINGLE
# machine still goes in integration_ingress_rules, in that machine's file.
#
# The label "dataflow" was renamed to "nonproddataflow" on 10/21 with a "moved"
# block - which rewrites the address in the state without touching AWS. Renaming
# a FILE needs nothing; renaming a LABEL needs "moved", otherwise Terraform
# destroys and recreates.
#
# Full procedure:    README.md > "How to create a new machine"
# Reasons for values: README.md > "Recorded decisions"
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# FILE versus FOLDER - the criterion, which is NOT the resource type
#
# NEW FILE: for each unit you read and edit together. Here, one machine. A file
# is HUMAN organization: Terraform concatenates all the .tf in the directory
# before interpreting, and the address in the state has no file name inside it.
# Moving a block between files, or renaming the file, changes nothing - proven
# twice on 10/21, both ended with "No changes".
#
# NEW FOLDER (= new state, new key in the backend): the question that decides is
#
#   "CAN I RECREATE THIS FROM CODE?"
#
#   RECREATABLE - a mistake costs minutes     NOT RECREATABLE - a mistake costs DATA
#   EC2 from the golden image                 RDS
#   security group                            S3 with content
#   ALB, target group                         EFS
#   launch template                           DATA EBS volume
#   root disk (delete_on_termination)         Route 53 zone with records
#
# What is not recreatable goes into its own folder, ALWAYS. Not for elegance: a
# "terraform destroy" in one folder has no way to reach another. It is the only
# isolation that does not depend on someone paying attention.
#
# WHY NOT "ONE FOLDER PER RESOURCE TYPE": the type is a good hint and it errs in
# both directions. A DATA EBS volume is in the EC2 family, same type as the
# instance, and belongs on the protected side. An ALB is a big, expensive,
# visible resource, and it is entirely recreatable.
#
# THE BEHAVIORAL REASON, which is the decisive one: if 90% of the plans are a
# routine machine change, you learn to skim. On 10/20 a "14 to destroy" from a
# key_name change was only caught because someone read the LIST of resources,
# not the summary. Mixing a high-consequence resource with routine trains the
# wrong reading habit.
#
# THE OTHER TWO TRIGGERS, when the resource is recreatable but you still
# separate it:
#
#   CADENCE. What changes together stays together. The images are rebuilt
#   monthly, the instances changed four times in two days, the peering almost
#   never.
#
#   DIFFERENT CREDENTIAL OR OWNER. IAM requires the admin profile because of
#   iam:PassRole; networking depends on another team. A permission boundary is a
#   state boundary, and it is the most objective of the three triggers.
#
# The current split follows the criterion, not the type:
#
#   bootstrap/        the state bucket - must exist BEFORE everything
#   images/           image pipeline, monthly cadence
#   instances/        the machines - all recreatable
#   network-peering/  depends on another account and another team
#
# WHEN RDS OR AN APPLICATION BUCKET ARRIVES: its own folder, with the resource's
# locks next to the state wall -
#   deletion_protection = true      AWS refuses the delete
#   skip_final_snapshot = false     requires a snapshot before deleting
#   lifecycle { prevent_destroy = true }   fails AT PLAN, before calling AWS
# prevent_destroy is the most useful of the three: it catches destroy AND
# replace.
#
# And the database access rule lives in the DATABASE's directory, discovering
# the machine's SG by data source - not by a copied ID, and not with
# terraform_remote_state, which couples one state to the internal details of the
# other.
#
# THE COST OF A NEW FOLDER, which is real: backend, provider and variables
# duplicated; and above all the shared values (vpc_id, subnet, instance_profile,
# AMIs, common_tags) copied into each terraform.tfvars - which is NOT versioned.
# Divergence between copies is invisible to git.
#
# The way to make the split cheap is to discover the shared part by data source
# instead of copying an ID:
#
#   data "aws_subnet" "private_d" {
#     filter {
#       name   = "tag:Name"
#       values = ["acme-swe-prod-private-d"]
#     }
#   }
#
# Note the contrast with the AMI, where a data source is FORBIDDEN: there the
# problem is tracking "the latest", because "ami" is ForceNew and would recreate
# the instance. VPC and subnet do not change, so the reasoning does not apply.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# TEMPLATE - copy it into a new file, not into this one.
#
# Before copying, answer: name, architecture (type + AMI together) and the three
# tags. Once applied, name and key_name only change by replacing the resource.
#
# Do NOT copy another machine's block without cleaning up the rules and tags. It
# went wrong three times here: the copied block brings the original's network
# rules and tags.
#
# module "runner01" {
#   source = "./modules/ec2-instance"
#
#   name     = "acme-swe-prod-runner01"
#   hostname = "SWE-P-RUNNER01" # only acts on a new instance
#
#   ami_id        = var.arm_docker_ami_id # pinned: "latest" would recreate the machine
#   instance_type = "t4g.medium"          # Graviton, required for the arm64 AMI
#
#   subnet_id        = var.private_subnet_id # private-d; the public ones have no egress
#   vpc_id           = var.vpc_id
#   instance_profile = var.instance_profile # without it SSM does not register
#
#   root_volume_size = 30                       # minimum = AMI disk
#   key_name         = "acme-swe-prod-runner01" # immutable: changing it replaces
#
#   enable_termination_protection = true
#
#   # Empty ingress is the default of the empty-ingress SG design. Declare a
#   # rule only with a REAL source.
#   integration_ingress_rules = {}
#   integration_egress_rules  = {}
#
#   tags = merge(var.common_tags, {
#     "acme:cost-allocation:Project"     = "<fill in>"
#     "acme:cost-allocation:Application" = "<fill in>"
#     "acme:automation:Environment"      = "<fill in>"
#   })
# }
# ---------------------------------------------------------------------------
