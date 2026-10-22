# ---------------------------------------------------------------------------
# modules/ec2-instance/main.tf
#
# One EC2 instance in the project's pattern: no public IP, no key pair,
# access only through Session Manager.
#
# THE THREE THINGS THAT MAKE THIS INSTANCE UNREACHABLE IF WRONG:
#
#   1. subnet - must be PRIVATE-D. The public ones use rt-main, which has
#      only "local": an instance there has no egress at all and the SSM agent
#      does not register. It happened on 10/13. An instance does NOT change
#      subnet: getting it wrong means recreating
#   2. instance_profile - without it the SSM agent does not register, and since
#      there is no key pair and no port 22, there is no other way in
#   3. metadata - the agent gets its credentials from the IMDS. Disabling the
#      endpoint brings everything down
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Security group FOR THIS instance
#
# ONE SG PER MACHINE, by a decision from 10/16. Previously the instance reused
# acme-swe-prod-baseline-sg, created in the empty-ingress security group design
# for another project - the name described the wrong machine.
#
# BUT THE BIGGER PROBLEM WAS NOT THE NAME: a shared security group is a shared
# RULE. When the legacy ERP integration added the production integration rule,
# it would apply to every machine using that SG, not just the one that needs it.
# It is the same reasoning already recorded about the delegated-ec2-ssm role,
# where the conclusion was to separate baseline from specific.
#
# The SG lives INSIDE the module on purpose: that way "one per machine" is the
# default behavior and does not depend on anyone remembering to create it.
#
# AN SG NAME IS IMMUTABLE on AWS - there is no renaming, only creating another.
# But CHANGING an instance's SG does NOT require recreating it:
# vpc_security_group_ids is mutable in place. That is what let this be fixed
# with no downtime.
# ---------------------------------------------------------------------------

# A CHILD module declares the constraint of the provider it uses, but never a
# provider block: the configuration - region, profile, default_tags - is
# inherited from the root. Without this declaration the module carries no
# compatibility contract of its own, and the constraint that applies is
# whatever the caller happens to have. It must match the root: a divergence
# here fails at init, on the caller's side, with a message that names the
# module and not the cause.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_security_group" "this" {
  # Name derived from var.name. GroupName is IMMUTABLE on AWS, so renaming the
  # machine REPLACES the SG - and the replacement recreates every rule attached
  # to it.
  #
  # THIS WAS ACCEPTED ON 10/20, during the dataflow rename to prod, because two
  # conditions were true at the same time:
  #
  #   1. the machine was STOPPED, so there was no traffic to drop
  #   2. all 11 rules were ENTIRELY in code. Verified on the spot with
  #      describe-security-group-rules: 11 on AWS, 11 declared, matching one by
  #      one. A rule that existed only on AWS would be lost silently
  #
  # The second condition is the one that matters, and it was only true because
  # of the import on 10/16. Before it, recreating this SG would have wiped out
  # the legacy ERP integration with no error at all.
  #
  # BEFORE RENAMING A MACHINE WITH AN SG IN USE, repeat the two checks:
  #   aws ec2 describe-security-group-rules --filters Name=group-id,Values=<sg>
  #   aws ec2 describe-security-groups --filters Name=ip-permission.group-id,Values=<sg>
  # The second one flags another SG that references this one - the sg-id changes
  # on the replacement, and a reference by ID does not follow.
  name = "${var.name}-sg"

  # NEUTRAL DESCRIPTION, ON PURPOSE - changed on 10/20.
  #
  # The previous text was "Instance {name}: empty ingress, egress 443/80", and
  # it became FALSE on 10/16, when the legacy ERP integration opened ingress. It
  # became false and was kept that way because fixing it would replace the SG -
  # there was a comment "DO NOT FIX THIS TEXT" for exactly that reason.
  #
  # THE LESSON: the description of an immutable resource should not carry a fact
  # that changes. If it does, it either ages into something false or costs a
  # replacement to fix. This version only IDENTIFIES the SG, so it cannot go
  # stale.
  #
  # The record of what comes in and WHY stays in the RULE DESCRIPTIONS, which
  # are mutable in place - and that is the only place where that reason belongs.
  description = "Security group for instance ${var.name}"

  vpc_id = var.vpc_id

  lifecycle {
    # REQUIRED when the SG is replaced, it is not a preference.
    #
    # Without this Terraform tries to DESTROY the old SG before creating the new
    # one, and the old one is still attached to the instance's ENI - AWS refuses
    # with DependencyViolation and the apply dies halfway through, with the new
    # SG possibly already created. Partial state.
    #
    # With create_before_destroy the order becomes: create the new SG, create
    # the rules on it, point the instance at it, and only then delete the old
    # one.
    #
    # There is no name collision because the new SG has a different name. If one
    # day the replacement is for another reason and the name does NOT change,
    # create_before_destroy fails with InvalidGroup.Duplicate - in that case the
    # path is name_prefix.
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.name}-sg"
  })
}

