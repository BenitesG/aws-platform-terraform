# ---------------------------------------------------------------------------
# images/backend.tf
#
# Where the state of this configuration is stored.
#
# IMPORTANT: the backend block does NOT accept variables. No var.* here - it
# has to be a literal. This is a Terraform limitation, not a typo.
#
# The bucket must exist before the first "terraform init". Run the bootstrap/
# directory first.
#
# key: the path of the file inside the bucket. The prefix lets the same bucket
#   hold the state of several projects, each at its own path.
#
# use_lockfile: locks the state using S3 itself, dispensing with DynamoDB.
#   Without a lock, two simultaneous applies (you and the pipeline, for
#   example) read the same state, both decide to create, and the state ends up
#   inconsistent. Requires Terraform >= 1.10.
# ---------------------------------------------------------------------------

terraform {
  backend "s3" {
    bucket       = "acme-swe-prod-tfstate"
    key          = "images/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
