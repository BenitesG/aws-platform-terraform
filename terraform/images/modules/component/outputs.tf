# ---------------------------------------------------------------------------
# modules/component/outputs.tf
# ---------------------------------------------------------------------------

output "arn" {
  description = "ARN do componente, com a versao embutida. E o que a receita consome."
  value       = aws_imagebuilder_component.this.arn
}

output "name" {
  description = "Nome do componente"
  value       = aws_imagebuilder_component.this.name
}

output "version" {
  description = "Versao do componente"
  value       = aws_imagebuilder_component.this.version
}
