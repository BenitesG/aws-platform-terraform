# Golden images — EC2 Image Builder

Pipeline that produces the fleet's **standardized base image**, with EC2 Image
Builder, in `us-west-2`. Four lineages: base image and container host, in x86
and arm64.

This README prioritizes the **traps** and the **engineering decisions** — that
is what has value for whoever maintains or reuses the pattern. The internal
chronology has been condensed; what remains is the reasoning.

---

## What a golden image is

A custom AMI, built from an official AMI, with the customizations already
applied. A new instance comes up ready. If you think in Docker, the **parent
image** is the `FROM` and the **components** are the `RUN`s.

What happens in a build:

1. the Image Builder spins up a **temporary** EC2 instance from the parent image
2. applies the components **in the recipe's order**, via SSM
3. runs the test phase on an instance launched from the already-built AMI
4. shuts down, takes the AMI, **destroys the temporary instances**

The build instance is destroyed **always** — on success it is part of the
cycle, on failure via `terminate_instance_on_failure = true`. What persists is
the AMI and its EBS snapshot.

---

## The four lineages

| Lineage | Disk | `Application` | Parent image |
|---|---|---|---|
| `acme-base-ubuntu-2604` | 20 GB | `ubuntu-2604-x86` | Canonical amd64 |
| `acme-base-ubuntu-2604-arm64` | 30 GB | `ubuntu-2604-arm64` | Canonical arm64 |
| `acme-docker-host-ubuntu-2604` | 20 GB | `docker-ubuntu-2604-x86` | our x86 base |
| `acme-docker-host-ubuntu-2604-arm64` | 30 GB | `docker-ubuntu-2604-arm64` | our arm64 base |

**YOU CANNOT STACK ACROSS ARCHITECTURES.** Each container host starts from the
base of its **own** architecture — the architecture is baked into the AMI, and
an x86 image does not boot on `t4g`. That is why there are four lineages and not
three.

### Our own components

| Component | Version | What it does | Used by |
|---|---|---|---|
| `acme-timezone` | 1.0.1 | `America/Sao_Paulo` timezone **and AWS time source** | the 2 bases |
| `acme-cleanup` | 1.0.2 | SSH port 65022, `apt clean`, `bash_history` | all 4 |
| `acme-docker` | 1.0.2 | Docker Engine, `daemon.json` with `log-opts` and `live-restore` | the 2 hosts |

**Which component gets a change decides how many recipes the apply replaces.**
Putting the clock fix in `acme-timezone` (used only by the bases, with the
children inheriting by stacking) instead of `acme-cleanup` (used by all four)
saved two recipe replacements.

### Why the ARM64 container host lineage exists

An integration worker runs on `t4g`, was born from the arm64 base and had
**Docker installed by hand**, because there was no ARM container host image. The
consequence: it runs **without the component's `daemon.json`** — without log
rotation (`max-size 10m`, `max-file 3`) on a 30 GB disk. A container that logs a
lot fills the disk and brings the machine down, with the symptom "the server
stopped" and no obvious cause. The lineage fixes it for a **new** machine; the
existing one needs a fix by hand or to be recreated.

**The components did not need adaptation.** `docker.yml` builds the repository
line with `$(dpkg --print-architecture)`, so it resolves `arm64` on its own; the
others are shell scripts. And a build reaching `AVAILABLE` proves more than "it
built": the `validate` phase of `acme-docker` rejects it if the `daemon.json`
did not take effect.

### The chain, and its cost

```
Canonical Ubuntu 26.04   (public SSM parameter)
        │
        ▼
acme-base-ubuntu-2604         update-linux · timezone · cloudwatch-agent · cleanup
        │
        ▼
acme-docker-host-ubuntu-2604  update-linux · docker · cleanup
```

**Stack, don't repeat.** The container host's parent image is the AMI of our
base, so it is *guaranteed* to be the base plus Docker — not "the two built with
the same components on different dates", which could start from different patch
levels. The sentence you want to be able to say: "every server is the base
image; some have more stuff".

**The cost of the chain:** the Docker image is as old as the base it started
from, and rebuilding the base does **not** update the child on its own. Updating
is a deliberate act — changing `base_ami_id` in the `tfvars` and bumping the
`recipe_version` of the Docker lineage.

**The container host does not repeat `acme-timezone` nor the CloudWatch agent**
(they already came from the base), **but it does repeat `acme-cleanup`** — the
build instance is born from the base AMI and generates a **new** identity on the
first boot (SSH keys, `machine-id`, cloud-init). Without running the cleanup
again, that identity would go into the snapshot.

