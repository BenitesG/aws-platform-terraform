# ---------------------------------------------------------------------------
# bootstrap/main.tf
#
# The bucket that holds the Terraform state.
#
# Note that "one bucket" is actually FIVE resources: the bucket plus four
# configuration resources. Versioning, encryption, public access block and
# lifecycle are not fields of the bucket: they are separate resources that
# point to it. Older provider versions accepted everything inline, and that
# changed - if you find an example on the internet with "versioning { }"
# inside the aws_s3_bucket, it is outdated material.
#
# Repository convention: IDENTIFIERS IN ENGLISH, comments and tags in English
# too.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = "acme-swe-prod-tfstate"

  # Prevents a "terraform destroy" from deleting the bucket that holds this
  # configuration's own state. Without it, the destroy sabotages itself: it
  # wipes the record in the middle of the operation and leaves orphaned
  # resources.
  lifecycle {
    prevent_destroy = true
  }

  # A tag key with a colon MUST be quoted in HCL. Without quotes, the parser
  # reads "acme" as the attribute name and fails during init.
  tags = {
    Name      = "acme-swe-prod-tfstate"
    ManagedBy = "terraform"

    "acme:cost-allocation:Project"     = "best-practices"
    "acme:cost-allocation:Application" = "terraform-state"
    "acme:cost-allocation:Department"  = "swe"
    "acme:cost-allocation:CostCenter"  = "cc-infra-1000"
    "acme:automation:Environment"      = "prod"

    # "sensitive" on purpose: the state can end up containing sensitive values
    # in clear text if Terraform creates a resource with a secret (an RDS
    # initial password, for example). Starting at the highest classification
    # avoids having to remember to raise it later.
    "acme:data:DataClassification" = "sensitive"

    Owner      = "plataforma@example.com"
    ChargeType = "dedicated"
  }
}

# Versioning: every apply writes a new version of the state. If a state gets
# corrupted, or if someone runs an improper destroy, you can restore the
# previous version and regain control of the resources. It is Terraform's
# undo - that is why versioning here is required, not optional.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (AES256), not KMS. An AWS-managed key avoids the cost and the point
# of failure of a CMK - same reasoning as the decision about the account's
# default EBS encryption.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Housekeeping only: cleans up interrupted uploads, which are still billed and
# do not show up in the normal object listing.
#
# Do NOT add old-version expiration here. In the flow logs bucket retention
# makes sense because the volume grows; here each version is a few KB, and
# deleting old versions throws away the ability to recover.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "abort-multipart-7d"
    status = "Enabled"

    # An empty filter is not an oversight: it is how you say "applies to all
    # objects".
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# "moved" blocks: renaming without destroying anything
#
# These are left over from renaming the resources. The original name was
# "bucket", which only said what the resource WAS; "state" says what it is
# FOR. Worth the rename, and kept here as a worked example of the mechanism.
#
# The resource name is the KEY in the state. Changing "bucket" to "state"
# without warning would make Terraform conclude that the old one was removed
# and the new one needs to be created - that is, it would try to DESTROY AND
# RECREATE the bucket.
#
# The "moved" block says: "this resource changed its name, it is the same
# object". The next apply only updates the state, without touching AWS. The
# plan shows the changes as "moved", not as create/destroy - check before
# applying.
#
# After a successful apply these blocks can be removed from the file.
# ---------------------------------------------------------------------------

moved {
  from = aws_s3_bucket.bucket
  to   = aws_s3_bucket.state
}

moved {
  from = aws_s3_bucket_versioning.bucket
  to   = aws_s3_bucket_versioning.state
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.bucket
  to   = aws_s3_bucket_server_side_encryption_configuration.state
}

moved {
  from = aws_s3_bucket_public_access_block.bucket
  to   = aws_s3_bucket_public_access_block.state
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.bucket
  to   = aws_s3_bucket_lifecycle_configuration.state
}

# ---------------------------------------------------------------------------
# outputs: values that Terraform prints at the end of the apply.
# ---------------------------------------------------------------------------

output "state_bucket" {
  description = "Name of the state bucket, to use in the backend block"
  value       = aws_s3_bucket.state.id
}
