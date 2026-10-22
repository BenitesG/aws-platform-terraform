# EC2 instances

Terraform for the project's EC2 instances, in the production account, region
**us-west-2**. The instances are born from a **golden image** (EC2 Image
Builder, see `../images/`) and are accessed **exclusively through Session
Manager** — no key pair, no open port 22 and no public IP.

There are **six instances**, each in **its own file** `.tf`, sharing a
**single state**. `main.tf` **receives no machine** — it is the directory map
and the template for a new machine. **The rule is for the file name to match the
`module` label**, so that when you read `module.nonprodprotosim.aws_instance.this`
in a plan or an error you know which file to open:

| File | Module | Name | Role |
|---|---|---|---|
| `nonproddataflow.tf` | `nonproddataflow` | `acme-swe-nonprod-dataflow` | development worker for the legacy ERP integration |
| `proddataflow.tf` | `proddataflow` | `acme-swe-prod-dataflow` | production worker for the integration |
| `nonprodprotosim.tf` | `nonprodprotosim` | `acme-swe-nonprod-protosim` | industrial protocol simulator |
| `prodprotosim.tf` | `prodprotosim` | `acme-swe-prod-protosim` | industrial protocol simulator (prod) |
| `nonprodworkbench.tf` | `nonprodworkbench` | `acme-swe-nonprod-workbench` | workbench |
| `prodworkbench.tf` | `prodworkbench` | `acme-swe-prod-workbench` | workbench (prod) |

> **One file is not a machine:** `clientsg.tf` carries the two security groups
> of the client (legacy ERP) integration — one per environment, shared by the
> machines through `extra_security_group_ids`. See "The shared client SG" below.

> **All six files match the label — no exception.** The label `dataflow`, which
> came from before the convention, was renamed to `nonproddataflow` on 10/21
> **with a `moved` block**. Renaming the `module` label without `moved` makes
> Terraform see a removal plus a creation and **destroys the instance** (14
> resources, with the disk along); `moved` rewrites the address in the state
> without touching AWS — the plan gave `0 to add, 0 to change, 0 to destroy` and
> 14 moves. Renaming a **file** needs nothing; renaming a **label** needs
> `moved`.

> **`nonprod` describes the role in the topology, not the criticality.**
> `dataflow` receives real traffic coming from the production account; shutting
> it down outside the agreed window interrupts a flow that production consumes.
> The private IP does not change with stop/start, so nothing breaks on that side,
> and a stopped instance is not charged for compute, only for the disk — but
> **do not start/stop it without agreeing first**.

## The design, in one pass

```
IT user ──SSO──> Session Manager ──> instance (private subnet)
                                         └─ egress 443/80 ─> NAT ─> IGW
```

The instance **accepts no connection from outside** by default: the security
group has **empty ingress**. All communication starts from the machine itself,
and Session Manager works because the SSM agent opens the connection from the
inside out.

---

## Prerequisites and access

Terraform **>= 1.10** (the S3 backend with `use_lockfile` requires it), AWS CLI
with SSO (`aws configure sso`; Start URL `https://<your-org>.awsapps.com/start`,
region `us-west-2`), and the golden image in `../images/`. Two profiles are
used:

| Profile | Permission set | What for |
|---|---|---|
| `acme-swe-prod` | `PowerUserAccess` | **the backend only** (it needs just S3) |
| `acme-swe-prod-admin` | `DelegatedAdministrator` | **this directory's provider** |

> **`aws_profile` must be the `DelegatedAdministrator` one, and this is not
> optional.** Attaching an instance profile to an instance requires
> `iam:PassRole`, and `PowerUserAccess` **does not have it** (the apply fails
> with `UnauthorizedOperation ... iam:PassRole on .../delegated-ec2-ssm`).
> Confirmed by `simulate-principal-policy`: `PowerUserAccess` → `implicitDeny`,
> `DelegatedAdministrator` → `allowed`. The `DelegatedAdminBoundary` allows
> `PassRole` for `role/delegated-*` passed to `ec2.amazonaws.com` — and that is
> why the role is called `delegated-ec2-ssm`.