**Docker does not go into the base image, on purpose:** the daemon runs as root
and belonging to the `docker` group is equivalent to being root — you can mount
the host filesystem inside a container. It should not be on a server that does
not need it.

---

## Prerequisites and usage

Terraform >= 1.10. AWS CLI with SSO configured.

The `terraform.tfvars` points `aws_profile = "acme-swe-prod-admin"` because this
directory **creates a role and an instance profile**, and `PowerUserAccess` has
neither `iam:GetRole` nor `iam:GetInstanceProfile`. Without those **reads** the
`apply` fails *after* creating the resource, leaving an orphan object outside
the state. The **backend**, on the other hand, uses the `AWS_PROFILE`
environment variable and only needs S3, which PowerUser has — explicit
configuration in the provider beats the environment variable, so the two halves
coexist.

```bash
terraform init
terraform plan
terraform apply

# a build is an action, not state — it does not come out of Terraform:
aws imagebuilder start-image-pipeline-execution \
  --image-pipeline-arn "$(terraform output -raw base_pipeline_arn)" \
  --profile acme-swe-prod
```

Follow it (`BUILDING` → `TESTING` → `AVAILABLE`, 15 to 25 min) with
`list-image-pipeline-images`. On failure, the `state.reason` names the component
and `list-workflow-step-executions` the step; the full log is in CloudWatch Logs
in `/aws/imagebuilder/<image-name>`. To investigate from the inside, switch
`terminate_instance_on_failure` to `false` temporarily.

### After EVERY build: tag the *image* resource — MANDATORY STEP

**A build does not end at `AVAILABLE`.** It ends after this, and forgetting
gives no error at all.

```bash
aws imagebuilder tag-resource \
  --resource-arn "arn:aws:imagebuilder:us-west-2:111122223333:image/<name>/<version>/1" \
  --tags "acme:cost-allocation:Application=<lineage>" \
  --profile acme-swe-prod
```

Valid lineages, which **must match** the keys of `retention_lineages` in
`lifecycle.tf`: `ubuntu-2604-x86`, `ubuntu-2604-arm64`,
`docker-ubuntu-2604-x86`, `docker-ubuntu-2604-arm64`.

**Why this exists:** the retention policy selects by tag on the **Image Builder
*image* resource** — not on the output AMI — and the *image* resource is **born
without tags**. An image without the tag falls **outside** the policy: it runs,
finds nothing, deletes nothing and **does not complain**.

> **TRAP: `describe-images` does not serve for this verification.** With the
> `ami_tags` aligned in the code, every build is born with the **AMI correctly
> tagged** and the ***image* resource empty**. Looking at the AMI gives **false
> confidence**. Check with `list-tags-for-resource` on the ARN of the *image*
> resource.

**As long as the tagging is manual, do not turn on scheduling** of the
pipelines: a scheduled build goes unwatched, and the omission is silent by
design. A Lambda that copies the recipe's tags to the *image* resource would
solve this generically — not yet implemented.

### Adding a new image

An image is **three `module` blocks** — recipe, distribution and pipeline — in
`images.tf`. You do not copy a file. There are three and not one because they
have **different lifecycles**: a new recipe does not require a new distribution,
and a distribution can be shared. To **stack** on top of the base, change only
the `parent_image` to its AMI — and remember that `acme-cleanup` runs again. The
`x.x.x` in the managed component ARNs is **not a placeholder**: it is the Image
Builder syntax for "the latest version".

---

## Traps

All discovered in practice, each one cost a build or an `apply`.

### CRLF replaces the components — the worst on this list

**The worst because `git status` shows a clean tree.** After a rebase, the
`plan` went from `No changes` to `Plan: 9 to add, 5 to change, 6 to destroy`,
wanting to replace **the three recipes and the three components**.

**Cause:** the rebase rewrote the working tree and `core.autocrlf = true` —
Git's default on Windows — converted `components/*.yml` from LF to **CRLF**. This
module reads those files with `file()` and feeds the content into the
component's `data` attribute. In a component **every argument is ForceNew**, so
different bytes become a replacement — and in cascade, because a replaced
component changes the ARN and the ARN is part of the recipe.

**Why you cannot trust `git status`:** git **normalizes** line endings when
comparing, so it sees no difference at all. Terraform sees it. Two tools reading
the same file and disagreeing about the content.

**What applying would have caused:** the AMIs reference the recipes, and
removing a referenced recipe returns `ResourceDependencyException`. With
`create_before_destroy` the removal comes last — the apply would create the new
component and recipe, fail on the destroy and leave partial `tainted` state.

