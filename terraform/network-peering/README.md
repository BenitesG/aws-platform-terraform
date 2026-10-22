# VPC peering with the production account

Connection between the VPC of the `acme-swe-prod` account (`111122223333`) and
the production VPC, both in **us-west-2**. Described in the project's internal
action plan.

---

## Current state

| | |
|---|---|
| Connection | **`pcx-0b1b2b3b4b5b6b7b8`** — `active`, created and accepted on 2026-10-16 |
| Our side | `vpc-0aaaa1111bbbb2222` — `10.20.0.0/16` |
| Production side | account `444455556666` · **`vpc-9f8e7d6c`** · **`172.31.0.0/16`** |
| Route in `rt-private` | `172.31.0.0/16 → pcx-0b1b...`, `active` — created **by hand** |
| DNS resolution, our side | `false` — step 2 has not been applied yet |
| DNS resolution, their side | `null` — not enabled **or** not visible from here |

**Zero cost:** peering has no hourly charge.

### The previous connection was deleted — and why

The first connection, **`pcx-0c1c2c3c4c5c6c7c8`** (created and accepted on
10/15, for `vpc-0d1d2d3d4d5d6d7d8` / `172.16.0.0/16`), was **deleted on 10/16**.

**Reason:** that VPC had **no resource** assigned to it. The peering was
technically correct and the destination was useless — there was nothing to talk
to.

**Why keeping both in parallel was not possible.** That was the initial
recommendation: peering is free, and keeping the old one would preserve a ready
path while the new one was being accepted. It did not work, and the reason is
concrete: **both routes would go to the same `rt-private`**, and a route table
does not accept two routes to the same destination. The replacement was not a
choice.

> At the time the information was that the new VPC used **the same** CIDR. It
> turned out not to — see below. With different CIDRs, coexisting **would** have
> been possible. The decision was made with the information available.

**Deleting was irreversible:** `pcx-0c1c...` does not come back, and the
acceptance production had given on 10/15 died with it. Redoing it required a new
round of acceptance.

---

## The CIDR was wrong — the most expensive error of the day

This is the best diagnostic story in the repository. Read it in full.

**`172.16.0.0/16` was the CIDR of the PREVIOUS VPC.** `vpc-9f8e7d6c` uses
**`172.31.0.0/16`** — confirmed at the source after acceptance, with
`CidrBlockSet` bringing a single block, no secondary range.

The first route was created with the wrong value, and **the state looked
healthy**:

```
pcx-0b1b2b3b4b5b6b7b8   active
172.16.0.0/16 -> pcx-0b1b2b3b4b5b6b7b8   active
```

Peering `active`, route `active`, and **nothing would work**. Traffic to the
real servers (`172.31.x.x`) would find no specific route, would fall into
`0.0.0.0/0` and leave through the **NAT to the internet**. Traffic to
`172.16.x.x` would enter the connection and find nobody. In both cases:
**timeout with no error message.**

**The root cause was not technical:** `172.16.0.0/16` was information **passed
along**, never verified. And there was no way to verify it beforehand — while
the connection is `pending-acceptance`, AWS returns `null` in
`AccepterVpcInfo.CidrBlock`. Only after acceptance can it be confirmed.

**That is why "check the CIDR at the source" is a separate step in the
checklist, not a formality.** It was checked, it diverged, and the route was
fixed by hand.

### Suspicion to confirm: this appears to be their default VPC

Three signs together: an **8-character** ID (pre-2016 format), CIDR
**`172.31.0.0/16`** and **no secondary range**. It is the signature of an **AWS
default VPC** — every account is born with one, in that range. The 8-character
ID is not a truncation: it is the old format, from a VPC created before ~2016,
and it is still valid (the validation in `variables.tf` accepts `{8,17}`).

It matters to know because a default VPC comes with an **Internet Gateway and
automatic public IP**, the opposite design to ours — which is exactly why the
default VPCs of this account's 17 regions were deleted. Production running in a
default VPC is plausible in an old account, but it is worth knowing that this is
what we are reaching, and not a VPC designed for the role.

### A new consequence for Docker — the risk changed status

`172.31.0.0/16` **is in Docker's allocation path** (`172.17` going up to
`172.31`), and it is the last range before it moves to `192.168`.

The 10/15 decision to keep the pool at the default rested on **zero risk**:
production was `172.16.0.0/16`, off the path. Now:

```
ZERO risk  ->  LOW AND REAL risk
```

