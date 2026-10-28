# ---------------------------------------------------------------------------
# tools/flowlog/query-flowlog.py
#
# Reads the VPC Flow Logs straight from S3 (Parquet) and answers questions
# about the traffic, WITHOUT setting up Athena.
#
# WHY NOT ATHENA: it would work, but it would require creating a table with the
# 25 fields of the custom format in the exact order, plus a results bucket -
# new infrastructure on AWS for a one-off question. duckdb reads the local
# Parquet and solves it.
#
# If one day the query becomes routine, Athena starts to pay off: the table is
# ready and anyone can query it from the console, without downloading anything.
#
# CONFIGURATION - the constants below are not hardcoded. In a public
# repository, embedding an account number, bucket or IP is bad: each
# environment has its own. So each one comes from an environment variable, with
# a fallback to a placeholder. Export them before running (see README), for
# example:
#
#   $env:FLOWLOG_ACCOUNT = "111122223333"
#   $env:FLOWLOG_BUCKET  = "acme-swe-prod-flowlogs"
#   $env:FLOWLOG_PROFILE = "acme-swe-prod"
#
# PREREQUISITES
#   pip install -r requirements.txt
#   aws sso login --profile acme-swe-prod
#
# USAGE
#   python query-flowlog.py                 # summary of today
#   python query-flowlog.py 2026-10-16      # summary of a date
#
# WATCH OUT WHEN INTERPRETING - two pitfalls that have already produced a wrong
# conclusion:
#
#   1. ACCEPT DOES NOT MEAN "REACHED THE DESTINATION". It only means that no
#      security group or NACL denied it. The NAT Gateway has no security group,
#      so EVERY scan from the internet against its EIP shows up as ACCEPT - and
#      is discarded by the NAT itself afterwards. To assess the posture of the
#      instances, filter by their ENI.
#
#   2. THE LOG IS HISTORICAL. An SG rule created today does not change the past:
#      earlier flows stay REJECT in the log. Always look at the TIMESTAMP before
#      concluding that a rule is not working.
# ---------------------------------------------------------------------------

import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

import duckdb

# Environment constants, with a fallback to placeholders (see block above).
# os.environ.get(key, default) returns the exported value when it exists, or
# the placeholder when it does not - handy for cloning the repo and just
# running the example.
BUCKET = os.environ.get("FLOWLOG_BUCKET", "acme-swe-prod-flowlogs")
ACCOUNT = os.environ.get("FLOWLOG_ACCOUNT", "111122223333")
REGION = os.environ.get("FLOWLOG_REGION", "us-west-2")
PROFILE = os.environ.get("FLOWLOG_PROFILE", "acme-swe-prod")

# Reference resources, so the report knows what is "ours"
INSTANCE_IP = os.environ.get("FLOWLOG_INSTANCE_IP", "10.20.1.50")  # acme-swe-nonprod-dataflow
INSTANCE_ENI = os.environ.get("FLOWLOG_INSTANCE_ENI", "eni-0a1b2c3d4e5f60718")
NAT_EIP = os.environ.get("FLOWLOG_NAT_EIP", "203.0.113.25")
PROD_CIDR_PREFIX = os.environ.get("FLOWLOG_PROD_CIDR_PREFIX", "172.31.")  # production VPC, vpc-0a1b2c3d4e5f60002


def download(day: str, dest_dir: str) -> int:
    """Download a day's Parquet files. Returns the number of files."""
    year, month, dom = day.split("-")
    prefix = (
        f"s3://{BUCKET}/AWSLogs/aws-account-id={ACCOUNT}"
        f"/aws-service=vpcflowlogs/aws-region={REGION}"
        f"/year={year}/month={month}/day={dom}/"
    )
    print(f"downloading {prefix}")
    subprocess.run(
        ["aws", "s3", "cp", prefix, dest_dir, "--recursive", "--quiet",
         "--profile", PROFILE],
        check=True,
    )
    return len([f for f in os.listdir(dest_dir) if f.endswith(".parquet")])


