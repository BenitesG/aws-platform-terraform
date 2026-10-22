# ---------------------------------------------------------------------------
# images/outputs.tf
#
# A build is an ACTION, not state: there is no Terraform resource to run the
# pipeline. These outputs are the ARNs that the CLI and the CI pipeline use to
# trigger it.
# ---------------------------------------------------------------------------

output "base_pipeline_arn" {
  description = "Base image pipeline. Trigger it with start-image-pipeline-execution."
  value       = module.base_pipeline.arn
}

output "docker_host_pipeline_arn" {
  description = "Container host pipeline. Requires base_ami_id to be up to date."
  value       = module.docker_host_pipeline.arn
}

output "base_arm64_pipeline_arn" {
  description = "Base ARM64 (Graviton) image pipeline, for t4g instances"
  value       = module.base_arm64_pipeline.arn
}

output "parent_ami_ubuntu_em_uso" {
  description = "amd64 parent AMI the recipes actually use (pinned in the tfvars)"
  value       = local.parent_ami_ubuntu
}

output "parent_ami_ubuntu_arm64_em_uso" {
  description = "arm64 parent AMI the recipe actually uses (pinned in the tfvars)"
  value       = local.parent_ami_ubuntu_arm64
}

# The two outputs below are INFORMATIONAL: they tell which AMI Canonical
# publishes today. Compare them with the "em_uso" ones above to know whether an
# update is available.
#
# If they diverge, updating is a DELIBERATE ACT: changing base_parent_ami_* in
# the tfvars REPLACES the recipe, so bump the recipe_version along with it and
# delete old images that block the removal.
#
# insecure_value instead of value: aws_ssm_parameter marks "value" as sensitive
# by default, because it does not know whether the parameter holds a secret.
# Exporting it in an output would require sensitive = true. Since a public
# Canonical AMI ID is not a secret, the correct attribute is insecure_value.
output "parent_ami_ubuntu_disponivel" {
  description = "amd64 AMI that Canonical publishes NOW. Compare with the one in use."
  value       = data.aws_ssm_parameter.ubuntu.insecure_value
}

output "parent_ami_ubuntu_arm64_disponivel" {
  description = "arm64 AMI that Canonical publishes NOW. Compare with the one in use."
  value       = data.aws_ssm_parameter.ubuntu_arm64.insecure_value
}

output "base_ami_in_use_as_docker_parent" {
  description = <<-EOT
    AMI of the base image that the Docker lineage uses as parent.

    Check after every new base build: this value does NOT follow along on its
    own, on purpose. Updating is a deliberate act, because it changes the
    container host recipe and requires bumping its version.
  EOT
  value       = var.base_ami_id
}

output "build_security_group_id" {
  description = "Security group of the temporary build instance"
  value       = module.build_infrastructure.security_group_id
}
