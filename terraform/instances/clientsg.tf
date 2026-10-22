# ---------------------------------------------------------------------------
# instances/clientsg.tf - security groups for the CLIENT (legacy ERP) integration
#
# One SG per ENVIRONMENT, carrying the legacy ERP rules that apply to EVERY
# machine in the fleet. Attached to the instances through
# extra_security_group_ids.
#
# A FILE, NOT A FOLDER: by the criterion recorded in main.tf, a new folder is
# for what is NOT recreated from code. A security group is in the RECREATABLE
# column - getting it wrong costs minutes, not data. Its own file because the
# two SGs read together and neither of them is a machine.
#
# ---------------------------------------------------------------------------
# WHY THIS SG EXISTS - AND WHAT IT INVERTS
#
# On 10/16 the decision was ONE SG PER MACHINE, with the reason recorded in the
# module: "a shared SG is a shared RULE". This here is the deliberate exception
# to that rule, and it is the exception the module itself anticipated in
# var.extra_security_group_ids.
#
# THE DIFFERENCE THAT JUSTIFIES IT: the legacy ERP rules do not belong to a
# machine, they belong to the interlocutor. Every machine in the fleet talks to
# the legacy ERP. Kept per machine, they were duplicated across two files and
# MISSING from two - and revoking the legacy ERP's access would mean remembering
# four places.
#
# THE PRICE, which has to be written down: adding a rule here grants access to
# ALL the machines in that environment at once. In nonprod there are three
# (dataflow, protosim, workbench). Whoever opens a port in this file is not
# touching one machine.
#
# A NEW RULE THAT APPLIES TO A SINGLE MACHINE still goes in
# integration_ingress_rules in THAT machine's file. The criterion is the
# interlocutor: if it is the legacy ERP and applies to everyone, it goes here.
#
# ---------------------------------------------------------------------------
# REVERTED DECISION - the nine legacy ERP rules out of workbench (10/20)
#
# On 10/20 the legacy ERP rules were REMOVED from workbench, with the reason
# "they came by copying the dataflow block and had no reason: this machine is a
# workbench, it does not take part in the integration".
#
# REVERTED ON 10/21. The legacy ERP rule is standard for every machine in the
# fleet - the workbench talks to the legacy ERP too, and it should have had the
# rule all along.
#
# THE WRONG REASONING, which is the part worth keeping: on 10/20 the rules were
# classified as COPY RESIDUE because they arrived by copy. The origin was right
# and the conclusion was wrong - what arrived by copy was a CONVENTION not yet
# formalized. "It came by copy" proves how the code got there, not whether it
# should be there. The question that was missed was "does this machine talk to
# the legacy ERP?", not "where did this block come from?".
#
# The pitfall "DO NOT COPY ANOTHER MACHINE'S BLOCK" still holds - it has really
# bitten three times. This file exists precisely so that the shared rule does
# not have to be copied in order to be replicated.
#
# ---------------------------------------------------------------------------
# DISCARDED DECISION - splitting baseline and specific BY PORT (10/21)
#
# The initial proposal was to leave 443, 80 and 65022 in the machine's SG and
# move only 5020-5023 and 5160-5161 over here. Discarded on two findings from
# the CLI:
#
#   1. the 443/80 egress to 0.0.0.0/0 is NOT in the machines' files - it is
#      fixed inside the module, so the uniform baseline already existed
#   2. the 443, 80 and 65022 INGRESS on dataflow comes from var.erp_host_cidr.
#      They are not baseline, they are legacy ERP rules with a similar-looking
#      port number
#
# And the port is not an axis for splitting, because the SAME port has a
# DIFFERENT interlocutor on each machine: 65022 came from the legacy ERP on
# dataflow and from the industrial engineering workstation on protosim. A
# uniform baseline of "65022 ingress" on the four machines would grant new
# access to someone that does not talk to that host - and a network grant does
# not error on apply nor show up in the plan summary.
#
# The correct axis is the INTERLOCUTOR: legacy ERP rule here, industrial
# engineering workstation rule in the protosim file, baseline in the module.
#
# ---------------------------------------------------------------------------
# THE ICMP DID NOT COME ALONG (10/21)
#
# The legacy ERP ICMP ingress existed on both dataflow machines and was
# REMOVED, not forgotten. Reason: no automated validation depends on it - the
# ping was a manual check in the console. This also closes the question of who
# initiates the connection as far as the "they ping us, we do not ping them"
# asymmetry goes, which stops being an open decision because the rule no longer
# exists.
#
# IF IT IS NEEDED BACK: one entry in local.erp_ingress_rules, ip_protocol
# "icmp", from_port and to_port -1 (which in ICMP are the TYPE and the CODE, not
# ports). The rule is mutable in place and does not replace the SG.
# ---------------------------------------------------------------------------

