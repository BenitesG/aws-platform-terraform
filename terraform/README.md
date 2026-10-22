# Infrastructure — AWS account `acme-swe-prod`

Terraform for the **`acme-swe-prod` (111122223333)** account, **us-west-2**
region, dedicated to the software engineering production environment.

Each directory is an independent configuration, with its own state. Start with
the README of the directory you are going to work on: that is where the
specific pitfalls live.

---

## Boundary: what is in code and what is not

**Not all of this account's infrastructure is here**, and that is deliberate.

The network — VPC, subnets, NAT Gateway, route tables, security groups, VPC
endpoint, flow logs — was built **in the console**, documented in prose, and
**remains outside Terraform**. It was not imported.

The rule adopted: **whatever is born from now on as shared infrastructure goes
into Terraform; whatever already exists stays in the console, documented.**

An explicit boundary does not produce drift. An implicit one does — someone
changes in the console what Terraform thinks it controls, and the next `apply`
undoes it.

**A nuance that looks like an exception but is not:** `network-peering/`
manages a route inside `rt-private`, which was created in the console. The
`aws_route` manages **a single route** in an existing route table, referenced
by ID — it does not require the table to be in the state. The table stays
outside Terraform; only that one route comes in.

---

## Directories

| Directory | What it does | State |
|---|---|---|
| `bootstrap/` | the S3 bucket that holds the Terraform state. **Runs once** | `bootstrap/terraform.tfstate` |
| `images/` | golden images with EC2 Image Builder | `images/terraform.tfstate` |
| `instances/` | EC2 instances from the golden image | `instances/terraform.tfstate` |
| `network-peering/` | VPC peering with the production account | `network-peering/terraform.tfstate` |

**Separate states on purpose:** a `terraform destroy` in `instances/` never
reaches the image pipeline, and none of them reaches the state bucket.

**The backend `key` must be unique per configuration.** Terraform does not
validate this. If two configurations use the same path, the second one to run
will think it owns the first one's resources — and a `destroy` would delete
another project's things.

---

## Getting started

> **Do not change `.gitattributes` without reading its comment.** The
> `*.yml text eol=lf` is not style: the Image Builder components are read with
> `file()` and the content becomes the `data` attribute, which is **ForceNew**.
> CRLF in one of those files makes Terraform want to replace the component and
> the recipe — and `git status` shows a clean tree, because git normalizes line
> endings when comparing. A real incident, detailed in `images/README.md`.

### 1. Terraform

Version **>= 1.10** — the S3 backend with `use_lockfile` (state locking
without DynamoDB) requires it. On Windows: `winget install HashiCorp.Terraform`.

### 2. AWS access

```powershell
aws configure sso
```

- Start URL: `https://<your-org>.awsapps.com/start`
- Region: `us-west-2`
- Registration scope: `sso:account:access` (default, just press Enter)

Two profiles are used:

| Profile | Permission set | When |
|---|---|---|
| `acme-swe-prod` | `PowerUserAccess` | day to day, and **always** on the backend |
| `acme-swe-prod-admin` | `DelegatedAdministrator` | wherever IAM is created (`images/`) |

Renew the session: `aws sso login --profile acme-swe-prod`
Check: `aws sts get-caller-identity --profile acme-swe-prod`

### 3. Before any `terraform init`

```powershell
$env:AWS_PROFILE = "acme-swe-prod"
```

**Required.** The `backend` block is initialized before the provider and has
its own credential chain — it **does not inherit** the `profile` from the
`provider` block. Without the variable: `No valid credential sources found`,
followed by a mention of an `EC2 IMDS role` that is just the last resort in the
chain timing out.

The variable only applies to the current terminal session. It is not hardcoded
on purpose: on the CI pipeline there is no SSO profile, and the credentials
come from other variables that Terraform also recognizes.

### 4. Order, the first time

`bootstrap/` → `images/` → `instances/`

The `bootstrap` creates the bucket that the others use as a backend. It runs
with **local state** first, because the state cannot live in a bucket that does
not exist yet; then it migrates into the bucket it created itself with
`terraform init -migrate-state`. Details in its README.

---

## Conventions

### Language

**Identifiers in English; comments, documentation and tag values in English
too.** It follows the Terraform and AWS documentation, which is where you look
for examples.

Renaming a resource later **is not just editing the text**: the name is the key
in the state, so it requires a `moved` block or `terraform state mv`, otherwise
Terraform destroys and recreates.

### Resource names

`acme-{scope}-{environment}-{purpose}` — for example `acme-swe-prod-dataflow`.
Operating-system hostnames follow a different pattern: `SWE-P-FLOW01`.

**IAM is the exception: it must start with `delegated-`.** Not style. The
`DelegatedAdminBoundary` permissions boundary only allows creating roles,
instance profiles and policies within that prefix. And **every new role must
carry its own boundary** in the `permissions_boundary` argument, otherwise the
`CreateRole` is denied with an error that does not mention the boundary.

### Tags

Internal tagging standard, applied via `default_tags` on the provider.

Required: `Name`, `Owner`, `Department`, `Environment`, `DataClassification`,
`Project`, `Application`.
Optional for now: `CostCenter`, `ChargeType`, `ManagedBy`.

