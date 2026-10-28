# ---------------------------------------------------------------------------
# modules/infrastructure/outputs.tf
# ---------------------------------------------------------------------------

output "arn" {
  description = "ARN da infrastructure configuration, consumido pelo pipeline"
  value       = aws_imagebuilder_infrastructure_configuration.this.arn
}

output "role_name" {
  description = "Nome do papel da instancia de build"
  value       = aws_iam_role.this.name
}

output "role_arn" {
  description = "ARN do papel da instancia de build"
  value       = aws_iam_role.this.arn
}

output "instance_profile_name" {
  description = "Nome do instance profile da instancia de build"
  value       = aws_iam_instance_profile.this.name
}

output "security_group_id" {
  description = "ID do security group da instancia de build"
  value       = aws_security_group.this.id
}