locals {
  # Names assembled once: they go into the SG name, the Name tag and the Name of
  # each rule. GroupName is IMMUTABLE on AWS - changing it here REPLACES the SG
  # and recreates the rules attached to it.
  nonprod_client_sg_name = "acme-swe-nonprod-client-sg"
  prod_client_sg_name    = "acme-swe-prod-client-sg"

  # Legacy ERP INGRESS. Same keys the dataflow maps used, on purpose: whoever
  # compares the before and after recognizes the rules one by one.
  #
  # DO NOT RENAME A KEY after it is applied - the key becomes part of the
  # resource's address in the state, and renaming destroys and recreates that
  # rule. Same warning that is in var.integration_ingress_rules.
  erp_ingress_rules = {
    # Legacy ERP SFTP/SCP. The port is 65022 because the golden image moves sshd
    # there - 22 does not listen on any image in this project.
    #
    # THE SG DOES NOT DISTINGUISH SFTP FROM SHELL: SFTP runs inside SSH, same
    # port and same protocol. Whoever reaches the port and has an authorized key
    # opens a shell too. Restricting file transfer is done in sshd
    # (ForceCommand internal-sftp in a Match block), not here.
    #
    # OPENING THE PORT IS ONLY HALF: the legacy ERP side needs an authorized key
    # on the machine. The way is to add THEIR public key to authorized_keys - do
    # NOT hand over the machine key pair's private key, which belongs to a single
    # machine by a decision from 10/15.
    #
    # THIS RULE REPLACES the sftp_plc_workstation on protosim, removed on 10/21:
    # protosim now does file transfer with the legacy ERP, not with the
    # industrial engineering workstation. CONSEQUENCE: the host 172.31.20.11/32
    # no longer reaches 65022 on protosim.
    erp_sftp = {
      description = "erp file transfer ssh"
      ip_protocol = "tcp"
      from_port   = 65022
      to_port     = 65022
      cidr_ipv4   = var.erp_host_cidr
    }

    erp_hub = {
      description = "erphub"
      ip_protocol = "tcp"
      from_port   = 5020
      to_port     = 5023
      cidr_ipv4   = var.erp_host_cidr
    }

    partner_hub = {
      description = "partnerhub (ip erp)"
      ip_protocol = "tcp"
      from_port   = 5160
      to_port     = 5161
      cidr_ipv4   = var.erp_host_cidr
    }

    # 443 AND 80 INGRESS ARE LEGACY ERP RULES, not baseline. The baseline is the
    # 443/80 EGRESS to 0.0.0.0/0, which the module declares as fixed. Same port
    # number, different direction and interlocutor.
    #
    # The descriptions of these two were SWAPPED - 443 said "erp http" and 80
    # said "erp https". Fixed on 10/21 in both files; the correct text comes
    # over here.
    erp_tcp_443 = {
      description = "erp https"
      ip_protocol = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_ipv4   = var.erp_host_cidr
    }

    erp_tcp_80 = {
      description = "erp http"
      ip_protocol = "tcp"
      from_port   = 80
      to_port     = 80
      cidr_ipv4   = var.erp_host_cidr
    }
  }

  # Legacy ERP EGRESS, BEYOND the 443/80 to 0.0.0.0/0 that the module declares on
  # every machine SG.
  #
  # THE SYMMETRY WITH THE INGRESS IS CORRECT (the question of who initiates the
  # connection, closed on 10/21): the traffic comes in and goes out on the same
  # ports because the communication is bidirectional on them, confirmed with
  # engineering. It is not a symptom of "we do not know who initiates the
  # connection".
  #
  # THE LATERAL-MOVEMENT RISK IS PRESERVED: no database port (3306/1433/5432),
  # and the destination is a single host as a /32.
  erp_egress_rules = {
    erp_sftp = {
      description = "erp file transfer ssh"
      ip_protocol = "tcp"
      from_port   = 65022
      to_port     = 65022
      cidr_ipv4   = var.erp_host_cidr
    }

    erp_hub = {
      description = "erphub"
      ip_protocol = "tcp"
      from_port   = 5020
      to_port     = 5023
      cidr_ipv4   = var.erp_host_cidr
    }

    partner_hub = {
      description = "partnerhub (ip erp)"
      ip_protocol = "tcp"
      from_port   = 5160
      to_port     = 5161
      cidr_ipv4   = var.erp_host_cidr
    }
  }

  # Tags for the two SGs. Project, Application and Environment are a per-resource
  # question, never inheritance - they override the provider's default_tags.
  #
  # Application = "client" and not the name of a machine: this SG does not belong
  # to any of them. If it inherited "dataflow", the inventory would say a
  # resource used by three machines belongs to one.
  #
  # NO RequestId, on purpose: the machines have the ticket that requested them
  # (req-4939, 4940, 4943, 4944) and this SG is not born from a single ticket.
  # CHECK whether the Config required-tags rule demands RequestId - if it does,
  # the resource shows up as NON_COMPLIANT and the field has to be filled in.
  nonprod_client_tags = merge(var.common_tags, {
    "acme:cost-allocation:Project"     = "erp-integration"
    "acme:cost-allocation:Application" = "client"
    "acme:automation:Environment"      = "nonprod"
  })

  prod_client_tags = merge(var.common_tags, {
    "acme:cost-allocation:Project"     = "erp-integration"
    "acme:cost-allocation:Application" = "client"
    "acme:automation:Environment"      = "prod"
  })
}

