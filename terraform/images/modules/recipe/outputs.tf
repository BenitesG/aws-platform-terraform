# ---------------------------------------------------------------------------
# modules/recipe/outputs.tf
# ---------------------------------------------------------------------------

output "arn" {
  description = "Recipe ARN, consumed by the pipeline"
  value       = aws_imagebuilder_image_recipe.this.arn
}

output "name" {
  description = "Recipe name"
  value       = aws_imagebuilder_image_recipe.this.name
}

output "version" {
  description = "Recipe version"
  value       = aws_imagebuilder_image_recipe.this.version
}

output "parent_image" {
  description = "Parent AMI used. Useful for recording traceability in the distribution."
  value       = aws_imagebuilder_image_recipe.this.parent_image
}
