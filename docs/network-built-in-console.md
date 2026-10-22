# The account network — built in the console, on purpose

This repository has four Terraform stacks (`bootstrap/`, `images/`, `instances/`,
`network-peering/`). The account's **network layer is not one of them**. The VPC,
its subnets, the Internet Gateway, the NAT Gateway, the route tables, the baseline
security group, the S3 gateway endpoint, VPC Flow Logs, the instance IAM role,
Session Manager preferences, the budget and its SNS topic, and the DNS zone and ACM
certificate were all built in the AWS console and deliberately left out of code.

In the README this shows up as a list of bullets, which makes half the work look
like it was never done — as if "not in Terraform" meant "not engineered." It was
engineered. This document is where those decisions and their reasons live.

---

## 1. Why this is not in Terraform

There is an explicit management boundary behind this. Everything created **from now
on** as shared infrastructure goes into Terraform; everything that **already
existed** when the account was bootstrapped stays in the console and is documented
here. The network was built first, by hand, while the shape of the account was still
being decided — and it was never imported.

The reason is drift, stated as a rule: **an explicit boundary does not produce
drift; an implicit one does.** Importing the network into Terraform would mean
every manual touch — an extra route for a one-off peering, a security group rule
added during an incident — becomes a diff that someone has to explain or revert.
Keeping the network in the console and writing it down here keeps the Terraform
stacks honest: a `terraform plan` that returns `No changes` actually means no
changes, because the network simply is not in scope.

This is a decision with a cost, and that cost is the whole of section 5: the
network is the one layer that does not rebuild itself from code. This document is
written to be the runbook for that case, and it is the strongest argument for
importing the network one day.

---

## 2. What was built

The account lives in a single region, **us-west-2 (Oregon)**. Working AZs are
**us-west-2d** (instances and the NAT) and **us-west-2c** (reserved).

- **VPC** `acme-swe-prod-vpc` — `10.20.0.0/16`.
- **Four subnets**, named after the real AZ letter so the name never contradicts
  the zone:

  | Subnet | CIDR | AZ | Route table |
  |---|---|---|---|
  | `acme-swe-prod-private-d` | `10.20.1.0/24` | us-west-2d ← **instances** | `rt-private` (explicit) |
  | `acme-swe-prod-private-c` | `10.20.2.0/24` | us-west-2c | `rt-private` (explicit) |
  | `acme-swe-prod-public-d`  | `10.20.101.0/24` | us-west-2d | `rt-main` (implicit, `local` only) |
  | `acme-swe-prod-public-c`  | `10.20.102.0/24` | us-west-2c | `rt-main` (implicit, `local` only) |

  `10.20.3.0/24` through `10.20.100.0/24` are free for future private subnets.
  Auto-assign public IP is **off on every subnet**, including the public ones: the
  NAT uses an explicit Elastic IP and the future load balancer is managed, so
  nothing there needs an automatic address.
- **Internet Gateway** `acme-swe-prod-igw`, attached to the VPC.
- **NAT Gateway** `acme-swe-prod-nat` — **regional mode**, with a manually allocated
  Elastic IP in us-west-2d.
- **Route tables** — final state:

  | Route table | Routes | Association |
  |---|---|---|
  | `rt-main` | `10.20.0.0/16 → local` only | implicit (both public subnets) |
  | `rt-nat` | `local` + `0.0.0.0/0 → igw` | edge, tied to the NAT |
  | `rt-private` | `local` + `0.0.0.0/0 → nat` + S3 prefix list → gateway endpoint | explicit: `private-c` and `private-d` |

  `rt-public` was **not** created, on purpose — with a regional NAT there is no NAT
  sitting in a public subnet, and the public subnets are empty. When the load
  balancer arrives, its own route table gets built then.
- **Baseline security group** `acme-swe-prod-baseline-sg` — **empty inbound**,
  egress limited to TCP 443 and 80.
- **Default security group** — emptied to zero rules in both directions.
- **S3 VPC endpoint** — **Gateway** type, associated with `rt-private`.
- **VPC Flow Logs** to S3 in Parquet, custom format (section 3).
- **Instance IAM role** `delegated-ec2-ssm` (SSM + CloudWatch), with a matching
  instance profile.
- **Session Manager** preferences: a dedicated CloudWatch log group with 90-day
  retention.
- **Budget** of USD 150/month with an SNS topic `acme-swe-prod-alarms` for alarms.
- **DNS and certificate**: the `example.com` zone is hosted in Route 53 inside this
  account, and the single ACM certificate (ISSUED) covers the apex name.

---

## 3. The decisions worth explaining

### 3.1 `rt-main` keeps only `local` — the best network decision here

The main route table carries nothing but `10.20.0.0/16 → local`. This is a
deliberate act, not an omission. The main route table is the **implicit** destination
of any subnet nobody associated. Keeping it empty means that "forgot to associate a
subnet" fails **safely** — the instance has no route out — instead of silently
handing it a path to the internet.