**Before any `terraform init`:** `$env:AWS_PROFILE = "acme-swe-prod"`. This is
**not optional** — the `backend` block is initialized before the provider and
has its own credential chain; it does **not inherit** the `profile` from the
`provider` block. Without the variable, the error is `No valid credential
sources found`, with a mention of `EC2 IMDS role` that is just the last resort
of the chain timing out. The variable applies only to the current terminal
session.

---

## How to create a new machine

### 1. Decide three things before opening the editor

**The name**, following the pattern `acme-{scope}-{environment}-{purpose}` (e.g.
`acme-swe-prod-runner01`). It shows up on the instance, the disk, the SG and the
`Name` tags of every rule — getting it wrong spreads.

**The architecture**, which decides the type and the AMI together — they are not
independent choices:

| Image lineage | Variable | Valid types | Minimum disk |
|---|---|---|---|
| base arm64 (Graviton) | `var.arm_ami_id` | `t4g.*`, `m6g.*`, `c7g.*` | 30 GB |
| arm64 container host | `var.arm_docker_ami_id` | `t4g.*`, `m6g.*`, `c7g.*` | 30 GB |
| base x86 | `var.x86_ami_id` | `t3a.*`, `t3.*`, `m5.*` | **20 GB** |
| x86 container host | `var.x86_docker_ami_id` | `t3a.*`, `t3.*`, `m5.*` | **20 GB** |

**The minimum disk size changes with the architecture:** 30 GB on arm64, 20 GB
on x86. The comment `# minimum = arm64 AMI disk` in the Graviton machine blocks
does not apply on an x86 machine. And getting the architecture wrong (an x86 AMI
on `t4g`, or arm64 on `t3a`) fails at launch with a not-so-obvious message. If
the machine will run containers, use the **container host** lineage — it already
ships Docker with a log-rotation `daemon.json`.

**The three tags that are a question, never inheritance:**
`acme:cost-allocation:Project`, `acme:cost-allocation:Application` and
`acme:automation:Environment`. They go in the module block and **override** the
provider's `default_tags`.

### 2. Create ONE FILE for the machine

**One file per machine, with the name equal to the module label.** For
`module "runner01"`, the file is `runner01.tf`. When you read
`module.runner01.aws_instance.this` in a plan or an error, you know which file to
open. `main.tf` **receives no machine** — it is the directory map and carries the
ready-to-copy template (`module "runner01" { ... }`, with `name`, `hostname`,
`ami_id`/`instance_type`, `subnet_id`/`vpc_id`/`instance_profile`,
`root_volume_size`, `key_name`, `enable_termination_protection`, the empty rules
and the three tags).

**The module label (`"runner01"`) is an address in the state, not a resource
name.** Renaming the label makes Terraform see a removal plus a creation, and
that **destroys the instance**; to rename, use a `moved` block, never a direct
edit.

**Moving the block between files is safe**, for the opposite reason: the address
is `module.<label>.<type>.<name>` and has no file name inside it — Terraform
concatenates all the directory's `.tf` before interpreting. Proven on 10/21: the
split into one file per machine ended with `No changes`.

**Never copy another machine's block without cleaning up the rules and tags** —
the copied block brings the original's network rules and tags. It went wrong
three times here; the plan flags it (`12 to add` instead of `5 to add`), but only
in the resource list, not in the summary. There is no need to pass an SG name:
the module names it `{name}-sg` and creates **one SG per machine** — a shared SG
is a shared rule.

**Optional fields:** `key_name` (immutable — changing it replaces the instance
and the disk goes with it; decide now), `root_volume_size` (minimum = AMI disk,
30 GB on the arm64 base; it grows, does not shrink),
`integration_ingress_rules` / `integration_egress_rules` (empty ingress by
default; every rule requires `/32` per host and a `description` saying why; do
not open a database port 3306/1433/5432), `extra_security_group_ids` (only for a
legitimately shared SG).

### 3. Apply and verify