# INGRESS: empty BY DEFAULT, and every exception is declared.
#
# The empty-ingress security group design was: the instance accepts no
# connection from outside, all communication starts from it, and Session Manager
# works because the SSM agent opens the connection from the inside out.
#
# THAT CHANGED ON dataflow ON 10/16, when the legacy ERP integration went into
# production. The rules are in integration_ingress_rules, declared in the module
# call - not here, because they are machine-specific.
#
# Rules as separate resources, not inline blocks: with inline "ingress"/"egress"
# Terraform assumes ownership of ALL the SG's rules and removes any created
# outside of it. As separate resources, management is per rule - and the plan
# shows exactly which one changes.
#
# THIS CHOICE HAD A REAL CONSEQUENCE on 10/16: the integration's nine rules were
# created by hand, and the plan kept saying "No changes" because a separate rule
# resource manages only the rule it declares. With inline blocks, the next apply
# would have WIPED OUT the entire integration. The side effect is the opposite:
# a rule outside the code stays invisible, with no record of the reason - and if
# the SG is recreated, it does not come back. That is why they were imported.

resource "aws_vpc_security_group_ingress_rule" "integration" {
  for_each = var.integration_ingress_rules

  security_group_id = aws_security_group.this.id
  description       = each.value.description
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = each.value.cidr_ipv4

  # THE MACHINE'S TAGS, not the directory's.
  #
  # Discovered in the plan of the 10/16 import: without this line the rule
  # inherits only the provider's default_tags, which carry Application =
  # baseline, Project = best-practices and Environment = prod - contradicting
  # the instance itself, which is dataflow / erp-integration / nonprod.
  #
  # It was the same kind of inconsistency fixed on 10/16 on the instance, when
  # the Name said "noprod" and the Environment said "prod": for Cost Explorer
  # and for Config rules, what counts is the tag, not the name. An SG rule has no
  # cost, but an inventory that contradicts itself is an inventory nobody trusts.
  tags = merge(var.tags, {
    Name = "${var.name}-in-${each.key}"
  })
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "AWS APIs, SSM, npm, Google APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"

  # THE MACHINE'S TAGS - ADDED ON 10/21.
  #
  # THESE TWO FIXED RULES WERE LEFT OUT of the 10/16 fix that brought the
  # machine's tags into the integration rules. Without the block, they inherit
  # ONLY the provider's default_tags - and the default carries Application =
  # baseline and Project = best-practices, from the project that created the
  # empty-ingress SG design.
  #
  # THE DEFECT WAS IN PRODUCTION, on 8 rules (two per machine, across the four):
  # confirmed by describe-security-group-rules, which returned Project =
  # best-practices, Application = baseline and NO Name tag.
  #
  # WHY IT SLIPPED THROUGH: the symptom is identical to what the ingress rule's
  # comment already described, and the 10/16 fix was done looking at the IMPORT
  # plan - which involved only the nine legacy ERP rules. These two did not show
  # up in the diff because they were not being imported, and nobody read what
  # already existed. It was the creation plan of a NEW machine that exposed the
  # wrong value, six days later.
  #
  # A rule tag is mutable IN PLACE: fixing it replaces nothing.
  tags = merge(var.tags, {
    Name = "${var.name}-out-https"
  })
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.this.id
  description       = "Ubuntu apt repositories (GPG-signed packages)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"

  # The machine's tags - see the note on the 443 egress rule.
  tags = merge(var.tags, {
    Name = "${var.name}-out-http"
  })
}

