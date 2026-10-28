output "instance_ids" {
  description = "ID de cada instância, chaveado por hostname."
  value       = { for k, v in aws_instance.this : k => v.id }
}

output "instance_private_ips" {
  description = "IP privado de cada instância, chaveado por hostname."
  value       = { for k, v in aws_instance.this : k => v.private_ip }
}

output "data_volume_ids" {
  description = "ID de cada volume de dados, chaveado por hostname:device_name."
  value       = { for k, v in aws_ebs_volume.data : k => v.id }
}

output "s3_bucket_arn" {
  description = "ARN do bucket S3 de software compartilhado e backups."
  value       = aws_s3_bucket.this.arn
}

output "s3_bucket_name" {
  description = "Nome do bucket S3."
  value       = aws_s3_bucket.this.id
}

output "instance_role_arns" {
  description = "ARN da IAM role de cada instância, chaveado por hostname."
  value       = { for k, v in aws_iam_role.instance : k => v.arn }
}

output "key_pair_names" {
  description = "Nome da key pair de cada instância, chaveado por hostname."
  value       = { for k, v in aws_key_pair.this : k => v.key_name }
}

output "security_group_ids" {
  description = "ID do security group de cada instância, chaveado por hostname."
  value       = { for k, v in aws_security_group.this : k => v.id }
}
