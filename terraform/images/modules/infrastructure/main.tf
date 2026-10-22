# ---------------------------------------------------------------------------
# modules/infrastructure/main.tf
#
# WHERE the build runs: role, instance profile, security group and the
# infrastructure configuration. Shared by all images.
#
# How a build works:
#   1. you trigger the pipeline
#   2. the Image Builder spins up a TEMPORARY EC2 instance from the parent AMI
#   3. that instance receives the instance profile declared here
#   4. the service sends commands into it VIA SSM - that is how the components
#      are applied
#   5. it shuts down, takes the AMI from the disk and destroys the instance
#
# The role is not yours nor the Image Builder's: it belongs to a machine that
# lives about 20 minutes and dies. That is why the instance profile is
# required and there is no "attach later" - you never get the chance to touch
# it.
#
# TWO MANDATORY ADAPTATIONS IN THIS ACCOUNT, both absent from the team's
# reference module:
#
#   1. permissions_boundary on the role. Without it the CreateRole is DENIED,
#      with an AccessDenied that does NOT mention the boundary
#   2. explicit subnet and security group. The reference module omits them and
#      falls back to the default VPC - which NO LONGER EXISTS in any region of
#      this account
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Build instance role
#
# Separate from delegated-ec2-ssm (the application instances') on purpose: the
# build machine needs permissions that an application server should not have.
# Merging them would make every instance in the company carry permission to
# build images.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "this" {
  # The "delegated-" prefix is REQUIRED, not a style convention. The
  # DelegatedAdminBoundary only allows creating a role, instance profile and
  # policy inside arn:aws:iam::*:role/delegated-*. Outside the prefix,
  # CreateRole is denied.
  name = var.role_name

  # Without this line the CreateRole is DENIED. The boundary requires that
  # every role created by delegation carry the boundary itself as a permission
  # ceiling - this is what prevents privilege escalation by whoever holds the
  # delegation.
  permissions_boundary = var.permissions_boundary_arn

  description = "Role of the temporary EC2 Image Builder build instance"

  # Half 1 of the role: WHO can wear it. Without a trust policy the role exists
  # but nobody can use it.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Half 2 of the role: WHAT it can do.
#
# EC2InstanceProfileForImageBuilder: download the component definitions and
# send logs.
resource "aws_iam_role_policy_attachment" "imagebuilder" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

# AmazonSSMManagedInstanceCore: register the instance with SSM. Without it the
# build sits waiting, because the service cannot run the components inside the
# machine.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The "hanger": a role cannot be attached directly to an EC2 instance, it has
# to live inside an instance profile. The console creates that object
# automatically with the same name as the role, which is why almost nobody
# knows it exists. In Terraform it is explicit.
resource "aws_iam_instance_profile" "this" {
  name = var.instance_profile_name
  role = aws_iam_role.this.name
}

# ---------------------------------------------------------------------------
# Build instance security group
#
# Dedicated, rather than reusing the acme-swe-prod-baseline-sg. Two reasons:
#
#   - separation of purpose: the application SG will GAIN an inbound rule when
#     the integration with the legacy ERP exists, with the peering to
#     production. The build instance has no reason to inherit that
#   - the name now says what it is for
#
# Inbound: NONE. The build is orchestrated by SSM, which works over an
# OUTBOUND connection from the instance itself - nothing is coming in.
# ---------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = var.security_group_name
  description = "Temporary Image Builder build instance: egress only"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.security_group_name
  }
}

# Rules as separate resources, not inline blocks.
#
# With inline "ingress"/"egress", Terraform takes ownership of ALL the SG's
# rules and removes any created outside it. As separate resources, management
# is per rule - and the plan shows exactly which rule changes.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "SSM, AWS API, component downloads and the Docker registry"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.this.id
  description       = "Ubuntu apt repositories (GPG-signed packages)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Infrastructure configuration
#
# The build instance goes in the PRIVATE subnet: it only needs EGRESS (for SSM
# and to download packages), and that egress exists through the NAT.
# ---------------------------------------------------------------------------

resource "aws_imagebuilder_infrastructure_configuration" "this" {
  name        = var.name
  description = var.description

  # Required field. Takes the NAME of the instance profile, not the ARN.
  instance_profile_name = aws_iam_instance_profile.this.name

  instance_types = var.instance_types

  subnet_id          = var.subnet_id
  security_group_ids = [aws_security_group.this.id]

  # resource_tags is DIFFERENT from tags.
  #
  #   tags           -> tag the infrastructure configuration itself
  #   resource_tags  -> tag the TEMPORARY build INSTANCE and its volume,
  #                     created by the Image Builder
  #
  # The provider's default_tags reaches neither of these: it applies to what
  # Terraform creates, and the build instance is created by the SERVICE.
  # Without this, the build hours would show up in the cost report with no
  # allocation.
  #
  # The build instance's Name is NOT overridden here: the service names it
  # "Build instance for <image>". Pinning a Name in this configuration would
  # be worse, because it is shared across images - the same name would apply
  # to every build.
  resource_tags = var.resource_tags

  # true: brings the instance down if the build fails, avoiding a forgotten
  # machine running and being billed, with the instance profile attached.
  #
  # The team's reference module uses false in the example, "for debugging". As
  # a default it is a trap: a build that fails overnight leaves an EC2 running
  # indefinitely. Switch to false TEMPORARILY when you need to investigate from
  # the inside.
  terminate_instance_on_failure = var.terminate_instance_on_failure

  # Optional notification. Reuses the acme-swe-prod-alarms alarm topic when
  # passed.
  sns_topic_arn = var.sns_topic_arn

  # S3 logging is OPTIONAL and off by default.
  #
  # The Image Builder already writes the component log to CloudWatch Logs, in
  # /aws/imagebuilder/<image-name>, with no configuration at all - and that is
  # where the diagnosis of the builds that failed in the first cycles came
  # from.
  #
  # The team's reference module creates a bucket per infrastructure
  # configuration with bucket_prefix, generating a name with a random suffix
  # that does not follow acme-{scope}-{environment}-{purpose}. We prefer not to
  # create a bucket.
  dynamic "logging" {
    for_each = var.s3_logs_bucket != null ? [1] : []

    content {
      s3_logs {
        s3_bucket_name = var.s3_logs_bucket
        s3_key_prefix  = var.s3_logs_prefix
      }
    }
  }
}
