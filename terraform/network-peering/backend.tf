# ---------------------------------------------------------------------------
# network-peering/backend.tf
#
# key DIFFERENT from bootstrap/, images/ and instances/. Its own, isolated state.
#
# If two configurations used the same key, the second one to run would think it
# owns the first one's resources - and a destroy would wipe out another
# project's things. Terraform does not validate this: a unique key per
# configuration is a manual rule of the repository.
#
# Reminder: the backend block does NOT accept a variable, and it does not
# inherit the profile from the provider. Before the init:
#   $env:AWS_PROFILE = "acme-swe-prod"
# ---------------------------------------------------------------------------

terraform {
  backend "s3" {
    bucket       = "acme-swe-prod-tfstate"
    key          = "network-peering/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