```powershell
$env:AWS_PROFILE = "acme-swe-prod"        # the backend does NOT inherit the provider's profile
terraform init -input=false
terraform plan -out=new-machine.tfplan    # READ the output before applying
terraform apply "new-machine.tfplan"
```

**Read the plan before applying.** On a new machine you expect only creation,
with `0 to destroy`. Any `must be replaced` or `to destroy` on a resource that
already exists means you touched something you did not intend to — stop and find
out what. Once it is up, through Session Manager, confirm: address in
`10.20.1.x` with no public IP (`ip addr`), `cloud-init status` = done,
`timedatectl` synced, SSH on **65022** (`ss -tlnp`), and a `curl` to the IMDS
without a token **must fail** — it is the door through which the instance's
credentials get stolen.

## Pitfalls that make the instance unreachable

There is no key pair, no port 22 and no public IP. If any of these is wrong,
**the only way in stops working and the fix is to recreate the instance**.

**1. The subnet must be private-d.** The public ones use `rt-main`, which has
only the `local` route — an instance there has **no egress** and the SSM agent
does not register. `rt-main` being empty is **deliberate**: it makes "forgetting
to associate" fail safely instead of silently granting internet. An instance
**does not change subnet** (an attribute of the primary ENI, fixed at launch);
getting it wrong means recreating.

**2. The instance profile must be present.** Without it the SSM agent does not
obtain credentials and does not register. The role is `delegated-ec2-ssm`
(`AmazonSSMManagedInstanceCore` + `CloudWatchAgentServerPolicy`).

**3. The metadata endpoint must be enabled.** The agent obtains credentials
through the IMDS. `http_endpoint = "disabled"` brings everything down.

## Technical decisions and pitfalls

### `ami_id` is fixed on purpose

Do not use `data "aws_ami"` with `most_recent = true`. It looks convenient and
it is dangerous: a new build would change the value, and the next
`terraform apply` — even one done for something else — would **destroy and
recreate the instance**, taking the disk. The module has
`lifecycle { ignore_changes = [ami] }` precisely so the variable can track the
current image without proposing to recreate an existing machine. Changing images
is a deliberate act: `terraform apply -replace=module.<name>.aws_instance.this`.

### The SSH port is 65022, confirmed on a real instance

The golden image configures SSH on **65022**, verified with `sudo ss -tlnp | grep
ssh`: the socket shows up with **`systemd` (pid=1)** next to `sshd`, and
`systemctl is-enabled ssh.socket` returns `enabled`. **The detail that proves the
mechanism:** from Ubuntu 24.04 onward SSH uses **socket activation**, and in that
mode the `Port` in `sshd_config` is **ignored** — what decides is the
`ListenStream` of the systemd unit. The build can pass with `sshd_config` alone
and SSH keep listening on 22 **with no error at all**; that is why the component
writes to both places. (`sshd -T` fails on the build machine because `/run/sshd`
is missing, which only exists when the service comes up.) Changing the port only
affects **where the server listens**; outbound connections keep going to the
destination's port 22.

### Renaming a machine replaces the security group

An SG's `GroupName` and `description` are **immutable on AWS**, and both derive
from `var.name`. Renaming the machine does not "rename" the SG: it creates
another, moves the instance and deletes the old one, **recreating the rules**.
Before renaming a machine with an SG in use, three checks:

```powershell
# 1. does every AWS rule exist in the code? A rule only on AWS is lost SILENTLY.
aws ec2 describe-security-group-rules --filters Name=group-id,Values=<sg>
# 2. does any other SG reference this one? The sg-id changes, and a reference by ID does not follow.
aws ec2 describe-security-groups --filters Name=ip-permission.group-id,Values=<sg>
# 3. is the instance stopped?
aws ec2 describe-instances --instance-ids <id> --query "Reservations[].Instances[].State.Name"
```

The first one only gives a safe result because the rules were imported into the
code; before that, recreating the SG would wipe out the integration with no
error at all. **`create_before_destroy = true` on the SG is required, not a
preference:** without it Terraform deletes the old SG before creating the new
one, and the old one is still attached to the ENI — AWS refuses with
`DependencyViolation` and the apply dies halfway through. It works because the
name changes; a replacement **without** a name change fails with
`InvalidGroup.Duplicate` — in that case the path is `name_prefix`.

