# ---------------------------------------------------------------------------
# modules/infrastructure/outputs.tf
# ---------------------------------------------------------------------------

output "arn" {
  description = "Infrastructure configuration ARN, consumed by the pipeline"
  value       = aws_imagebuilder_infrastructure_configuration.this.arn
}

output "role_name" {
  description = "Name of the build instance role"
  value       = aws_iam_role.this.name
}

output "role_arn" {
  description = "ARN of the build instance role"
  value       = aws_iam_role.this.arn
}

output "instance_profile_name" {
  description = "Name of the build instance's instance profile"
  value       = aws_iam_instance_profile.this.name
}

output "security_group_id" {
  description = "ID of the build instance security group"
  value       = aws_security_group.this.id
}