# ---------------------------------------------------------------------------
# Client SG - NONPROD
#
# Consumed by: nonproddataflow, nonprodprotosim, nonprodworkbench
# ---------------------------------------------------------------------------

resource "aws_security_group" "nonprod_client" {
  name   = local.nonprod_client_sg_name
  vpc_id = var.vpc_id

  # NEUTRAL DESCRIPTION, by the lesson recorded in the module: the description of
  # an IMMUTABLE resource must not carry a fact that changes. If it said which
  # ports it opens or which machines use it, it would either age into something
  # false or cost a replacement to fix. The reason for each port lives in the
  # RULE description, which is mutable in place.
  description = "Rules for the client (legacy ERP) integration - nonprod"

  lifecycle {
    # Required if this SG is ever replaced with an instance attached: without it
    # AWS refuses to destroy the old one with DependencyViolation and the apply
    # dies halfway through.
    #
    # A replacement here only happens if the NAME changes - and since the name
    # would change, there is no InvalidGroup.Duplicate collision.
    create_before_destroy = true
  }

  tags = merge(local.nonprod_client_tags, {
    Name = local.nonprod_client_sg_name
  })
}

resource "aws_vpc_security_group_ingress_rule" "nonprod_client" {
  for_each = local.erp_ingress_rules

  security_group_id = aws_security_group.nonprod_client.id
  description       = each.value.description
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = each.value.cidr_ipv4

  tags = merge(local.nonprod_client_tags, {
    Name = "acme-swe-nonprod-client-in-${each.key}"
  })
}

resource "aws_vpc_security_group_egress_rule" "nonprod_client" {
  for_each = local.erp_egress_rules

  security_group_id = aws_security_group.nonprod_client.id
  description       = each.value.description
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = each.value.cidr_ipv4

  tags = merge(local.nonprod_client_tags, {
    Name = "acme-swe-nonprod-client-out-${each.key}"
  })
}

# ---------------------------------------------------------------------------
# Client SG - PROD
#
# Consumed by: proddataflow, prodworkbench
#
# SAME RULES AS NONPROD TODAY, by request - and they are two SGs on purpose, not
# one shared. Being identical today is not an invariant: with a single SG,
# changing the rule to test it in nonprod would apply it to production in the
# same apply, and you lose the one place where the mistake is cheap. An SG has no
# cost, so there is no saving in unifying them.
# ---------------------------------------------------------------------------

resource "aws_security_group" "prod_client" {
  name        = local.prod_client_sg_name
  vpc_id      = var.vpc_id
  description = "Rules for the client (legacy ERP) integration - prod"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.prod_client_tags, {
    Name = local.prod_client_sg_name
  })
}

resource "aws_vpc_security_group_ingress_rule" "prod_client" {
  for_each = local.erp_ingress_rules

  security_group_id = aws_security_group.prod_client.id
  description       = each.value.description
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = each.value.cidr_ipv4

  tags = merge(local.prod_client_tags, {
    Name = "acme-swe-prod-client-in-${each.key}"
  })
}

resource "aws_vpc_security_group_egress_rule" "prod_client" {
  for_each = local.erp_egress_rules

  security_group_id = aws_security_group.prod_client.id
  description       = each.value.description
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = each.value.cidr_ipv4

  tags = merge(local.prod_client_tags, {
    Name = "acme-swe-prod-client-out-${each.key}"
  })
}

output "nonprod_client_security_group_id" {
  description = "Client SG for the nonprod machines"
  value       = aws_security_group.nonprod_client.id
}

output "prod_client_security_group_id" {
  description = "Client SG for the prod machines"
  value       = aws_security_group.prod_client.id
}
