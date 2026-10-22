# ---------------------------------------------------------------------------
# modules/pipeline/outputs.tf
# ---------------------------------------------------------------------------

output "arn" {
  description = "Pipeline ARN, to trigger the build via the CLI"
  value       = aws_imagebuilder_image_pipeline.this.arn
}

output "name" {
  description = "Pipeline name"
  value       = aws_imagebuilder_image_pipeline.this.name
}
