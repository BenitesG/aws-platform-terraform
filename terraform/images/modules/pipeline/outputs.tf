# ---------------------------------------------------------------------------
# modules/pipeline/outputs.tf
# ---------------------------------------------------------------------------

output "arn" {
  description = "ARN do pipeline, para disparar a build pela CLI"
  value       = aws_imagebuilder_image_pipeline.this.arn
}

output "name" {
  description = "Nome do pipeline"
  value       = aws_imagebuilder_image_pipeline.this.name
}
