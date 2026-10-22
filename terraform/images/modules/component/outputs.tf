# ---------------------------------------------------------------------------
# modules/component/outputs.tf
# ---------------------------------------------------------------------------

output "arn" {
  description = "Component ARN, with the version embedded. This is what the recipe consumes."
  value       = aws_imagebuilder_component.this.arn
}

output "name" {
  description = "Component name"
  value       = aws_imagebuilder_component.this.name
}

output "version" {
  description = "Component version"
  value       = aws_imagebuilder_component.this.version
}