def report(parquet_glob: str, day: str) -> None:
    ts = "strftime(epoch_ms(start*1000), '%d/%m %H:%M')"

    print("\n=== 1. VOLUME OF THE PERIOD ===")
    print(duckdb.sql(f"""
        SELECT count(*) AS records,
               strftime(epoch_ms(min(start)*1000), '%d/%m %H:%M') AS start_utc,
               strftime(epoch_ms(max("end")*1000), '%d/%m %H:%M') AS end_utc
        FROM read_parquet('{parquet_glob}')
    """))

    print("\n=== 2. WHAT WAS BLOCKED ON THE INSTANCE'S EGRESS ===")
    print("(REJECT on egress = the security group blocked something the machine tried)")
    print(duckdb.sql(f"""
        SELECT dstaddr AS destination, dstport AS port, protocol AS proto,
               count(*) AS attempts,
               min({ts}) AS first_utc, max({ts}) AS last_utc
        FROM read_parquet('{parquet_glob}')
        WHERE srcaddr = '{INSTANCE_IP}' AND action = 'REJECT'
        GROUP BY ALL ORDER BY attempts DESC LIMIT 25
    """))

    print("\n=== 3. WHO INITIATES EACH CONNECTION WITH PRODUCTION ===")
    print("(SYN without ACK = the side that OPENS. tcp_flags: 2=SYN, 16=ACK)")
    print(duckdb.sql(f"""
        SELECT flow_direction AS direction, srcaddr AS source,
               dstaddr AS destination, dstport AS dest_port,
               count(*) AS connections
        FROM read_parquet('{parquet_glob}')
        WHERE protocol = 6
          AND (srcaddr LIKE '{PROD_CIDR_PREFIX}%' OR dstaddr LIKE '{PROD_CIDR_PREFIX}%')
          AND (tcp_flags & 2) = 2 AND (tcp_flags & 16) = 0
          AND (dstport < 1024 OR dstport BETWEEN 5020 AND 5023
               OR dstport BETWEEN 5160 AND 5161 OR dstport = 65022)
        GROUP BY ALL ORDER BY connections DESC LIMIT 20
    """))

    print("\n=== 4. WHICH PATH THE TRAFFIC TOOK (traffic_path) ===")
    print("1=another resource in the VPC . 2=IGW . 4=intra-region peering . 5=inter-region peering")
    print(duckdb.sql(f"""
        SELECT traffic_path, count(*) AS flows, sum(bytes) AS bytes
        FROM read_parquet('{parquet_glob}')
        WHERE flow_direction = 'egress' AND dstaddr LIKE '{PROD_CIDR_PREFIX}%'
        GROUP BY ALL ORDER BY flows DESC
    """))

    print("\n=== 5. DATABASE PORT LEAVING THE INSTANCE? ===")
    print("(lateral-movement check - filtered by the INSTANCE on purpose, see pitfall 1)")
    print(duckdb.sql(f"""
        SELECT dstaddr AS destination, dstport AS port, action, count(*) AS flows
        FROM read_parquet('{parquet_glob}')
        WHERE srcaddr = '{INSTANCE_IP}'
          AND dstport IN (3306, 1433, 5432, 1521, 27017, 6379, 9200, 11211)
        GROUP BY ALL ORDER BY flows DESC
    """))

    print("\n=== 6. INTERNET SCAN AGAINST THE NAT EIP ===")
    print("Background noise. ACCEPT here does NOT mean it reached anyone:")
    print("the NAT does not forward unsolicited inbound connections.")
    print(duckdb.sql(f"""
        SELECT count(*) AS flows,
               count(DISTINCT srcaddr) AS distinct_sources,
               count(DISTINCT dstport) AS distinct_ports
        FROM read_parquet('{parquet_glob}')
        WHERE dstaddr = '{NAT_EIP}'
    """))

    # Evidence in CSV, to attach to a conversation or a ticket
    output_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               f"evidence-rejects-{day}.csv")
    duckdb.sql(f"""
        COPY (
            SELECT strftime(epoch_ms(start*1000), '%Y-%m-%d %H:%M:%S') AS start_utc,
                   strftime(epoch_ms("end"*1000),  '%Y-%m-%d %H:%M:%S') AS end_utc,
                   srcaddr, srcport, dstaddr, dstport, protocol,
                   packets, bytes, action, flow_direction, interface_id
            FROM read_parquet('{parquet_glob}')
            WHERE srcaddr = '{INSTANCE_IP}' AND action = 'REJECT'
            ORDER BY start
        ) TO '{output_path.replace(chr(92), '/')}' (HEADER, DELIMITER ',')
    """)
    print(f"\nCSV with the blocked attempts: {output_path}")


if __name__ == "__main__":
    day = sys.argv[1] if len(sys.argv) > 1 else datetime.now(timezone.utc).strftime("%Y-%m-%d")
    with tempfile.TemporaryDirectory(prefix="flowlog-") as tmp:
        count = download(day, tmp)
        print(f"{count} files")
        if count == 0:
            print("No file for this date. The bucket stays empty when there is no traffic.")
            sys.exit(0)
        report(os.path.join(tmp, "*.parquet"), day)