This was validated by accident. During setup, a `0.0.0.0/0 → IGW` route had been
added to `rt-main` with the wrong table selected (both were unnamed at that moment),
which quietly made the two public subnets effectively public. It was spotted and
removed. Later, a test instance launched by mistake into a **public** subnet lost
all connectivity: the SSM agent never registered and the instance never showed up in
Fleet Manager — exactly the desired behavior. Had that stray IGW route still been
there, the instance would have come up in a public subnet **with a route to the
internet**, SSM would have connected normally, and nobody would have noticed the
mistake. An empty main table turns a silent misconfiguration into a loud,
fail-closed one.

### 3.2 NAT Gateway in regional mode, with a manual EIP

The NAT runs in **regional** mode with a single Elastic IP allocated by hand in
us-west-2d. The regional choice is validated on the bill: it is **not** charged per
AZ. See section 4 for the cost — this one line item dominates the account.

One trap worth recording: AWS does **not** pre-populate the IGW route on the NAT's
route table if the IGW is not attached at the moment the NAT is created. The NAT was
created before the IGW was attached, so that route had to be added manually. `Route
Origin` does not distinguish "you added it" from "AWS added it" — both read as
`Create Route`.

### 3.3 Baseline security group: empty inbound, egress only 443/80

Inbound is empty. Egress is restricted to TCP 443 and 80, not `All traffic`.

Against a competent attacker the egress restriction buys little — exfiltration rides
on 443 anyway. The real gain is **lateral movement**: once the production peering
exists, instances here cannot reach production databases (3306, 1433, 5432). That is
the mitigation this rule exists for.

DNS is not affected: security groups cannot block DNS requests to or from the Route 53
Resolver, so there is no need to open UDP 53. Port 80 is open only for the Ubuntu apt
repositories (packages are GPG-signed); 443 covers AWS APIs, SSM, and package
registries. Those reasons are written into the rule descriptions, because the rule
description is the only place that records **why** port 80 is open at all.

The default NACL is kept as-is. A NACL is stateless: a custom one would require
explicitly allowing the ephemeral return ports (1024–65535), and forgetting that is
the classic cause of "nothing downloads and nobody understands why." The protection
stays in the security group, which is stateful. A NACL only becomes necessary when
you need to **block** something, since security groups only have ALLOW rules.

### 3.4 S3 VPC endpoint — Gateway, not Interface

The S3 endpoint is a **Gateway** endpoint: free, route-based, reachable only from
inside the VPC. It was chosen over an Interface endpoint (which bills ~USD 0.01/h per
AZ plus ~USD 0.01/GB). The win is avoiding the NAT's data-processing charge on S3
traffic — same-region transfer to S3 was already free, so routing it through the NAT
would have been pure waste.

Cross-region is disabled: that is a PrivateLink/interface feature, and a gateway
endpoint does not support peering, VPN, or Transit Gateway anyway. The limitation to
remember: resources in the peered production account **cannot** use this endpoint;
they would need their own in their VPC.

### 3.5 Flow Logs — Parquet, custom format, 25 fields

Flow Logs go to S3 as **Parquet**, daily partitions, Hive-compatible prefixes on,
`All` filter, 10-minute aggregation. The log was first created with the default
format and then **recreated** with the custom format while traffic was still zero —
recreating in that window loses nothing; doing it after the first instance booted
would have left a gap in the most valuable window.

The field order matters because the Athena DDL has to mirror this sequence exactly:

```
${version} ${account-id} ${interface-id} ${srcaddr} ${dstaddr} ${srcport} ${dstport}
${protocol} ${packets} ${bytes} ${start} ${end} ${action} ${log-status} ${vpc-id}
${subnet-id} ${instance-id} ${tcp-flags} ${type} ${pkt-srcaddr} ${pkt-dstaddr}
${pkt-src-aws-service} ${pkt-dst-aws-service} ${flow-direction} ${traffic-path}
```

The 14 standard fields come first, in canonical order, so AWS's example DDL holds for
the leading columns and the extras only get appended at the end. In a custom format
**nothing is included by default** — you have to select the 14 basics too, and
without `srcaddr`/`dstaddr`/`action` the record is useless. Do not use *Select all*:
it pulls ECS fields that would sit empty.

Why each extra is there: `traffic-path` shows which way egress went (NAT, IGW,
peering, gateway endpoint) — it is the direct validation of the network design, and
the field that would have exposed the stray `0.0.0.0/0 → IGW` route on `rt-main`.
`tcp-flags` separates "connection refused" (SYN only) from "session established and
dropped." `flow-direction` saves having to infer direction by comparing IPs.
`pkt-dst-aws-service` confirms whether S3 traffic takes the gateway endpoint instead
of the NAT. `subnet-id` and `instance-id` remove the need to map `interface-id` by
hand. Dropped: `region`, `az-id`, the `sublocation-*` fields (one region, one AZ, no
Outposts/Local Zones — constants repeated per line) and the ECS fields.

