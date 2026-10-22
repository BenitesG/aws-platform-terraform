# ---------------------------------------------------------------------------
# instances/backend.tf
#
# key DIFFERENT from bootstrap/ and images/. Its own isolated state.
#
# If two configurations used the same key, the second one to run would think it
# owns the resources of the first - and a destroy would wipe out another
# project's resources. Terraform does not validate this: a unique key per
# configuration is a manual rule of this repository.
#
# Reminder: the backend block does NOT accept variables, and it does not inherit
# the provider's profile. Before init:  $env:AWS_PROFILE = "acme-swe-prod"
# ---------------------------------------------------------------------------

terraform {
  backend "s3" {
    bucket       = "acme-swe-prod-tfstate"
    key          = "instances/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
