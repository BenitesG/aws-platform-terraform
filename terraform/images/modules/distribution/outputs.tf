# ---------------------------------------------------------------------------
# modules/distribution/outputs.tf
# ---------------------------------------------------------------------------

output "arn" {
  description = "Distribution configuration ARN, consumed by the pipeline"
  value       = aws_imagebuilder_distribution_configuration.this.arn
}

output "name" {
  description = "Distribution configuration name"
  value       = aws_imagebuilder_distribution_configuration.this.name
}