**Fix:** files back to LF and **`.gitattributes` at the repository root** with
`*.yml text eol=lf`, so it does not recur on a fresh clone.

**The general rule:** a file whose **content becomes a resource attribute**
cannot depend on the checkout configuration of whoever cloned it. The risk class
is that of files read by `file()` or `templatefile()` — in this directory, only
`components/*.yml`.

**The relapse, and two lessons.** The fix was incomplete because a conversion
script ended the pipeline with `Select-Object -First 15` — and in PowerShell
that **interrupts the upstream pipeline**, not just the display. The conversion
stopped at 15 files. `Select-Object -First N` **is not `head`**. And `terraform
validate` **does not replace `terraform plan`** in finding drift: validate looks
at syntax and types, without talking to AWS or reading the state.

### The build SG has zero ENIs and is NOT orphaned

The build instance security group was **deleted from the console** by mistake;
without it **no build works**. The confusion: it shows up with **zero ENIs**,
just like an orphaned SG. But the build instance is **ephemeral** — zero ENIs
here means "no build running right now", not "nobody uses it". **How to tell
them apart:** look up the name in `terraform state list` before deleting
anything (or check the Terraform user agent in CloudTrail). Recovery is cheap:
`security_group_ids` is mutable, and the new ID is referenced by a variable.

### The parent AMI cannot come from the SSM parameter

Canonical's public parameter points to **"the current one"** and changes on its
own when they republish. Since `parent_image` is **ForceNew** in a recipe, using
the data source directly made Terraform want to **replace the base recipes** —
with no one having changed anything. And the replacement would **fail**, because
a recipe referenced by an already-built image cannot be removed. It is a mine
that goes off on its own every few weeks, in a `plan` you ran for something
else.

**Fix:** `base_parent_ami_amd64` and `base_parent_ami_arm64`, pinned in the
`tfvars`. The data source stays, but only as an **informational output** —
compare `*_em_uso` with `*_disponivel`. Updating is a deliberate act: changing
the value replaces the recipe, so bump the `recipe_version` along with it.

### The four tag layers, and who reads what

The confusion that cost the most time on this lineage:

| Layer | Comes from | Does retention read it? | Serves for |
|---|---|---|---|
| *image* resource | **manual `tag-resource`** | **YES — only this one** | the retention policy |
| output AMI | distribution `ami_tags` | no | inventory and Cost Explorer |
| snapshot | `ami_tags`, propagated | no | **cost allocation** — this is where the cost is |
| pipeline | `tags` in the module (`extra_tags`) | no | inventory only |

The asymmetry that matters: **tagging only the AMI does not reach retention;
tagging only the *image* resource is enough for it.** The snapshot receives the
tags from `ami_tags`, verified in practice — the documentation that said it
needed EventBridge plus Lambda was wrong. **Changing a tag in the console has an
expiration date:** on the AMI the **next build** undoes it; on the pipeline the
**next apply** undoes it. That is why the pipeline's per-lineage `Application`
went into the code, via `extra_tags`.

### `daemon.json` has to be written before the `apt install`

**Configuration that only applies to resources created after it does not apply
to what the daemon already created.** The `apt install docker-ce` **already
starts the daemon**. Writing the `daemon.json` afterwards and restarting, what
the daemon created on the first startup remains — that is what brought down build
1.0.0/1, when the component still pinned `default-address-pools`: `docker0`
already existed in `172.17.0.0/16` and was not recreated on the `restart`.
Writing it before, the first startup already reads the configuration.

### The address pool went back to the Docker default

Version 1.0.0 pinned `default-address-pools` at `10.100.0.0/16` and
`10.101.0.0/16`. **It was reverted, and the original justification was wrong.**
What was claimed: the default pool collides with the production VPC. Why it is
wrong: Docker allocates starting from `172.17.0.0/16` and goes up to `172.31`,
then `192.168.0.0/20`. Production is `172.16.0.0/16`, which is **not on the
allocation path**. Zero risk.

And the mechanism is not what intuition suggests: traffic leaving the container
goes through **MASQUERADE** and reaches the destination with the host's IP — the
container's IP never appears on the network. The problem would be at the
**destination**, a local route `172.x dev docker0` more specific than the VPC's,
but that would require dozens of simultaneous `docker-compose` networks. What
tipped the decision to go back to the default: fewer pieces to maintain, and
whoever debugs routing expects `172.17`.

### The validation checks the EFFECT, not the configuration