### The SG `description` does not carry a fact that changes

The text was *"empty ingress, egress 443/80"* and became false when the
integration opened ingress. Fixing it would cost a replacement of the SG, so it
was changed to `"Security group for instance {name}"`, which only
**identifies** it. The rule: the description of an immutable resource should not
carry a fact that changes — it either ages into something false, or costs a
replace to fix. What comes in and **why** stays in the **rule** descriptions,
which are mutable in place.

### Touching `hostname` jolts the instance

`hostname` feeds `user_data`, and AWS requires the instance to be **stopped** to
modify that attribute. The provider does stop → modify → start on its own
(measured: with the machine already stopped, the following `start-instances`
returned `PreviousState: running`). Editing `hostname` on a **running** machine
brings the instance down and back up, killing every container along the way. And
the edit does **not change the OS hostname** of a machine that already came up:
`user_data` only runs on the first boot, and the module has
`user_data_replace_on_change = false`. It applies to a **new** instance.

### `key_name` is the line that destroys the machine

There is no attaching a key pair to an existing instance. Changing `key_name`
forces a **replacement**, and the root volume has `delete_on_termination = true`
— the disk goes with it. **Termination protection does not save you:**
`disable_api_termination` is an attribute managed by Terraform. **The two-faced
rule:** the module label is the address in the state; renaming the label
destroys the instance, while **keeping the label and changing attributes touches
the existing machine**. A new machine is always a **new block with a new label**.
(It nearly happened: editing the existing block instead of creating a new one
flagged `14 to destroy` with `aws_instance.this must be replaced`.)

### Why one key per machine

It limits the blast radius of a leaked key. The case that matters most is the CI
runner, which runs arbitrary code by design and should not carry the key of a
production machine. The private key never passes through AWS (generated with
`ssh-keygen`, only the public one imported) and **does not open a network path**
— SSH arrives only through the SSM tunnel, which is not an emergency escape
hatch.

### Why the integration rules are in the code