The probability is still low — it requires **15 networks** created earlier on
the same host, which is dozens of `docker-compose` stacks. **It was not
reverted.** But if "the container host does not talk to production" shows up,
**this is the first hypothesis**: a container network creates a **local route**,
the local route beats the VPC route, and the local network does not escape — it
**swallows** the traffic. The rule for future ranges does not change: avoid
`172.17`–`172.31` when creating a new VPC or subnet.

---

## The route is outside Terraform — and how to import it

The route `172.31.0.0/16 → pcx-0b1b2b3b4b5b6b7b8` was created **by hand**, and
this directory's `terraform state list` has **only** the connection:

```
aws_vpc_peering_connection.production
```

**Consequence:** uncommenting step 2 and applying would fail with
`RouteAlreadyExists` — Terraform would try to create a route that already
exists.

**The recommended path is `import`**, not delete-and-recreate: it brings the
existing route into the state without touching the traffic.

```powershell
$env:AWS_PROFILE = "acme-swe-prod"
# 1. uncomment step 2 in main.tf (import requires the resource in the code)
# 2. import the route that already exists
terraform import aws_route.to_production "rtb-0a1a2a3a4a5a6a7a8_172.31.0.0/16"
# 3. plan: expected 1 to add (only the DNS options) and NO change to the route
terraform plan
```

The `plan` after the import is the check that matters: if it wants to **alter**
the route, it is because the imported value differs from the code — and then the
suspect is `production_vpc_cidr` in the `tfvars`.

---

## Why there are two `apply`s

The route and the DNS options require the connection to be **`active`**. With it
in `pending-acceptance`, the `apply` would fail halfway through — with the
request already created and the state partially applied. That is why step 2 is
kept **commented out** in `main.tf` until the acceptance comes through.

```
apply 1  ─ deletes the old one, creates the new request   ← DONE 10/16
   ↓
       the production owner ACCEPTS                        ← DONE 10/16
   ↓
apply 2  ─ route in rt-private + DNS resolution            ← PENDING
```

**The mechanism showed up twice, and the second time taught more.** On the VPC
swap, `peer_vpc_id` is **ForceNew**: the connection is destroyed and recreated,
and the new one is born `pending-acceptance`. In other words step 2 **went
back** to being commented out after it had already been applied. Swapping the
VPC of a peering does not exist — it is always a replacement. The pattern holds
for any resource that depends on a third party's action midway through.

---

## What is left, and half of it is not ours

### On our side

1. **`import` the route** created by hand (see above).
2. **`apply` step 2**, which turns on DNS resolution on our side (`false`).

### On the production side — three steps

1. ~~**Accept the request**~~ — **DONE on 10/16** for
   `pcx-0b1b2b3b4b5b6b7b8`.
2. **Return route:** destination `10.20.0.0/16`, target the peering connection,
   in the route table **of the subnets involved**. Reported as done "on the
   default route" — **and this needs to be confirmed**.
3. **Accepter DNS resolution** — Actions → Edit DNS settings, if the integration
   uses a name instead of an IP. Today `AccepterVpcInfo.PeeringOptions` returns
   `null`, which may mean not enabled **or** not visible from here.

These three **cannot be in this code**: they are resources in another account,
and we have no credentials there.

> ### To confirm: the "default route" may have no effect at all
>
> A route table only applies to the **subnets associated with it**. The **main**
> route table (the "default" one) is used only by the subnets that **nobody
> explicitly associated** with another. If the subnets of the integration
> servers have an explicit association with another route table, the route in
> the main one **does nothing** — and the symptom is **timeout with no error**,
> identical to a missing route. Being a default VPC, there is a reasonable
> chance they use the main one, but "likely" is not "verified".

### How to check from our side

```powershell
$env:AWS_PROFILE = "acme-swe-prod"

aws ec2 describe-vpc-peering-connections `
  --filters "Name=status-code,Values=active,pending-acceptance" `
  --query "VpcPeeringConnections[].{Id:VpcPeeringConnectionId,State:Status.Code,TheirCIDR:AccepterVpcInfo.CidrBlock,OurDNS:RequesterVpcInfo.PeeringOptions.AllowDnsResolutionFromRemoteVpc}" `
  --output table --profile acme-swe-prod
