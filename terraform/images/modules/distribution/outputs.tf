# ---------------------------------------------------------------------------
# modules/distribution/outputs.tf
# ---------------------------------------------------------------------------

output "arn" {
  description = "ARN da distribution configuration, consumido pelo pipeline"
  value       = aws_imagebuilder_distribution_configuration.this.arn
}

output "name" {
  description = "Nome da distribution configuration"
  value       = aws_imagebuilder_distribution_configuration.this.name
}
