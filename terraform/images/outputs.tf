# ---------------------------------------------------------------------------
# images/outputs.tf
#
# Build e ACAO, nao estado: nao ha recurso no Terraform para executar o
# pipeline. Estes outputs sao os ARNs que a CLI e a esteira usam para disparar.
# ---------------------------------------------------------------------------

output "base_pipeline_arn" {
  description = "Pipeline da imagem base. Dispare com start-image-pipeline-execution."
  value       = module.base_pipeline.arn
}

output "docker_host_pipeline_arn" {
  description = "Pipeline do host de container. Precisa que a base_ami_id esteja atualizada."
  value       = module.docker_host_pipeline.arn
}

output "base_arm64_pipeline_arn" {
  description = "Pipeline da imagem base ARM64 (Graviton), para instancias t4g"
  value       = module.base_arm64_pipeline.arn
}

output "parent_ami_ubuntu_em_uso" {
  description = "AMI-pai amd64 que as receitas usam de fato (fixa no tfvars)"
  value       = local.parent_ami_ubuntu
}

output "parent_ami_ubuntu_arm64_em_uso" {
  description = "AMI-pai arm64 que a receita usa de fato (fixa no tfvars)"
  value       = local.parent_ami_ubuntu_arm64
}

# Os dois outputs abaixo sao INFORMATIVOS: dizem qual AMI a Canonical publica
# hoje. Compare com as "em_uso" acima para saber se ha atualizacao disponivel.
#
# Se divergirem, atualizar e ATO DELIBERADO: trocar base_parent_ami_* no
# tfvars SUBSTITUI a receita, entao suba o recipe_version junto e apague
# imagens antigas que travem a remocao.
#
# insecure_value em vez de value: o aws_ssm_parameter marca "value" como
# sensivel por padrao, porque nao sabe se o parametro guarda segredo. Exportar
# em output exigiria sensitive = true. Como um ID de AMI publica da Canonical
# nao e segredo, o atributo correto e insecure_value.
output "parent_ami_ubuntu_disponivel" {
  description = "AMI amd64 que a Canonical publica AGORA. Compare com a em uso."
  value       = data.aws_ssm_parameter.ubuntu.insecure_value
}

output "parent_ami_ubuntu_arm64_disponivel" {
  description = "AMI arm64 que a Canonical publica AGORA. Compare com a em uso."
  value       = data.aws_ssm_parameter.ubuntu_arm64.insecure_value
}

output "base_ami_in_use_as_docker_parent" {
  description = <<-EOT
    AMI da imagem base que a linhagem do Docker usa como pai.

    Conferir depois de cada build nova da base: este valor NAO acompanha
    sozinho, de proposito. Atualizar e ato deliberado, porque muda a receita
    do host de container e exige subir a versao dela.
  EOT
  value       = var.base_ami_id
}

output "build_security_group_id" {
  description = "Security group da instancia temporaria de build"
  value       = module.build_infrastructure.security_group_id
}