```

**Filter by `status-code`**: a deleted connection keeps showing up as `deleted`
for a few hours, and in an unfiltered list that is confusing. **Why `TheirCIDR`
matters:** while the connection is pending, AWS does not reveal the other side's
CIDR; after acceptance it appears, and it is the **only** independent
confirmation that the route points at the right range. On 10/16 this check
caught the `172.16` against `172.31` error.

---

## What this directory deliberately does not do

**It does not create a security group rule.** That is the integration with the
legacy ERP, and it depends on two answers from engineering that do not exist
yet: **who initiates the connection** and **on which port**.

That is why creating the peering now is safe: **the connection existing does not
make any traffic flow.** The security group decides that, and the one on the
`dataflow` instance (`acme-swe-nonprod-dataflow-sg`) still has empty ingress and
egress restricted to 443/80. Each machine now has its **own SG**, created inside
the `ec2-instance` module — which is why there is no fixed ID here: Terraform
creates it. The old shared baseline SG was left orphaned. This changes the
integration design: the rule goes **in the SG of the machine that needs it**,
not in a shared SG.

> **Caution.** Opening the integration port is easy to reverse on paper and hard
> in practice: once real traffic is flowing, closing it breaks the integration.
> The time to decide the design is before passing traffic.

If production **pulls** from the instance, it reopens the security group design
with ingress today empty by design. If the instance **sends**, egress on 443/80
does not reach a database on 3306/1433/5432 — and opening those ports undoes the
mitigation of the lateral-movement risk.

---

## Boundary with the rest of the repository

The VPC and the `rt-private` were built **in the console** and are not in the
Terraform state. This does not stop the route from living in code: **`aws_route`
manages ONE route inside an existing route table**, referenced by ID, without
requiring the table to be under Terraform management — so the route goes in code
without importing the network and without producing drift on the table.

The route goes in **`rt-private`** (`rtb-0a1a2a3a4a5a6a7a8`), explicitly
associated with `private-c` and `private-d`. **It does not go in `rt-main`**,
which is left with only `local` on purpose — the decision to leave the main
route table with only `local`, so that "forgetting to associate" fails safely.

---

## Pitfalls

### A route is needed in BOTH accounts

Half the way does not work: the symptom is **timeout with no error message** —
not "missing route". Our route alone does nothing.

### Peering does NOT resolve private DNS by default

It must be turned on **in both directions** if the integration uses a name
instead of an IP. The symptom of missing it is **"the host does not exist"**,
which looks like an application error and not a network one. The pending request,
in turn, **expires in 7 days**: if it expires, the `plan` will propose recreating
it — correct behavior, but it means arranging a new window with the other side.

### Their NACL may block with everything apparently correct

A NACL is **stateless** and evaluated separately from the security group. Worth
remembering **if connectivity fails with peering, routes and SGs all correct**.

### Peering is NOT transitive

Nobody from the office reaches the instances through it. From three VPCs onward
the number of connections grows as `n(n-1)/2` and the Transit Gateway becomes the
right instrument. As long as it is production ↔ `acme-swe-prod`, peering is the
simplest and the cheapest.

### Swapping the VPC of a peering does not exist — it is a replacement

`peer_vpc_id` is **ForceNew**. Changing the value destroys the connection and
creates another, which is born `pending-acceptance` and requires a **new
acceptance** from the other side. The route and the DNS options fall with it,
because they depend on the connection ID. This is correct, but it means step 2
**goes back** to being commented out — you cannot swap the VPC in a single apply.

### Deleting a connection is irreversible, and the acceptance dies with it

The ID does not come back, and the other side's acceptance is lost. Before
deleting, it is worth asking whether **coexisting** solves it: peering is free,
and two connections to different VPCs are allowed — what prevents coexisting is
an equal or overlapping CIDR (two routes to the same destination do not fit in
the same route table).

### `peer_region` is not declared

Both VPCs are in us-west-2. Declaring `peer_region` equal to the provider region
creates an **inter-region** peering and changes the cost (transfer per GB).
`auto_accept`, in turn, only works in the same account — between accounts the
acceptance is necessarily manual, on the other side.

---

## Structure

```
network-peering/
├── README.md                    this file
├── provider.tf                  versions and profile (PowerUser is enough: no IAM)
├── backend.tf                   remote state, its own key
├── variables.tf                 variable declarations, with validations
├── terraform.tfvars             values — does NOT go to git
├── terraform.tfvars.example     versionable template
└── main.tf                      step 1 and step 2, both applied
```

The `terraform.tfvars` holds identifiers from **another AWS account** — not
versioning it means not publishing a third-party team's infrastructure data. The
`.terraform.lock.hcl`, on the other hand, **must** be versioned: it pins the
provider version (`5.100.0`) and the hashes, ensuring every `init` uses the same
provider.