The rules were made by hand in the console to get the integration live and then
imported. Even with `plan` saying `No changes` (a separate rule resource manages
only the rule it declares), they were brought in because: (1) **the SG is created
by this module** — if it were recreated, it would come back with 443/80 and
nothing more, and the integration would stop with nobody touching it, since a
rule outside the code does not come back; (2) there was no record that the rules
existed nor of the reason for each port; (3) what is managed by Terraform stays
in Terraform. The destination is always a **host as /32** (`var.erp_host_cidr`,
in the tfvars, so as not to version another team's address) — a wider range
would give the entire production VPC the integration ports, including inbound
65022. No database port was opened, so the lateral movement mitigation held.

> **These rules were CENTRALIZED on 10/21** into the client SG (`clientsg.tf`),
> because the legacy ERP rule belongs to the **interlocutor**, not the machine —
> every machine in the fleet talks to it. The machine files' own
> `integration_ingress_rules`/`integration_egress_rules` went back to empty. The
> three questions below are **recorded in `clientsg.tf`** now; two of them were
> closed in the move (see "The shared client SG").

**Three questions these rules raised:**

- **65022 is SFTP, but the SG does not distinguish.** SFTP runs inside SSH, same
  port and protocol: whoever has the private key and reaches the port can open a
  shell. Restricting it is done in `sshd` (`ForceCommand internal-sftp` in a
  `Match`), not here. The real mitigation today is the private key.
- **ICMP existed only on ingress — now removed.** It used to be stateful, so
  they pinged this instance and got a reply, but we did not ping them. On 10/21
  the ICMP ingress was **removed, not forgotten**: no automated validation
  depended on it, the ping was a manual check. That closes the asymmetry — the
  rule no longer exists.
- **The same application ports appear on ingress and egress.** The question was
  whether this was "we do not know who initiates the connection". Closed on
  10/21 by finding: the communication **is bidirectional** on those ports,
  confirmed with engineering, so the symmetry is correct, not a smell.

### The shared client SG

`clientsg.tf` holds **two security groups** — `acme-swe-nonprod-client-sg` and
`acme-swe-prod-client-sg`, one per environment — that carry the legacy ERP
(client) integration rules and are attached to the machines through
`extra_security_group_ids`. This is the **deliberate exception** to "one SG per
machine", and it is the exception the module itself anticipated in
`var.extra_security_group_ids`.

**Why it inverts the rule.** The legacy ERP rules do not belong to a machine,
they belong to the **interlocutor**: every machine in the fleet talks to the
legacy ERP. Kept per machine, they were duplicated across two files and missing
from two, and revoking the legacy ERP's access meant remembering four places.
**The price, written down:** adding a rule here grants access to **every machine
in that environment at once** (three in nonprod: dataflow, protosim, workbench).
A rule that applies to a single machine still goes in that machine's file.

**Why two identical SGs instead of one shared across environments.** Being
identical today is not an invariant: with a single SG, changing a rule to test
it in nonprod would apply it to production in the same apply, and you lose the
one place where the mistake is cheap. An SG has no cost, so there is no saving in
unifying them.

**The reverted decision, kept as a lesson.** On 10/20 the legacy ERP rules were
removed from the workbench because "they came by copy and the workbench does not
take part in the integration". **Reverted on 10/21:** the workbench talks to the
legacy ERP too. The wrong reasoning was treating "it came by copy" as proof the
code should not be there — the origin of the code proves how it got there, not
whether it is necessary. The question that was missed was "does this machine
talk to the legacy ERP?".

**The discarded decision — splitting by port.** The proposal to split
baseline and specific **by port** was discarded because the same port has a
different interlocutor on each machine: 65022 came from the legacy ERP on
`dataflow` and from the industrial engineering workstation on `protosim`. A
uniform "65022 ingress" baseline would grant new access to someone that does not
talk to that host — and a network grant does not error on apply nor show up in
the plan summary. The correct axis is the **interlocutor**: legacy ERP rule in
`clientsg.tf`, industrial workstation rule in `prodprotosim.tf`/`nonprodprotosim.tf`,
baseline in the module.

**Opening the port is only half.** The SG does not distinguish SFTP from shell
(both run on the same SSH port), and granting 65022 does nothing until the other
side's **public key** is in `authorized_keys` — do not hand over the machine key
pair's private key. The 443/80 **ingress** here are legacy ERP rules, not
baseline; the baseline is the 443/80 **egress** to `0.0.0.0/0` the module
declares. Their descriptions had been **swapped** (443 said "http", 80 said
"https") and were fixed on 10/21; the corrected text lives in `clientsg.tf`.
ICMP was removed (see above), and the lateral-movement risk is preserved: no
database port, destination a single `/32`.

### Other recorded decisions

| Decision | Why |
|---|---|
| No key pair / no public IP | eliminates key management, an exposed port 22 and reachability from the internet |
| SG with empty ingress by default | user access will be through the ALB, not directly on the machine |
| **One SG per machine**, created by the module | a shared SG is a **shared rule**; `extra_security_group_ids` covers the legitimate case — now realized by the client SG (`clientsg.tf`) |
| Egress restricted to 443/80 | mitigates lateral movement: with the peering, a database on 3306/1433/5432 is unreachable |
| IMDSv2 required, hop limit 1 | hop limit 1 prevents a container on the instance from reaching the IMDS (the CI runner risk) |
| `credit_specification = standard` | the T3/T3a default is `unlimited`, which charges extra when the CPU bursts past its credits |
| gp3 disk encrypted with `aws/ebs` | a CMK costs ~US$ 1/month and adds a failure point; **consequence:** a snapshot with `aws/ebs` is not shareable across accounts — migration requires a copy with its own key |

### Tags: two pitfalls

- **A key with a colon needs quotes in HCL.**
  `"acme:cost-allocation:Project"`, not without quotes (the parser fails at
  `init`).
- **An instance tag does not propagate to the volume.** The disk is tagged
  separately, in the `root_block_device` block. `Project`, `Application` and
  `Environment` stay in the machine block because they vary per instance;
  `Environment` is what Cost Explorer groups by, and the spelling must be
  consistent (`nonprod`, never `noprod`), otherwise Cost Explorer treats it as
  two environments.

### The primary ENI tag

`aws_instance` has no argument to tag the ENI it creates. The alternative
(declaring a separate `aws_network_interface`) **replaces the instance**, because
the primary ENI cannot be swapped after launch. Solved with `aws_ec2_tag`, which
manages **one** tag on any EC2 resource by ID, combined with
`primary_network_interface_id`. Only `Name`: an ENI has no cost.

### Terraform state

It lives in `s3://acme-swe-prod-tfstate/instances/terraform.tfstate`. The `key`
must be **unique per configuration** — Terraform does not validate this. If two
configurations use the same path, the second one to run will think it owns the
resources of the first, and a `destroy` would wipe out another project's
resources. Never commit `*.tfstate` nor `*.tfvars` (already in the root
`.gitignore`).

## The protosim protocol ports

PROTOSIM simulates Modbus, BACnet and EtherNet/IP to validate PLC software.
Single source and destination: the industrial engineering workstation host, as a
`/32`.

| Ingress (PROTOSIM as slave) | Proto | Ports | | Egress (PROTOSIM as master) | Proto | Port |
|---|---|---|---|---|---|---|
| `modbus_slave_low` | TCP | 400–1000 | | `modbus_master` | TCP | 502 |
| `modbus_slave_high` | TCP | 4000–6000 | | `enip_master_tcp` | TCP | 44818 |
| `enip_slave_tcp` | TCP | 44800–44900 | | `enip_master_io` | UDP | 2222 |
| `enip_slave_udp` | UDP | 44800–44900 | | `bacnet_master` | UDP | 47808 |
| `bacnet_slave` | UDP | 47808–47907 | | | | |

**The ingress ranges are wide on purpose**, because each simulated slave listens
on its own port. `400-1000/TCP` includes 443, 445, 500, 514, 636, 873, 993 and
995; the risk is contained because the source is **a single host as `/32`**.
Egress makes an exception to the rule of restricting egress to 443/80, but no
database port was opened.

**The industrial engineering workstation IS NOT IN THIS ACCOUNT.** The address
belongs to `172.31.0.0/16`, the VPC of the **production** account
(`describe-network-interfaces` in this account does not find the IP; the local
VPC is `10.20.0.0/16`). The traffic leaves through the peering, with a route to
`172.31.0.0/16` in `acme-swe-prod-rt-private`. **The outbound route exists; the
return one, on the production side, is an open pending item** — without it the
packet leaves and never comes back, and the flow log would show `ACCEPT` on
egress with no reply, the pattern that confuses diagnosis the most. That is why
the address came in as `var.plc_workstation_host_cidr`.

Both PROTOSIM machines exist now (`nonprodprotosim` and `prodprotosim`). **Their
65022 does not live here** — it comes from the shared client SG, pointing at the
legacy ERP. The `sftp_plc_workstation` rule that used to be on the nonprod one
was **removed on 10/21** (protosim now does file transfer with the legacy ERP,
not with the workstation), so `172.31.20.11/32` no longer reaches 65022 on it;
the prod one never had it, being born in the new pattern.

### The ticket's port 22022 does not exist

The tickets asked for "SSH 22022", but the golden image configures sshd on
**65022**. Opening 22022 on the SG would have no effect, and it is not needed:
SSH arrives through the SSM tunnel. Same logic for the web interface — instead of
opening port 80, use `aws ssm start-session ... --document-name
AWS-StartPortForwardingSession --parameters "portNumber=80,localPortNumber=8080"`
and access `localhost:8080`, without opening any port. For **production with
many users** it does not scale (each one would need AWS credentials and the
session plugin) — there the path is the ALB.

### The workbench is born with empty ingress and egress

Its **own** SG is empty: nothing reaches the machine directly, access is through
Session Manager. On 10/20 the legacy ERP rules were removed from here with the
reason "they came by copying the `dataflow` block and the workbench does not take
part in the integration". **That was reverted on 10/21** — the workbench talks to
the legacy ERP too, so the rules now apply to it through the **shared client
SG** (`extra_security_group_ids`), not in this file. The lesson kept from the
episode: "it came by copy" proves how the code got there, not whether it should
be there; the right question is "does this machine talk to the interlocutor?".
And copying a module block still copies the original's network decisions and
tags — the plan flags it (`12 to add` instead of `5 to add`), but only for
whoever reads the resource list, not the summary.

### `t4g.small` instead of `t4g.medium`

The tickets asked for `t4g.medium`; they came up on `t4g.small`, by a decision to
measure real consumption before sizing — there is no published benchmark of the
libraries used (bacpypes, BAC0, pymodbus, cpppo), and **the instance type is an
in-place change** (stop, modify, restart, without recreating or losing the
disk).

**How to measure:** if the slaves are child processes, they share the Python
interpreter's pages by copy-on-write. **Summing the RSS of 30 processes counts
the shared memory 30 times** and inflates the result three or four fold. Use
`free -m`, which measures the machine (baseline → 1 slave → 10; the difference
divided by 9 is the real marginal cost). The internal throttle refuses new slaves
with a 503 when free RAM drops below 512 MB — **an absolute limit, not a
proportional one:** 25% of a 2 GB machine and 6% of an 8 GB one. On `t4g.small`
the throttle can become the normal behavior instead of edge protection, and it
shows up as if it were a software bug. It does not protect the neighbor (it only
blocks new slaves, it does not give back allocated memory); if you share the
machine with another container, use `--memory`.

---

## Known gaps, cost and structure

- **The x86 AMI variables exist** since 10/21 (`x86_ami_id` and
  `x86_docker_ami_id`), alongside the two arm64 ones — you can create Graviton
  and x86. Mind the minimum disk size per architecture (20 GB on x86, 30 GB on
  arm64) and that an x86 AMI does not run on `t4g`/`m6g`/`c7g`.
- **`credit_specification` is fixed at `cpu_credits = "standard"`**, an attribute
  of the *burstable* (T) family. On `m6g`, `c7g` or a non-T family, that block is
  the first place to look if the apply fails — to be generic, it needs to become
  conditional.

Recurring before any instance: **~US$ 36/month** (NAT Gateway + Elastic IP);
`t3a.small` ~US$ 14/month, `t3a.medium` ~US$ 27/month; plus ~US$ 1.60/month per
20 GB gp3 disk; taxes ~16%.

The directory follows **one file per machine**, with the file name equal to the
module label:

```
instances/
├── README.md                this file
├── provider.tf              versions and AWS profile
├── backend.tf               remote state (its own key)
├── variables.tf             variable declarations
├── terraform.tfvars.example example values (the real one does NOT go to git)
├── main.tf                  directory map + machine template (NO machine)
├── clientsg.tf              client (legacy ERP) SGs, one per environment
├── nonproddataflow.tf       module "nonproddataflow"
├── proddataflow.tf          module "proddataflow"
├── nonprodprotosim.tf       module "nonprodprotosim"
├── prodprotosim.tf          module "prodprotosim"
├── nonprodworkbench.tf      module "nonprodworkbench"
├── prodworkbench.tf         module "prodworkbench"
└── modules/
    └── ec2-instance/        one instance in the project's pattern
```

Splitting into one file per machine is **human** organization: Terraform
concatenates all the `.tf` before interpreting and the address in the state has
no file name inside it, so moving a block between files changes nothing (the
split ended with `No changes` on 10/21). A new folder, by contrast, would be a
new state — reserved for a different blast radius, cadence or credential, never
for "one resource type per folder". `main.tf` records this criterion at length.

Before opening or closing a port on the integration machines, **there is real
traffic flowing** — measure in the flow log first (`../../tools/flowlog/`), close
afterward.
