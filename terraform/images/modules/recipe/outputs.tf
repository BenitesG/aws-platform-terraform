# ---------------------------------------------------------------------------
# modules/recipe/outputs.tf
# ---------------------------------------------------------------------------

output "arn" {
  description = "ARN da receita, consumido pelo pipeline"
  value       = aws_imagebuilder_image_recipe.this.arn
}

output "name" {
  description = "Nome da receita"
  value       = aws_imagebuilder_image_recipe.this.name
}

output "version" {
  description = "Versao da receita"
  value       = aws_imagebuilder_image_recipe.this.version
}

output "parent_image" {
  description = "AMI-pai usada. Util para registrar rastreabilidade na distribuicao."
  value       = aws_imagebuilder_image_recipe.this.parent_image
}
