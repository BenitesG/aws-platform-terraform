terraform {
  backend "s3" {
    bucket       = "acme-swe-prod-tfstate"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}