A cold storage class was evaluated and rejected: it would cost **more**. IA and
Glacier IR bill a 128 KB minimum per object, and the Parquet files of an idle VPC are
only a few KB each — a ~25× penalty that inverts the per-GB discount — while Glacier's
90-day minimum equals the retention anyway. The real volume levers, if it ever
matters, are the **filter** (`All` → `Reject`) and the aggregation interval, not the
storage class.

### 3.6 Default VPCs deleted in every region

The default VPC in us-west-2 was deleted, and so were the default VPCs in every other
enabled region — a sweep across all 17 enabled regions with an `isDefault=true` filter
returned zero.

The practical consequence is the point: with no default VPC, any attempt to launch a
resource in those regions fails for lack of a network, which is the desired behavior.
It also means a stack that omits `subnet_id` and `security_group_ids` does not
quietly fall into a default VPC — there is nowhere to fall. The Terraform EC2 module
makes those arguments **required** precisely because the upstream pattern omits them
and lands in a default VPC that no longer exists anywhere in this account.

The side effect to remember: a managed service that silently assumes a default VPC
(some do) now fails in those regions. It is reversible — `aws ec2 create-default-vpc
--region <r>` recreates one.

### 3.7 `delegated-ec2-ssm` — baseline separated from specific

The instance role is named `delegated-ec2-ssm`, a generic name on purpose: it is a
**baseline** role, not an environment-specific one. It carries the SSM and CloudWatch
managed policies and nothing else. The S3 policy that a backup bucket would need is
deliberately kept **out** of this role.

The reasoning is the same one that later drove one security group per machine: a
**shared role is a shared grant**. Anything added to a baseline role applies to every
instance that assumes it, whether or not that instance needs it. Keeping the baseline
minimal and pushing specific grants into specific roles means the default is always
least-privilege, and nobody has to remember to trim it later.

---

## 4. What this costs

The recurring cost of the network is dominated by one line item: the NAT Gateway.

- **NAT Gateway: ~USD 1.08/day**, confirmed in Cost Explorer and stable across a
  measured window — exactly USD 0.045/h × 24. It is charged **per idle hour,
  regardless of traffic**, and it is **not** billed per AZ, which validates the
  regional-mode choice on the bill. That is roughly **USD 32.40/month** before any
  data processing.
- **Flow Logs: < USD 0.50/month** — about USD 0.33 of log delivery (vended logs at
  ~USD 0.25/GB, which applies independently of the storage class) plus ~USD 0.03 of
  storage at steady state. The flow log is roughly 1% of the NAT.
- **S3 gateway endpoint, Elastic IP (while associated), route tables, security
  groups, the VPC itself**: no hourly charge.

Everything else in the account's recurring spend is instances and EBS, not network.
The budget is USD 150/month for the whole account; the NAT is the single largest
fixed piece of it. An unassociated Elastic IP, by the way, bills ~USD 0.005/h
(~USD 3.65/month) from the moment it is allocated — one was created by mistake during
setup and released.

---

## 5. The disaster-recovery consequence

This is the part that does not rebuild itself from code, and therefore the strongest
argument for importing the network one day.

If this account were lost — deleted VPC, corrupted configuration, a region that has
to be stood up again — the four Terraform stacks would **not** bring the network back.
They assume the VPC, the subnets, the security groups, the NAT, and the route tables
already exist and reference them by ID. There is no `terraform apply` that recreates
`rt-main` with its deliberate `local`-only routing, the empty-inbound baseline
security group, the regional NAT and its Elastic IP, the S3 gateway endpoint, or the
custom-format flow log. All of that would have to be rebuilt **by hand, from this
document**.

So treat this file as the runbook. To rebuild from zero, in order:

1. Create the VPC `10.20.0.0/16` and the four subnets per the table in section 2,
   with auto-assign public IP **off** on all of them.
2. Create and attach the Internet Gateway **before** creating the NAT, so the NAT
   route table is populated automatically (see 3.2).
3. Create the regional NAT Gateway with a fresh Elastic IP in us-west-2d.
4. Build the three route tables exactly as in section 2 — and leave `rt-main` with
   `local` only. Associate `private-c` and `private-d` explicitly to `rt-private`;
   leave the public subnets implicit on `rt-main`.
5. Create the S3 **Gateway** endpoint and associate it with `rt-private`.
6. Create the baseline security group (empty inbound, egress 443/80 with the
   descriptions) and empty the default security group.
7. Recreate the Flow Logs with the custom format and the exact 25-field order in 3.5.
8. Recreate the `delegated-ec2-ssm` role and instance profile, the Session Manager
   log group, the budget and SNS topic, and the DNS zone and ACM certificate.
9. Only then do the Terraform stacks have something to attach to — update the IDs
   they reference and re-run them.

The honest admission: steps 1–8 are manual and this document is their only source of
truth. That is the cost of the management boundary in section 1, and the day that
cost feels too high is the day to import the network into its own Terraform stack.