The `DataClassification` value is one of `internal` or `sensitive`: `internal`
for ordinary workloads, `sensitive` for anything whose exposure would be a
problem — such as the state bucket, which can contain secrets in clear text.

**`Project` and `Application` vary by directory, on purpose.** The
`Application` describes **what the resource is**, not the project; the `Project`
tracks the **scope of what is being built**. There is no single account-wide
value:

| Directory | `Project` | `Application` |
|---|---|---|
| `bootstrap/` | `best-practices` | `terraform-state` |
| `images/` | `best-practices` | `golden-image` |
| `instances/` | `best-practices` | `baseline` |
| `network-peering/` | `infrastructure` | `network-traffic` |

> **Exception in `images/`:** the `Application` of `best-practices`/`golden-image`
> applies to what is common to the directory (roles, infrastructure configuration, components), but
> **the recipe, distribution and pipeline of each lineage carry the lineage value** —
> `ubuntu-2604-x86`, `ubuntu-2604-arm64`, `docker-ubuntu-2604-x86`. Reason: it is by this value that
> the retention policy selects, and with every lineage under `golden-image` the `COUNT` grouping
> became ambiguous. Details in `images/README.md`.

**Changing a cost-allocation tag value is cheap now and expensive later.** The
`acme:cost-allocation:*` tags have **not** been activated in the management
account yet; after activation, changing a value makes the same resource appear
under two names depending on the month, and billing history cannot be rewritten.

Three pitfalls:

**A key with a colon needs quotes in HCL.**
`"acme:cost-allocation:Project"`, not `acme:cost-allocation:Project`. Without
quotes the parser fails during `init`.

**`default_tags` only reaches what Terraform creates.** Resources created by
*services* need their own field — in Image Builder, `resource_tags` for the
build instance and `ami_tags` for the AMI.

**An instance tag does not propagate to the volume.** The disk is tagged in the
`root_block_device` block.

### State

**Never commit `*.tfstate` or `*.tfvars`.** They are already in the root
`.gitignore`. The state can contain sensitive values in clear text; the tfvars
too. Each directory ships a `terraform.tfvars.example` with placeholders.

The `.terraform.lock.hcl`, on the other hand, **must** go to git: it is what
guarantees everyone uses the same provider version. It has nothing sensitive —
only the provider name, the installed version, the constraint declared in the
code and checksums. Without it, the `~> 5.0` in `provider.tf` accepts any 5.x
and each machine may install a different version; the `zh:` entries also make
`init` fail if the package in the registry is altered.

> **The hashes are per platform.** The `h1:` recorded is from the machine that
> ran the `init`. A Linux runner fails `init` with a checksum error, which looks
> like a security problem rather than a platform one. To generate both:
>
> ```powershell
> terraform providers lock -platform=windows_amd64 -platform=linux_amd64
> ```

---

## What this repository does NOT cover

Built in the console and documented in prose:

- VPC `10.20.0.0/16`, four subnets, Internet Gateway
- NAT Gateway in **regional mode** with a manual EIP in us-west-2d
- Route tables — including the decision to leave `rt-main` with **only
  `local`**, so that "forgetting to associate" fails safely
- Security group `acme-swe-prod-baseline-sg`: empty inbound, outbound only
  443/80
- S3 VPC endpoint (gateway)
- VPC Flow Logs to S3, in Parquet, with a 25-field custom format
- The instances' `delegated-ec2-ssm` role
- Session Manager preferences and the sessions log group
- A US$ 150/month budget and the `acme-swe-prod-alarms` SNS topic
- Route 53 domain and ACM certificate

It is worth reading each directory's README before changing anything in the
network: several choices that look like omissions are deliberate.

---

## Blockers that depend on the organization administrator

1. ~~**`imagebuilder.amazonaws.com` in the `iam:PassedToService` condition**~~ —
   **RESOLVED.** The `v2` of `DelegatedAdminBoundary` swapped `StringEquals` for
   `StringLike` with `"image*"`. The golden images' retention policy is applied
   and **working**. **Caveat:** the wildcard widened the boundary more than
   necessary — it is worth proposing the narrow version in the next conversation
   with the administrator.
2. **`iam:CreateOpenIDConnectProvider`** — unblocks the CI pipeline assuming a
   role via OIDC instead of storing an access key.
3. **Activate the `acme:cost-allocation:*` cost-allocation tags**, with
   backfill. **Without it no tag appears in Cost Explorer**, no matter how
   correct the tagging is.
   > **Sequence:** do not request activation before the tag values are
   > finalized. After it, changing a value makes the same resource appear under
   > two values depending on the month, and billing history cannot be rewritten.
4. **A restricted engineering profile in SSO** — today only `Billing`,
   `DelegatedAdministrator` and `PowerUserAccess` exist.

---

## Cost

Recurring cost with no instances: **~US$ 36/month** — NAT Gateway (US$ 1.08/day,
verified in Cost Explorer) plus its Elastic IP. Taxes add ~16%. Account budget:
**US$ 150/month**.

The NAT is the dominant item and costs per idle hour, regardless of traffic.
