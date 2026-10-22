# VPC Flow Logs query

A diagnostic tool, not infrastructure — that is why it lives outside
`terraform/`. It reads the Flow Logs straight from S3 and answers questions
about the traffic of the `acme-swe-prod` account.

```powershell
pip install -r requirements.txt
aws sso login --profile acme-swe-prod

python query-flowlog.py              # today
python query-flowlog.py 2026-10-16   # a date
```

It generates `evidence-rejects-<date>.csv` with everything the security group
blocked on the instance's egress — useful to attach to a conversation or a
ticket. A synthetic example of the format is in `example-evidence.csv`.

---

## Configuration via environment variable

The script **does not embed** the account number, bucket, profile or IPs in the
code: each environment has its own, and in a public repository a fixed account
value is bad. Each constant comes from `os.environ.get(key, default)`, which
returns the exported value when it exists or a placeholder when it does not — so
you can clone the repository and run the example without configuring anything,
but any real use exports your environment's values first.

| Variable | Default (placeholder) | What it is |
|---|---|---|
| `FLOWLOG_BUCKET` | `acme-swe-prod-flowlogs` | S3 bucket with the Parquet files |
| `FLOWLOG_ACCOUNT` | `111122223333` | account ID, 12 digits |
| `FLOWLOG_REGION` | `us-west-2` | region of the logs |
| `FLOWLOG_PROFILE` | `acme-swe-prod` | AWS CLI profile (SSO) |
| `FLOWLOG_INSTANCE_IP` | `10.20.1.50` | private IP of the analyzed instance |
| `FLOWLOG_INSTANCE_ENI` | `eni-0a1b2c3d4e5f60718` | ENI of the instance |
| `FLOWLOG_NAT_EIP` | `203.0.113.25` | Elastic IP of the NAT Gateway |
| `FLOWLOG_PROD_CIDR_PREFIX` | `172.31.` | prefix of the production VPC |

```powershell
$env:FLOWLOG_ACCOUNT     = "111122223333"
$env:FLOWLOG_BUCKET      = "acme-swe-prod-flowlogs"
$env:FLOWLOG_PROFILE     = "acme-swe-prod"
$env:FLOWLOG_INSTANCE_IP = "10.20.1.50"
python query-flowlog.py 2026-10-16
```

---

## Why not Athena

Athena would work and is the "official" path. It would require creating a table
with the **25 fields of the custom format in the exact order** — the same order
used in the flow logs custom format definition — plus a results bucket: new
infrastructure on AWS for a one-off question. `duckdb` reads the Parquet locally
and does away with both.

**When Athena starts to pay off:** if the query becomes routine or if someone
else needs to query it without downloading anything. Then the table is worth it,
because it is ready and anyone can use it from the console.

---

## Two interpretation pitfalls

Both have already produced a wrong conclusion in this project, on 2026-10-16.

### `ACCEPT` does not mean "reached the destination"

It only means that **no security group or NACL denied it**. It is permission,
not delivery.

The real case: a query for database ports across the whole log returned
`3306 ACCEPT`, `5432 ACCEPT`, `1433 ACCEPT` — which looks like a violation of the
lateral-movement risk. It was not. It was an **internet scan against the NAT's
Elastic IP** (`203.0.113.25`): 9,725 flows, 3,510 distinct sources, 6,046 ports.
The NAT Gateway **has no security group**, so everything that hits it shows up as
`ACCEPT` — and is discarded by the NAT itself afterwards, because it does not
forward unsolicited inbound connections.

**To assess an instance's posture, filter by its IP or its ENI.** The VPC log
includes the NAT, and the NAT attracts the noise of the whole internet.

### The log is historical

A security group rule created now does not change the past: earlier flows stay
`REJECT` in the log, forever.

The real case: `172.31.20.10 → 10.20.1.50` over ICMP showed up as `REJECT` at
13:42–13:45 UTC and `ACCEPT` at 13:51. It looked like a rule not working. It was
the rule **coming into effect** — the `REJECT`s are from before it existed.

**Always look at the timestamp before concluding that a rule failed.**

---

## How to read the fields that matter

| Field | What it is for |
|---|---|
| `action` | `ACCEPT`/`REJECT` of the SG and the NACL. See pitfall 1 |
| `tcp_flags` | OR mask of the interval: `2`=SYN, `16`=ACK, `1`=FIN, `4`=RST, `8`=PSH |
| `flow_direction` | `ingress`/`egress` **relative to the ENI** that recorded it |
| `traffic_path` | `1` another resource in the VPC · `2` IGW · `4` intra-region peering · `5` inter-region peering |
| `interface_id` | `-` when the flow is from the NAT Gateway |

**`SYN` without `ACK` identifies who OPENS the connection** — `(tcp_flags & 2) =
2 AND (tcp_flags & 16) = 0`. It is what answers "who initiates the integration",
a question the data answered when the initial survey did not.

**Signature of a blocked egress:** a `REJECT` flow with ~8 packets and ~480 bytes
and no return flow. These are `SYN` retransmissions with no answer. Different from
a **refused** connection, which gets a `RST` back — there the destination exists
and said no.

---

## Finding of 2026-10-16: Canonical NTS blocked

The report showed 81 egress attempts on **TCP 4460** to six destinations, all
with PTR `ntp-nts-*.canonical.com`.

**`NTS` is Network Time Security** — NTP authenticated over TLS, whose key
exchange runs on **TCP 4460** (RFC 8915). The instance tries to sync its clock
through Canonical's servers, and the security group blocks it: egress is only
443/80. It is exactly the pattern that appears in `example-evidence.csv`:
`REJECT` on egress on port 4460, with ~8 packets and ~480 bytes per flow.

This ties into the open item *"recheck the clock synchronization"*, open since
10/15, when `timedatectl` reported `System clock synchronized: no` with
`NTP service: active`.

**It had been concluded that the SG could not be involved**, because the AWS time
service lives at `169.254.169.123`, link-local, which is not filtered by a
security group. The reasoning is **correct for the AWS service** and
**incomplete**: the Ubuntu image also tries Canonical, and that path goes through
the SG.

**Preferred fix:** point the time service at `169.254.169.123`, which is
link-local, free and does not depend on an SG rule. It goes in the golden image
component, with a new version.

**Fix to avoid:** opening egress on 4460 to Canonical's IPs. It couples the rule
to a third party's IP and widens the egress restriction that mitigates the
lateral-movement risk.