`ValidateDaemonTookEffect` exists because `cat daemon.json` proves only that the
file is on disk. `Live Restore Enabled: true` in `docker info` only shows up if
it came from the `daemon.json` — the Docker default is `false`. It serves as
proof of reading, and indicates that the `log-opts` (which prevents the disk
from filling) was also read, since they are in the same file.

Of the three build failures of this lineage, **one was a bug and two were the
checker itself** — a `grep -A3` that cut off before the `max-size` and rejected
correct configuration. Hence the rule: **a complicated checker becomes a source
of failure instead of a detector**. Prefer a simple check that proves the
effect.

### Double braces collide with the AWSTOE syntax

**Do not use `docker ... --format` in a component.** AWSTOE uses double braces as
its own parameter syntax, and the Docker Go template uses the same thing. With
`--format '{{ range .IPAM.Config }}'`, AWSTOE tries to resolve `.IPAM` as one of
its parameters and **the component creation fails** — it does not even get to run
a build (`Parameter 'IPAM' not declared but referenced`). Workaround: extract
from the JSON without a template —
`docker network inspect bridge | grep '"Subnet"' | head -1 | cut -d'"' -f4`.

### Validating the YAML locally requires Linux

```bash
curl -O https://awstoe-us-west-2.s3.us-west-2.amazonaws.com/latest/linux/amd64/awstoe
chmod +x awstoe
./awstoe validate --documents components/docker.yml
```

**The Windows binary does not work** for Linux components: it validates for the
host's platform and refuses `ExecuteBash` with
`Unsupported action ExecuteBash for os platform windows` — including for
components that have already built successfully. On Windows, run it through
**WSL**.

### `include_resources` requires explicit `containers` — and `is_public` too

In the retention policy, omitting `containers` makes the `apply` fail with
`Provider produced inconsistent result after apply`: the provider plans
`containers` as **unknown**, the API returns `false`, and since `policy_detail`
is a **set** the planned element does not correlate with the returned one. The
resource **IS created in AWS** even with the error, and it ends up `tainted`;
`terraform untaint` resolves it. Same bug in another field: `is_public = false`
in `exclusion_rules.amis`, which without declaring leaves the plan with a
**perpetual diff**.

**The general rule, for any block the provider treats as a set:** explicitly
declare every boolean field the API fills by default. If the plan insists on a
change you already applied, look for a `-> null` in the diff.

### `description` is also ForceNew

In `aws_imagebuilder_component` and `aws_imagebuilder_image_recipe`, **every**
argument forces a replacement, including the description. Adding a `description`
to a component created without one **replaces** it, changes the **ARN**, and the
recipe that references it is replaced in cascade — failing with
`ResourceDependencyException` if there is an image referencing the recipe. That
is why `acme-timezone`, `acme-cleanup` and the base lineage were left **without
a `description`**, with a comment in the code saying it is not an oversight.
**General lesson:** when moving an immutable resource into a module, the diff has
to be **zero** — any cosmetic "improvement" along the way becomes a replacement.
(That is why the refactor used `moved` blocks, which can only be removed
**after** the apply that consumes them.)

### Changing a component requires bumping TWO versions

Bumping the component **changes its ARN**, and the ARN goes into the recipe — so
the `recipe_version` is bumped along with it. Forgetting makes the `apply` not
change the recipe and the build keep using the old version, **with no error at
all**. And a new version is a **replace**; with `create_before_destroy = true`
the order is create the new one, point the pipeline at it, remove the old one —
but **the removal fails if there is an image version referencing the old one,
including a build that FAILED**. Delete the record with `delete-image` first.
Removal order: from the inside out — image, recipe, component.

### The Image Builder already sanitizes the image

The `RunSanitizeScript` step, automatic before the snapshot, deletes SSH host
keys and `authorized_keys`, zeroes `machine-id`, removes `/var/lib/cloud/*`, the
journal and logs. Cleaning identity **by hand is redundant in the Image
Builder** (required only on a manually made AMI). The `RemoveSshHostKeys`,
`ResetMachineId` and `CleanCloudInit` steps of `acme-cleanup` are left over from
that confusion and can go in a revision.

### Ubuntu 24.04+ uses socket activation for SSH

`ssh.socket` enabled, `ssh.service` disabled. In that mode the `Port` in
`sshd_config` is **ignored** — it is the systemd unit's `ListenStream` that
decides. Touching only `sshd_config` makes the build pass and SSH stay on 22,
**with no error at all**. The component writes to both places; in the override,
an empty `ListenStream=` before the new value clears the inherited list.
Confirmed on a real instance, with `systemd` (pid=1) next to `sshd` in
`ss -tlnp | grep ssh`, proving that socket activation is in use and the override
took.

