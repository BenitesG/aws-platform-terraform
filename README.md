# AWS platform in Terraform — golden image factory, EC2 and cross-account networking

[![terraform-ci](https://github.com/BenitesG/aws-platform-terraform/actions/workflows/terraform-ci.yml/badge.svg)](https://github.com/BenitesG/aws-platform-terraform/actions/workflows/terraform-ci.yml)

*[Versão em português](README.pt-BR.md)*

Production infrastructure for an AWS account, as code: a golden image pipeline
built on EC2 Image Builder, EC2 instances with no inbound port, cross-account
VPC peering, and a small purpose-built tool for VPC Flow Log forensics.

This is not a lab. It is an account that runs — with the decisions, and the
mistakes, recorded inside the code itself.

|  |  |
|---|---|
| **Terraform configurations** | 4, state isolated by blast radius |
| **Modules written here** | 6 |
| **Golden image lineages** | 4 — base and container host, on x86 and ARM/Graviton |
| **EC2 hosts** | 6, all Graviton, across two environments |
| **AWSTOE components** | 3, hand-written in YAML |
| **Network exposure** | no public IP, no port 22; inbound empty by default, exceptions always `/32` |
| **Recurring cost** | ~US$ 36/month against a US$ 150 budget |

---

## In 30 seconds: what this repository demonstrates

**Images that stack instead of repeating themselves.** The container host image
uses our own base AMI as its parent image. So it *is* the base plus Docker, at
the same patch level — not two images built in parallel that can drift apart.
The sentence I want to be able to say: *every server is the base image; some
have more on top.*

**A bug that `git status` would not show.** An LF-to-CRLF conversion in a YAML
file made Terraform plan the replacement of the entire image pipeline —
`9 to add, 5 to change, 6 to destroy` — with a clean working tree. Caught at
`plan`, before `apply`, and fixed in `.gitattributes`.

**Network diagnosis from data, not from reasoning.** Flow logs in Parquet,
queried with duckdb, gave the real reason instance clocks would not sync:
TCP 4460 blocked on egress by the security group, not NTP misconfiguration. The
earlier conclusion, reached by reasoning without measurement, was incomplete.

**Cost treated as a requirement, not as an outcome.** A retention policy per
image lineage, sized to preserve rollback while dropping the snapshot ceiling
from ~300 GB to ~200 GB. Without it the cost grows silently, with no alarm.

**A pipeline that holds no credentials.** Every push validates formatting,
syntax, language lint and policy-as-code across the four configurations —
with no AWS key in a secret, in a public repository where a fork can open a
pull request. On the first run tflint produced twelve findings and all twelve
were real: none of the six child modules declared a provider constraint of
its own. Fixed in the modules, not silenced in the config. Checkov's 27
findings went the other way — none were defects, so each exception is
recorded with its reason in `.checkov.yaml`.

**Comments that explain why, not what.** The `.tf` files record which trap each
argument avoids and which `apply` failed before. It is the kind of context that
usually dies in a chat log, kept where someone will read it again.

> **Sanitized version.** Company names, account IDs, IP addresses and internal
> system names were replaced with example values. The structure, the modules
> and all of the reasoning in the comments are intact — details at the
> [end of this file](#about-this-sanitized-version).

---

## Architecture

```
AWS account acme-swe-prod (111122223333) · us-west-2

terraform/bootstrap/        S3 bucket that holds Terraform state
                            versioning + SSE + prevent_destroy

terraform/images/           EC2 Image Builder
  Ubuntu 26.04 LTS (Canonical, via public SSM parameter)
    ├─► acme-base-ubuntu-2604 ────────┐  components: update-linux,
    │     └─► docker-host-x86         │  timezone, cloudwatch-agent,
    └─► acme-base-ubuntu-2604-arm64 ──┘  cleanup
          └─► docker-host-arm64
  + 4 lifecycle policies (COUNT=2, one per lineage)

terraform/instances/        6 × t4g (Graviton) in a private subnet
                            no public IP · no key pair by default
                            IMDSv2 required · one security group per host
                            plus one shared SG per environment for the
                            legacy-ERP integration
                            access through Session Manager

terraform/network-peering/  VPC peering ──► production account (444455556666)
                            requester side, route and DNS resolution
                            peer CIDR 172.31.0.0/16

tools/flowlog/              duckdb reading Parquet from S3
                            traffic forensics without standing up Athena

Underneath, built in the console and deliberately NOT in Terraform:
VPC 10.20.0.0/16 · four subnets · NAT Gateway · route tables · baseline SG
S3 gateway endpoint · Flow Logs in Parquet with a 25-field custom format
```

---

## Stack

**Terraform** >= 1.10 (S3 backend with `use_lockfile`, no DynamoDB) ·
**AWS provider** ~> 5.0 · **EC2 Image Builder** with AWSTOE components in YAML ·
**EC2** Graviton · **IAM** under a permissions boundary · **VPC peering** ·
**VPC Flow Logs** in Parquet · **Session Manager** · **Python + duckdb** ·
**GitHub Actions** with `fmt`, `validate`, **tflint** and **checkov** ·
**Ubuntu 26.04 LTS**

---

## Decisions worth explaining

These are the choices I would defend in a code review, with the reason rather
than the preference.

**An explicit boundary between the console and Terraform.** The network in this
account was built in the console before Terraform arrived, and I **did not
import it**. The rule became: anything created from now on as shared
infrastructure goes in code; what already exists stays in the console,
documented. An explicit boundary does not produce drift. An implicit one does —
somebody changes in the console what Terraform believes it owns, and the next
`apply` reverts it.

**Separate state per configuration.** Four backends with distinct `key` values.
A `terraform destroy` in `instances/` cannot reach the image pipeline, and
none of them can reach the state bucket. Terraform does not validate `key`
uniqueness: two configurations pointing at the same path will make the second
one believe it owns the first one's resources.

**A new file is organization; a new directory is isolation.** The criterion is
written in `instances/main.tf`, and it is not the resource type. Splitting
files is a human decision — Terraform concatenates every `.tf` in a directory
before interpreting it, and the state address carries no file name, so moving a
block between files changes nothing. A new directory means **new state**, and
it is only justified when at least one of three things is true: a different
blast radius (what must never be reached by an apply made for something else),
a different cadence (images are rebuilt monthly, instances change weekly,
peering almost never), or a different credential or owner (IAM needs the admin
profile because of `iam:PassRole`; networking depends on another team). "One
directory per resource type" is wrong in both directions — an instance, its
data volume and its EIP are three types with the *same* lifecycle.

The corollary showed up in practice. Renaming a **file** costs nothing, because
the file name never enters the state address. Renaming a **module label**
requires a `moved` block, because there the address *is* the resource's
identity — without it Terraform sees a new address to create and an orphan to
destroy. On one host that meant 14 resources, including the instance with its
in-use volume. With the block, the plan came out as
`0 to add, 0 to change, 0 to destroy` plus 14 moves.

**AMI pinned in tfvars, never `most_recent = true`.** It looks convenient and
it is dangerous. With a dynamic data source, a new image build changes the
value and the next `apply` — even one made for something unrelated — **destroys
and recreates** the instance, taking the disk with it. Changing images has to
be a deliberate act, not a side effect.

**Stacked images instead of repeated components.** The container host uses our
own base AMI as its parent. That makes it *provably* the base plus Docker,
rather than "two images built from the same components on different days",
which could start from different patch levels. The cost of that choice is real
and worth recording: it creates a dependency chain, because the container image
is only as fresh as the base it came from, and rebuilding the base does not
update the child on its own.

**One security group per host — and the exception, documented.** Instances used
to share a single group. The problem was not the name: **a shared security
group is a shared rule** — opening a port for one host would open it for all of
them. The group now lives inside the module, so "one per host" is the default
and does not depend on anyone remembering.

Then the integration rules forced the opposite conclusion, and that is the more
interesting half. The rules for the legacy ERP are not a property of any one
machine — they are a property of **the party on the other end**, and every host
in the fleet talks to it. Kept per host, they ended up duplicated in two files
and missing from two others, and revoking the ERP's access would have meant
remembering four places. So they moved into one shared security group **per
environment**, which is exactly the exception the module already anticipated in
`extra_security_group_ids`.

The price is written down next to the code: adding a rule there grants access
to *every* machine in that environment at once. The axis that decides where a
rule lives is the **party on the other end**, not the port number — the same
port had a different counterpart on different hosts, so splitting by port would
have granted new access to machines that never talk to that host. A rule that
applies to one machine only still lives in that machine's file.

**Security group rules as separate resources, not inline blocks.** With inline
`ingress`/`egress`, Terraform takes ownership of *every* rule in the group and
removes anything created outside of it. As separate resources, management is
per rule. This had a concrete consequence: nine integration rules were created
by hand during an incident and `plan` kept reporting "No changes" — with inline
blocks, the next apply would have deleted the whole integration. They were
imported afterwards, because a rule outside the code is an invisible rule.

**Image retention is a requirement, not a refinement.** Every build keeps an
EBS snapshot. Four lineages × 3 versions = up to 300 GB (~US$ 15/month) of
images nobody uses, growing with no alarm attached. I lowered it to
`COUNT = 2` — the minimum that preserves rollback ("current and previous") —
and the ceiling dropped to ~US$ 10/month. `COUNT = 1` was rejected: it would
delete the version that was known to work at the exact moment the new one
arrived.

**An instance with no inbound port, by default.** No public IP, no key pair,
empty security group ingress, egress restricted to 443/80. Access is through
Session Manager, which works because the SSM agent opens the connection **from
the inside out**. IMDSv2 is required, with `hop_limit = 1` so a container on
the instance cannot reach the metadata service.

Inbound is no longer empty everywhere: the fleet talks to a legacy ERP. Every
one of those rules is a declared exception, restricted to a single `/32`, with
a `description` stating why the port exists — because that is the only place
the reason is recorded for whoever reviews it later. No database port
(3306/1433/5432) was opened, which is precisely what the egress restriction
exists to prevent.

---

## Problems I actually diagnosed

My favourite part of the repository. Each of these cost time and left a lesson
that lives in the code, not only here.

### CRLF replacing infrastructure, with a clean `git status`

After a rebase, `core.autocrlf = true` (Git's default on Windows) converted the
component YAML files from LF to CRLF. Terraform reads those files with `file()`
and puts the content into the component's `data` attribute — where **every
argument is ForceNew**. The byte change turned into a cascading replacement: a
replaced component gets a new ARN, the ARN is part of the recipe, so the
recipes went too.

```
Plan: 9 to add, 5 to change, 6 to destroy
```

Applying that would have failed halfway through, because a recipe referenced by
an already-built image cannot be deleted. The worst detail: **`git status`
showed a clean tree**, because Git normalizes line endings when comparing. Two
tools reading the same file and disagreeing about its contents.

Fix: `.gitattributes` with `*.yml text eol=lf`. The general rule I took from
it — *a file whose content becomes a resource attribute must not depend on the
checkout configuration of the machine.*

### A CIDR that was passed along and never verified

Peering `active`, route `active`, and traffic to the other account timing out
**with no error message**. The route pointed at `172.16.0.0/16`; the
destination VPC used `172.31.0.0/16`. The value had been passed along in a
conversation and never checked at the source. With no specific route, traffic
fell through to `0.0.0.0/0` and left via the NAT.

The detail that completes the lesson: while the connection is pending, AWS
returns `null` for that field — it can only be confirmed after acceptance, via
`AccepterVpcInfo.CidrBlock`. Checking at the source is not a formality.

### The clock that would not sync

`timedatectl` reported `System clock synchronized: no` alongside
`NTP service: active`. The documentation had concluded that the security group
could not be involved, because the AWS time service lives at
`169.254.169.123`, link-local, which security groups do not filter. That
reasoning was **correct for the AWS service and incomplete**.

The flow log showed 81 outbound attempts on **TCP 4460** to six
`ntp-nts-*.canonical.com` destinations. NTS is NTP authenticated over TLS, and
its key exchange runs on 4460 (RFC 8915). The Ubuntu image ships five Canonical
pools marked `prefer`; with several preferred sources and only one reachable,
chrony was averaging the AWS source in without using it to correct.

Fix: a golden image component pinning `169.254.169.123` as the single source.
The alternative — opening 4460 — would have coupled the rule to six third-party
`/32` addresses and widened the egress restriction.

### `ACCEPT` in a flow log does not mean "it arrived"

A query for database ports returned `3306 ACCEPT`, `5432 ACCEPT`,
`1433 ACCEPT` — which looks like a serious violation. It was not. It was
internet scanning against the NAT's Elastic IP: 9,725 flows, 3,510 distinct
sources, 6,046 ports. A **NAT Gateway has no security group**, so everything
that hits it is logged as `ACCEPT` and then dropped by the NAT itself.

`ACCEPT` means permitted, not delivered. To assess an instance's posture,
filter by its ENI. That warning sits at the top of the script, because I fell
for it myself.

### A permissions boundary denying without naming itself

The account is administered by delegation, under a boundary that only allows
IAM objects under the `delegated-` prefix. Creating the retention policy failed
with:

```
AccessDeniedException: not authorized to perform iam:PassRole on
role/delegated-imagebuilder-lifecycle because no permissions boundary
allows the iam:PassRole action
```

The boundary restricted `iam:PassRole` to `ec2`, `lambda` and `ecs-tasks`,
while the lifecycle policy passes the role to `imagebuilder.amazonaws.com`.
Diagnosed with `simulate-principal-policy`, which confirms permission without
attempting an `apply`. Once the administrator published the fix, the existing
session was already sufficient — a change to a policy document takes effect on
the next call and does not require re-login.

I recorded a caveat alongside it: the fix used `StringLike` with `"image*"`,
which widened the boundary more than necessary. A narrow version would have
produced the same functional result.

### A complicated verifier becomes the failure

Of three builds that failed on one component, **one was a real bug and two were
the validation code itself** — a `grep -A3` whose window cut off before the
field and rejected a correct configuration. I reduced it to a single
deterministic check. Validation that fails on its own is not a detector, it is
noise.

### "It got here by copy-paste" is not a reason to delete it

I removed nine integration rules from one host, with the justification that
they had been copied over from another machine's block and did not belong. The
origin was right and the conclusion was wrong: what had arrived by copy-paste
was a **convention that had not been formalized yet**. That host does talk to
the legacy ERP, and the rules should have been there all along. I put them
back, and the fix was to give the convention a home of its own — the shared
security group — so that a shared rule no longer needs to be copied in order to
be replicated.

The lesson I keep from it: *"it got here by copy-paste"* explains **how** the
code arrived, not **whether** it should be there. The question I skipped was
"does this machine talk to that counterpart?" — not "where did this block come
from?" The warning against copying another machine's block still stands; it has
caught three real mistakes. This was the case where it misfired.

---

## Finding your way around

| Path | What to read there |
|---|---|
| [`terraform/README.md`](terraform/README.md) | conventions, tagging, access profiles, the console/code boundary |
| [`terraform/bootstrap/`](terraform/bootstrap) | the chicken-and-egg state bucket, solved in two steps |
| [`terraform/images/`](terraform/images) | the image factory: immutability, `create_before_destroy`, retention |
| [`terraform/instances/`](terraform/instances) | the EC2 module, one file per host, and the network security decisions |
| [`terraform/network-peering/`](terraform/network-peering) | cross-account peering and the wrong-CIDR episode |
| [`tools/flowlog/`](tools/flowlog) | traffic forensics with duckdb, without standing up Athena |
| [`docs/network-built-in-console.md`](docs/network-built-in-console.md) | the half of the account that is **not** in Terraform, and why |

The comments in the `.tf` files are long on purpose. They explain *why* the
code is the way it is — which trap the argument avoids, which apply failed
before.

> **One document deserves a callout.** The VPC, subnets, NAT Gateway, route
> tables, baseline security group, VPC endpoint and flow logs were built in the
> console and deliberately left out of Terraform.
> [`docs/network-built-in-console.md`](docs/network-built-in-console.md)
> documents what exists, the reasoning behind each choice — including a main
> route table kept at `local` only, so that "forgetting to associate a subnet"
> fails closed instead of handing out internet access — the exact 25-field
> flow log format, and the disaster-recovery consequence of that boundary.

---

## Running it

This repository **does not run against my account** — every identifier is an
example value. To point it at an account of your own:

```powershell
# 1. Terraform >= 1.10 (required by use_lockfile on the S3 backend)
winget install HashiCorp.Terraform

# 2. access
aws configure sso
$env:AWS_PROFILE = "acme-swe-prod"   # the backend does NOT inherit the provider profile

# 3. fill in the values
cd terraform/images
cp terraform.tfvars.example terraform.tfvars   # edit with your own IDs

# 4. first-time order: bootstrap -> images -> instances
terraform init
terraform plan
```

Each directory ships its own `terraform.tfvars.example` with every variable
commented. The real `.tfvars` files are in `.gitignore` — they carry
infrastructure IDs and do not belong in any repository.

---

## What is still open

I list these because a project with no known gaps is usually a project with no
inventory.

- **Retention does not select anything yet.** The policies are `ENABLED` and
  correct, but tag-based selection evaluates the Image Builder *image resource*,
  and that resource is created without tags — they propagate neither from the
  pipeline nor from the recipe. Today `tag-resource` is a manual step after each
  build. The Lambda that would automate it is designed and not implemented: with
  manual triggers and few images, tagging by hand is more honest than
  maintaining code.
- **Scheduled builds are off** on purpose, and stay off until tagging is
  automatic. A build nobody watches, combined with retention that selects
  nothing, equals a 20 GB snapshot accumulating in silence.
- **`terraform plan` in the pipeline** depends on
  `iam:CreateOpenIDConnectProvider`, which has not been granted yet. The CI
  that exists today runs everything that needs no credentials — `fmt`,
  `validate`, tflint and checkov across the four configurations. What is
  missing is the half that reads the real state, and the alternative — a
  long-lived access key in a secret, in a public repository where a fork can
  open a pull request — is worse than the gap.
- **The tflint AWS ruleset** is not enabled; only the bundled `terraform`
  ruleset runs. The AWS plugin catches invalid instance types and malformed
  ARNs — exactly the class of error that today only appears at `apply`.
- **Wide port ranges** on one host (400–1000/TCP) because of industrial
  protocol simulation. The risk is contained because the source is a single
  `/32` rather than a range — but narrowing it would reduce surface at no cost,
  once the ports actually in use are established.

---

## About this sanitized version

Replaced with example values: the company name, AWS account IDs, VPC, subnet,
security group, route table, peering, AMI, ENI and snapshot IDs, public and
private IP addresses, email addresses, domains, internal system names and
ticket references.

Kept: the entire structure of the code, the modules, the components, the
technical comments, the diagnoses and the decisions. Example IP ranges use
RFC 5737 (`203.0.113.0/24`) and account IDs follow the AWS documentation
convention (`111122223333`).

---

## 📜 License

This project is distributed under the MIT License. See [`LICENSE`](LICENSE) for
details.

