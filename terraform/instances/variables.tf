# ---------------------------------------------------------------------------
# instances/variables.tf
# ---------------------------------------------------------------------------

variable "aws_profile" {
  description = "AWS CLI profile (SSO)"
  type        = string
}

variable "region" {
  description = "Region"
  type        = string
  default     = "us-west-2"
}

variable "private_subnet_id" {
  description = "acme-swe-prod-private-d. The public subnets have NO route to the outside."
  type        = string
}

variable "vpc_id" {
  description = "VPC where the instances' security groups are created"
  type        = string
}

# Deliberately unused: kept as the documented reference to an SG that exists
# in the account. See the description below.
# tflint-ignore: terraform_unused_declarations
variable "baseline_security_group_id" {
  description = <<-EOT
    acme-swe-prod-baseline-sg: empty ingress, egress TCP 443 and 80.

    NO LONGER USED by the instances in this directory. Since 10/16 each machine
    has ITS OWN security group, created by the module - a shared SG is a shared
    RULE, and a rule added for one machine would apply to all of them.

    Kept as a reference because the SG exists in the account (created in the
    console, following the empty-ingress security group design) and can be
    passed in extra_security_group_ids if one day a rule has to apply to a
    group of machines.
  EOT
  type        = string
}

variable "instance_profile" {
  description = "Instance profile of the baseline role (SSM + CloudWatch)"
  type        = string
}

variable "arm_ami_id" {
  description = <<-EOT
    AMI of the ARM64 golden image, for the t4g instance.

    FILL IN after the acme-base-ubuntu-2604-arm64 pipeline build. While it is
    empty, the arm01 module in main.tf stays commented out.

    To find it after the build:
      aws ec2 describe-images --owners self `
        --filters "Name=name,Values=acme-base-ubuntu-2604-arm64-*" `
        --query "sort_by(Images,&CreationDate)[-1].{AMI:ImageId,Arch:Architecture,Disk:BlockDeviceMappings[0].Ebs.VolumeSize}" `
        --output json --profile acme-swe-prod

    CHECK in the output: Arch must be arm64 and Disk must be 30. If x86_64 comes
    back, the AMI is from the wrong lineage and will not boot on t4g.
  EOT
  type        = string
  default     = ""
}

variable "arm_docker_ami_id" {
  description = <<-EOT
    AMI of the arm64 CONTAINER HOST lineage.

    DIFFERENT from arm_ami_id, which is the BASE: this one ships the Docker
    Engine with the log-rotation daemon.json (max-size 10m, max-file 3).

    USE on a machine that will run containers. Installing Docker by hand later
    reproduces the dataflow defect, which runs without rotation on a 30 GB
    disk - a failure mode whose only symptom is "the server stopped" with no
    obvious cause.

    FIXED ON PURPOSE, for the same reason as arm_ami_id: a data source with
    most_recent would make the next apply recreate the instance.

    To list the available images, see this directory's README under
    "How to create a new machine" > step 1.
  EOT
  type        = string
  default     = ""
}

# Deliberately unused: the fleet is entirely Graviton today. The variable is
# the declared interface for the x86 lineage, which the image factory does
# build. See the description below.
# tflint-ignore: terraform_unused_declarations
variable "x86_ami_id" {
  description = <<-EOT
    AMI of the x86_64 BASE lineage.

    MIND THE MINIMUM DISK SIZE: the x86 lineages have 20 GB, not 30 like the
    arm64 ones. The comment "minimum = arm64 AMI disk" in the Graviton machine
    blocks does not apply here.

    AND THE ARCHITECTURE DECIDES THE TYPE: an x86 AMI runs on t3a, t3 and m5 -
    it does NOT run on t4g, m6g or c7g. Getting this wrong is not an obvious
    error at launch.

    FIXED ON PURPOSE, for the same reason as arm_ami_id: a data source with
    most_recent would make the next apply recreate the instance.
  EOT
  type        = string
  default     = ""
}

# Deliberately unused, for the same reason as x86_ami_id.
# tflint-ignore: terraform_unused_declarations
variable "x86_docker_ami_id" {
  description = <<-EOT
    AMI of the x86_64 CONTAINER HOST lineage.

    Same relationship that arm_docker_ami_id has with arm_ami_id: this one
    ships the Docker Engine with the log-rotation daemon.json (max-size 10m,
    max-file 3). Use on an x86 machine that will run containers.

    Minimum disk size: 20 GB. Types: t3a, t3, m5.
  EOT
  type        = string
  default     = ""
}

variable "plc_workstation_host_cidr" {
  description = <<-EOT
    Industrial engineering workstation host as a /32, source and destination of
    the PROTOSIM protocol rules.

    WATCH OUT - THIS MACHINE IS NOT IN THIS ACCOUNT. Despite the name
    "acme-swe-nonprod-plc-workstation", the address belongs to 172.31.0.0/16,
    which is the VPC of the PRODUCTION account. Confirmed on 10/20:
    describe-network-interfaces in this account does not find the IP.

    The traffic leaves through the peering pcx-0b1b2b3b4b5b6b7b8, with a route
    to 172.31.0.0/16 in acme-swe-prod-rt-private. The OUTBOUND route exists; the
    RETURN route, on the production side, is an open pending item - without it
    the packet leaves and never comes back, and the flow log would show ACCEPT
    on egress with no reply.

    WHY IT IS A VARIABLE AND NOT A LITERAL: it is another team's infrastructure
    address and the repository is public - same reason as erp_host_cidr.

    /32 REQUIRED. A wider range would give the entire production VPC the
    industrial protocol ports.

    AN SG FROM ANOTHER ACCOUNT CANNOT BE REFERENCED here: the module accepts
    cidr_ipv4, not a security group ID. The original request mentioned an SG for
    the engineering workstation, which does not exist in this account.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.plc_workstation_host_cidr == "" || can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.plc_workstation_host_cidr))
    error_message = "Must be a single host as a /32, not a range."
  }
}

variable "erp_host_cidr" {
  description = <<-EOT
    Legacy ERP host in the production account, as a /32. Destination and source
    of the legacy ERP integration rules.

    WHY IT IS A VARIABLE AND NOT A LITERAL IN THE CODE: this is another team's
    infrastructure address, and the repository is public. It is the same reason
    terraform.tfvars is in .gitignore - the decision recorded there says that
    not versioning it "is not just secret hygiene: it is not publishing a third
    party team's infrastructure data".

    It was a literal in main.tf, in nine places, when the rules were written on
    10/16. Fixed BEFORE the first commit on purpose: git history is practically
    irreversible, and removing a value afterward would require rewriting history
    with a force push.

    /32 IS REQUIRED. A wider range would give the entire production VPC the
    integration ports, including inbound 65022 - and this machine's ingress only
    stopped being empty for this specific host.

    IF THE IP CHANGES: changing it here is NOT enough on its own if there is a
    DNS name in use, because a security group does not accept a name - only a
    CIDR or another SG. The coupling to the IP is in the firewall, not in the
    application.
  EOT
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.erp_host_cidr))
    error_message = "Must be a single host as a /32, not a range."
  }
}

variable "common_tags" {
  description = "Standard tags"
  type        = map(string)
}