**Harmless noise:** `sshd -t` fails on the build with `Missing privilege
separation directory: /run/sshd` (tmpfs, only exists with the service up, which
is disabled) — it is not a configuration error, which is why `acme-cleanup` only
prints a diagnostic. And `update-linux` complains about a missing
`amazon-ssm-agent` — on Ubuntu the agent is a snap and already ships in the AMI.

### The provider's `default_tags` does not reach everything

It applies to what **Terraform** creates. Resources created by the **service**
need their own field: the build instance and its volume use `resource_tags` in
the infrastructure configuration; the AMI **and the snapshot** use `ami_tags` in
the distribution configuration.

### The `delegated-` prefix is mandatory in IAM

The `DelegatedAdminBoundary` permissions boundary only allows creating a role,
instance profile and policy inside that prefix. And **every new role must carry
the boundary itself** (`permissions_boundary`), otherwise the `CreateRole` is
denied with an error that does not mention the boundary. A concrete case: the
retention policy needed `iam:PassRole` for `imagebuilder.amazonaws.com`, which
was not in the boundary's condition; the unlock **did not require a re-login** —
a change to a policy document is evaluated on the request, it does not stay in
the session token.

---

## Changing the Ubuntu version or the architecture

```hcl
ubuntu_version = "26.04"       # terraform.tfvars
architecture   = "amd64"       # or "arm64"
```

The image name is derived from the version (`acme-base-ubuntu-2604`), so
changing the version generates a **new lineage** — correct behavior: a different
OS version is not an update of the same image. **Use only LTS** (the interim
releases have 9 months of support). **Risk of the newest LTS:** third-party
repositories lag in publishing a package for the new codename.

The architecture is **baked into the AMI**: an `amd64` image does not run on
`t4g` and `arm64` does not run on `t3a`. Changing `architecture` requires
keeping the `build_instance_type` in step (Graviton for arm64).

---

## Structure and modules

```
images/
├── provider.tf           versions and profile (admin, because of the IAM)
├── backend.tf            remote state
├── variables.tf          variable declarations
├── terraform.tfvars      values — does NOT go to git (see .example)
├── main.tf               public parent AMI and our own components
├── infrastructure.tf     where the build runs (IAM, SG, infra config)
├── images.tf             the four lineages
├── outputs.tf            pipeline ARNs
├── lifecycle.tf          retention — 4 policies (one per lineage)
├── components/           timezone.yml · cleanup.yml · docker.yml
└── modules/
    ├── component/        one AWSTOE component
    ├── infrastructure/   IAM + SG + infrastructure configuration
    ├── recipe/           parent image + components + disk
    ├── distribution/     where the AMI goes and HOW IT IS TAGGED
    └── pipeline/         ties the three together
```

### Five modules, not one

Recipe, distribution and pipeline have **different lifecycles**: a new recipe
does not require a new distribution, and a distribution can be shared. A single
module wrapping all three would prevent stacking an image without duplicating
code. Four adaptations relative to a generic reference module, all mandatory in
this account:

| What | Why |
|---|---|
| `permissions_boundary` on the role | without it the `CreateRole` is **denied**, with an `AccessDenied` that does not mention the boundary |
| names with the `delegated-` prefix | the boundary only allows creating IAM inside it; the module **validates at the plan** |
| `subnet_id` and `security_group_ids` required | the generic one omits them and falls back to the default VPC, which **no longer exists in this account** |
| `distribution` module | without it the AMI and snapshot are born without `ami_tags`, and retention stops working **silently** |

### Why `.terraform.lock.hcl` is versioned

The lock pins the exact provider version and its hashes, ensuring that every
clone and the CI pipeline use the same provider. Without it, an `init` on a
different machine could pull a new version of the AWS provider and introduce
diffs or behavior changes with no one asking.

---

## Validate components locally, before the apply

A build costs 15 to 25 minutes to find a syntax error.

```bash
curl -O https://awstoe-us-west-2.s3.us-west-2.amazonaws.com/latest/linux/amd64/awstoe
chmod +x awstoe
./awstoe validate --documents components/docker.yml

# on a disposable machine, never yours:
sudo ./awstoe run --documents components/docker.yml --phases build,validate --trace
```

> **The `components/*.yml` must end in LF, not CRLF** — see the CRLF trap above.
> The `.gitattributes` at the repository root (`*.yml text eol=lf`) guarantees
> this on a fresh clone.
