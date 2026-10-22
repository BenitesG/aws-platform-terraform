# ---------------------------------------------------------------------------
# network-peering/main.tf
#
# VPC peering between acme-swe-prod (111122223333) and the production account.
# Part of the VPC peering with production described in the internal action plan.
#
# HALF OF THE WORK IS IN THE OTHER ACCOUNT and cannot live here: we have no
# credentials on their side. Acceptance, the return route and "accepter DNS
# resolution" are manual steps performed by the production account owner.
#
# EXECUTION ORDER - there are TWO applies, on purpose:
#
#   apply 1 (now)    : creates the peering request
#   -> the other side ACCEPTS
#   apply 2 (later)  : route in rt-private + DNS resolution on our side
#
# Why not everything at once: the route and the DNS options require the
# connection to be ACTIVE. With the connection in pending-acceptance the apply
# would fail halfway through, with the request already created and the state
# partially applied.
# ---------------------------------------------------------------------------

# ===========================================================================
# STEP 1 - the request
# ===========================================================================

resource "aws_vpc_peering_connection" "production" {
  vpc_id = var.vpc_id # requester: acme-swe-prod

  peer_vpc_id   = var.production_vpc_id
  peer_owner_id = var.production_account_id

  # Same region (us-west-2), so peer_region is not declared. Declaring
  # peer_region equal to the provider region creates an INTER-region peering
  # and changes the cost: transfer starts being billed per GB.
  #
  # auto_accept only works when both VPCs are in the SAME account. Here the
  # acceptance is necessarily manual, in the production account.
  auto_accept = false

  tags = {
    Name = "acme-swe-prod-peering-production"
  }

  # The PENDING request expires in 7 days. If it expires, Terraform will see
  # the connection as "expired" and the next plan will propose recreating it -
  # which is the correct behavior, but means arranging a new window with the
  # other side.
  lifecycle {
    precondition {
      condition     = var.production_vpc_cidr != "10.20.0.0/16"
      error_message = "CIDR identical to acme-swe-prod's. AWS refuses peering with overlapping CIDRs."
    }
  }
}

# ===========================================================================
# STEP 2 - REACTIVATED ON 2026-10-16
#
# History, because it came and went twice:
#
#   10/15  applied for pcx-0c1c2c3c4c5c6c7c8
#   10/16  commented out - swapping the VPC destroyed the connection
#          (peer_vpc_id is ForceNew) and the new one was born in
#          pending-acceptance
#   10/16  reactivated - pcx-0b1b2b3b4b5b6b7b8 is active and accepted
#
# THE ROUTE WAS IMPORTED, NOT CREATED BY THIS CODE. It was made by hand during
# the diagnosis of the wrong CIDR, and brought into the state with:
#
#   terraform import aws_route.to_production "rtb-0a1a2a3a4a5a6a7a8_172.31.0.0/16"
#
# WHY IMPORT AND NOT DELETE-AND-RECREATE: there is REAL TRAFFIC going through
# this route. Import makes no call at all to AWS - it only writes the binding
# into the state - whereas delete-and-recreate would leave a window with no
# route.
#
# AND WHY IMPORT INSTEAD OF LEAVING IT OUT: a route outside the state is
# invisible to Terraform. The concrete risk: if the connection is replaced
# again, Terraform would destroy the connection and NOT the route, leaving a
# BLACKHOLE route pointing at a nonexistent peering - silently swallowing the
# traffic to 172.31.0.0/16. On 10/16 the opposite happened, and it was good:
# the route was in the state, Terraform destroyed it along with the connection
# and the table stayed clean.
# ===========================================================================

# ---------------------------------------------------------------------------
# Outbound route: from acme-swe-prod to production.
#
# It goes in rt-private because that is the table explicitly associated with
# private-c and private-d - the subnets where the instances live. rt-main is
# left with only "local" on purpose (the main route table is left with only
# "local" so that "forgetting to associate" fails safely) and does NOT receive
# this route.
#
# THE TABLE IS OUTSIDE TERRAFORM, AND THIS IS DELIBERATE. aws_route manages ONE
# route inside an existing table, referenced by ID - it does not require the
# table to be in the state. Do not confuse this EXPLICIT boundary with the
# route having ended up outside the state, which was an accident and has just
# been corrected.
#
# THIS ROUTE ALONE DOES NOT MAKE TRAFFIC FLOW. It needs the reciprocal route
# (10.20.0.0/16 -> the connection) in the production account. It exists - the
# integration has been working since 10/16 -, but it STILL NEEDS CONFIRMING in
# which of their route tables: the main table only applies to subnets with no
# explicit association.
# ---------------------------------------------------------------------------

resource "aws_route" "to_production" {
  route_table_id            = var.private_route_table_id
  destination_cidr_block    = var.production_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.production.id
}

# ---------------------------------------------------------------------------
# DNS resolution on OUR side (requester).
#
# By default peering does NOT resolve the other VPC's private DNS. The symptom
# is "the host does not exist" - it looks like an application error, not a
# network one.
#
# It only matters if the integration uses a NAME instead of an IP. Today the
# integration uses the IP directly (see erp_host_cidr in the instances/ tfvars),
# so this is dispensable for what already works. Turning it on has no cost and
# no side effect, and it avoids a future diagnosis if someone starts using a
# name.
#
# THIS IS THE ONLY RESOURCE THIS APPLY ACTUALLY CREATES: today the value in AWS
# is false, because it was destroyed along with the old connection.
#
# The accepter side mirrors this one and CANNOT be declared here: it would
# require production account credentials. It is a manual step on their side
# (Actions -> Edit DNS settings -> Accepter DNS resolution), and remains
# pending confirmation.
# ---------------------------------------------------------------------------

resource "aws_vpc_peering_connection_options" "requester" {
  vpc_peering_connection_id = aws_vpc_peering_connection.production.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

# ===========================================================================
# WHAT IS DELIBERATELY NOT HERE
#
# The SECURITY GROUP RULES (part of the integration with the legacy ERP).
# They depend on two answers from engineering we still do not have: who
# initiates the connection and on which port.
#
# The peering existing does NOT make any traffic flow - the security group
# decides that, and acme-swe-prod-baseline-sg still has empty ingress and
# egress restricted to 443/80. That is why creating the peering now is safe.
#
# Caution with the integration with the legacy ERP: opening the integration
# port is easy to reverse on paper and hard in practice. Once real traffic is
# flowing, closing it breaks the integration.
# ===========================================================================

output "peering_connection_id" {
  description = "Hand this to the production account owner - it is what they look for to accept"
  value       = aws_vpc_peering_connection.production.id
}

output "peering_status" {
  description = "pending-acceptance until the other side accepts"
  value       = aws_vpc_peering_connection.production.accept_status
}