resource "aws_vpc_security_group_egress_rule" "integration" {
  for_each = var.integration_egress_rules

  security_group_id = aws_security_group.this.id
  description       = each.value.description
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = each.value.cidr_ipv4

  # The machine's tags - see the note on the ingress rule.
  tags = merge(var.tags, {
    Name = "${var.name}-out-${each.key}"
  })
}

# Egress restricted to 443/80 mitigates LATERAL MOVEMENT: with the peering
# active, the instance cannot reach a production database on 3306/1433/5432.
# Opening those ports undoes the mitigation - if it is unavoidable, restrict it
# to the destination IP and record the exception.
#
# STATE ON 10/16, after the legacy ERP integration went live: the mitigation
# HELD. The opened ports are application (5020-5023, 5160-5161) and SSH (65022),
# all restricted to a single host's /32. NO database port was opened - which was
# exactly what the lateral movement risk was meant to prevent.
#
# DNS is not affected: AWS documentation states that security groups cannot
# block queries to the Route 53 Resolver. There is no need to allow UDP 53.
#
# NTP is not affected either: the time service lives at 169.254.169.123,
# link-local, which is not filtered by a security group - same principle as the
# IMDS.

resource "aws_instance" "this" {
  ami           = var.ami_id
  instance_type = var.instance_type

  subnet_id = var.subnet_id

  # This instance's OWN SG, plus any extras the call passes in.
  #
  # extra_security_group_ids exists for legitimate shared-SG cases - for
  # example, an SG with an integration rule that applies to a group of machines.
  # Empty by default: the norm is for each machine to have only its own.
  vpc_security_group_ids = concat(
    [aws_security_group.this.id],
    var.extra_security_group_ids
  )

  # Redundant with the subnet configuration, but explicit: no instance in this
  # project has a public IP.
  associate_public_ip_address = false

  iam_instance_profile = var.instance_profile

  # Key pair OPTIONAL, empty by default.
  #
  # Empty = the console's "Proceed without a key pair", which is the project's
  # default: access is through Session Manager.
  #
  # When set, cloud-init injects the key pair's PUBLIC key into
  # ~ubuntu/.ssh/authorized_keys on the first boot. The private key never passes
  # through AWS - it stays with whoever generated it.
  #
  # WHY HERE AND NOT IN THE IMAGE: a key baked into the image would be the SAME
  # on every instance created from it, forever; leaking one would leak them all,
  # and revoking it would require rebuilding the image. Besides, Image Builder
  # deletes it: the RunSanitizeScript step removes authorized_keys before the
  # snapshot, for the same reason. Here it is per instance and revocable.
  #
  # WATCH OUT: key_name is IMMOVABLE after launch - you cannot attach a key pair
  # to an existing instance. On an instance that already came up without one,
  # the equivalent is adding the public key to authorized_keys by hand.
  #
  # And having a key pair does NOT open a network path: the instances have no
  # public IP and the subnet has no route to the IGW. SSH arrives through the
  # SSM tunnel (AWS-StartSSHSession), which needs no ingress rule on the security
  # group because it travels inside the connection the agent keeps open from the
  # inside out.
  key_name = var.key_name != "" ? var.key_name : null

  # NO KEY PAIR BY DEFAULT, on purpose. Access is through Session Manager.

  disable_api_termination = var.enable_termination_protection

  # IMDSv2 required.
  #
  # http_tokens = "required" refuses a query without a token, which is what
  # prevents credential theft through SSRF.
  #
  # hop_limit = 1 explicit: prevents a CONTAINER on the instance from reaching
  # the IMDS. Relevant to the CI runner risk. If one day a containerized runner
  # needs credentials, the correct path is OIDC, not raising this limit.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size

    # The account's default EBS encryption would already guarantee this;
    # explicit so the code does not depend on account configuration.
    encrypted = true

    delete_on_termination = true

    # The disk needs its own tags: the instance's tags do NOT propagate to the
    # volume.
    tags = merge(var.tags, {
      Name = "${var.name}-root"
    })
  }

  # Sets the hostname on the first boot. cloud-init runs this because the
  # image's cleanup component wiped its state.
  user_data = var.hostname == "" ? null : <<-EOT
    #cloud-config
    hostname: ${var.hostname}
    preserve_hostname: false
  EOT

  # Changing user_data recreates the instance. Since the hostname only matters
  # on the first boot, ignoring changes avoids an accidental replacement.
  user_data_replace_on_change = false

  lifecycle {
    # The AMI of an ALREADY-CREATED instance must not propose a replacement.
    #
    # WHY, decided on 10/19: the ami_id variable needs to track the lineage's
    # CURRENT image, so that a NEW instance is born with an up-to-date standard.
    # But "ami" is ForceNew - so updating the variable would make the plan want
    # to DESTROY AND RECREATE the existing machine, taking the disk, the
    # hand-installed Docker and the legacy ERP integration container.
    #
    # With ignore_changes, the two coexist: the variable points to the new image
    # and the existing machine stays on the AMI it was born from. This FREES the
    # old AMI for removal - it was the only reference holding it.
    #
    # WHAT YOU GIVE UP: changing an existing machine's image is no longer a
    # variable edit and becomes an explicit act:
    #
    #   terraform apply -replace=module.dataflow.aws_instance.this
    #
    # That is MORE deliberate than before, not less - and it is consistent with
    # what the ami_id comment in the module always said: changing images should
    # be a deliberate act, never a side effect of touching a variable.
    #
    # WATCH OUT: deregistering an AMI does NOT affect a running or stopped
    # instance. The AMI is only consulted at launch; the root volume is
    # independent of it.
    ignore_changes = [ami]
  }

  # "standard" mode instead of "unlimited", which is the default for T3/T3a.
  # Unlimited charges extra when the CPU bursts past its accrued credits - under
  # predictable load that is a surprise bill, not performance.
  credit_specification {
    cpu_credits = "standard"
  }

  tags = merge(var.tags, {
    Name = var.name
  })

  # The primary ENI does not inherit these tags - there is no argument for that
  # on aws_instance. SOLVED on 10/20 by the aws_ec2_tag below, which does not
  # require declaring a separate aws_network_interface nor recreating the
  # instance.
}

