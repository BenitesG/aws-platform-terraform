# ---------------------------------------------------------------------------
# modules/ec2-instance/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Resource name, following the pattern acme-{scope}-{environment}-{purpose}"
  type        = string
}

variable "hostname" {
  description = "Operating system hostname (e.g. SWE-P-APP01). Empty = leave unchanged."
  type        = string
  default     = ""
}

variable "ami_id" {
  description = <<-EOT
    Golden image ID.

    PINNED ON PURPOSE, not looked up by a data source with most_recent.

    If it were looked up dynamically, a new image build would change the value
    and the next "terraform apply" would DESTROY AND RECREATE the instance -
    taking everything on the disk with it. For a server with data, that is loss,
    not an update.

    Changing images must be a deliberate act: you change this variable knowing
    the instance will be replaced.
  EOT
  type        = string
}

variable "instance_type" {
  description = <<-EOT
    Instance type. Must match the AMI's architecture.

    The golden image is amd64, so it works with t3, t3a, m5, c5 and the like -
    it does NOT work with t4g (ARM/Graviton).

    t3a is ~10% cheaper than t3 with the same specs.
  EOT
  type        = string
  default     = "t3a.small"
}

variable "subnet_id" {
  description = "Subnet. The private-d one has egress through the NAT; the public ones have NO route to the outside."
  type        = string
}

variable "instance_profile" {
  description = "Instance profile name. Without it the SSM agent does not register and the instance is UNREACHABLE."
  type        = string
}

variable "root_volume_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 20
}

variable "enable_termination_protection" {
  description = "Termination protection. true for a durable instance, false for a disposable one."
  type        = bool
  default     = true
}

variable "key_name" {
  description = <<-EOT
    AWS key pair name. Empty (default) = no key pair.

    When set, cloud-init injects the PUBLIC key into
    ~ubuntu/.ssh/authorized_keys on the first boot. The private key never
    passes through AWS.

    IMMUTABLE after launch: you cannot attach a key pair to an existing
    instance. Changing this value REPLACES the instance.

    Does NOT open a network path. The instances have no public IP and the subnet
    has no route to the IGW - SSH arrives through the SSM tunnel
    (AWS-StartSSHSession), which does not require an ingress rule on the security
    group.

    And it is NOT an emergency escape hatch: the tunnel goes through the SSM
    agent. If SSM fails, the key pair does not help. For that, see "Emergency
    access" in this directory's README.
  EOT
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC where this instance's security group is created"
  type        = string
}

variable "extra_security_group_ids" {
  description = <<-EOT
    ADDITIONAL security groups, beyond the instance's own.

    Empty by default: the decision is ONE SG PER MACHINE, because a shared SG is
    a shared RULE - a rule added for one machine would apply to every other one
    using the same SG.

    Use it for legitimate sharing cases, such as an SG carrying the rule of an
    integration valid for a group of machines.
  EOT
  type        = list(string)
  default     = []
}

variable "integration_ingress_rules" {
  description = <<-EOT
    INGRESS rules specific to this machine. Empty by default.

    WATCH OUT - THIS CHANGES THE PREMISE OF THE EMPTY-INGRESS DESIGN. The
    original design was "empty ingress": nothing reaches the instance, access
    only through Session Manager. Every ingress declared here is a deliberate
    exception, and needs:

      - cidr_ipv4 per HOST (/32), never a wide range nor 0.0.0.0/0
      - a description saying WHY the port exists - it is the only place that
        records the reason, and a wrong description misleads whoever reviews it
        later

    The map key becomes the address in Terraform's state. Do NOT rename a key
    after it is applied: Terraform would see a removal plus a creation, and
    recreating a rule of an integration in use drops traffic.

    For ICMP, from_port is the TYPE and to_port is the CODE; -1 in both = all.
  EOT
  type = map(object({
    description = string
    ip_protocol = string
    from_port   = number
    to_port     = number
    cidr_ipv4   = string
  }))
  default = {}
}

variable "integration_egress_rules" {
  description = <<-EOT
    EGRESS rules specific to this machine, beyond the default 443/80.

    MIND THE LATERAL MOVEMENT RISK: egress restricted to 443/80 exists to
    prevent lateral movement - with the peering active, the instance cannot
    reach a production database on 3306/1433/5432. Opening a database port here
    UNDOES the mitigation. If it is unavoidable, restrict it to the /32 of the
    destination and record the exception in the journal.

    Same rule about the map key: do not rename it after it is applied.
  EOT
  type = map(object({
    description = string
    ip_protocol = string
    from_port   = number
    to_port     = number
    cidr_ipv4   = string
  }))
  default = {}
}

variable "tags" {
  description = <<-EOT
    Standard tags, applied to the instance, the root disk and the security
    group.

    PASS THIS MACHINE'S FULL MAP, not just the common part. Project, Application
    and Environment vary per instance - the same machine can be prod today and
    nonprod later, and two different services do not share an Application.

    The provider's default_tags covers what is genuinely common to the directory
    (Owner, Department, CostCenter, DataClassification, ManagedBy, ChargeType);
    what varies comes from here and OVERRIDES it, because a resource tag beats
    default_tags.

    GAP: the primary ENI does not receive these tags - there is no argument for
    that on aws_instance. See the note on the resource.
  EOT
  type        = map(string)
  default     = {}
}