# ---------------------------------------------------------------------------
# Name tag for the primary ENI
#
# WHY THIS RESOURCE EXISTS: aws_instance has no argument to tag the primary ENI,
# which it creates implicitly. The document recorded this as an "accepted gap",
# with the alternative being to declare aws_network_interface and attach it -
# which REPLACES the instance, because the primary ENI cannot be swapped after
# launch.
#
# aws_ec2_tag manages ONE tag on any EC2 resource by ID. Combined with the
# primary_network_interface_id attribute, it closes the gap without recreating
# anything.
#
# ONLY the Name tag, on purpose. An ENI has no cost, so the cost-allocation tags
# would have no consumer - and the ENI is OUT of scope of the Config
# required-tags rule by decision. Ten aws_ec2_tag in state for a cost split that
# does not exist would be noise. If one day the others are needed, just a
# for_each over merge(var.tags, { Name = ... }).
#
# WATCH OUT: aws_ec2_tag is ONE tag per resource. It is not a substitute for a
# tags block - it does not remove a tag someone created outside of it.
# ---------------------------------------------------------------------------

resource "aws_ec2_tag" "eni_name" {
  resource_id = aws_instance.this.primary_network_interface_id
  key         = "Name"
  value       = "${var.name}-eni"
}

output "instance_id" {
  value = aws_instance.this.id
}

output "private_ip" {
  description = "Should be in 10.20.1.x if the subnet is correct"
  value       = aws_instance.this.private_ip
}
