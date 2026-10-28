##################################################################
#_____ OUTPUTS __________________________________________________#
##################################################################
# Mapas chaveados por hostname (padrao do steering para recursos com
# for_each).

output "instance_ids" {
  description = "ID de cada instancia, chaveado por hostname."
  value       = { for k, v in aws_instance.this : k => v.id }
}

output "instance_private_ips" {
  description = "IP privado de cada instancia (deve estar em 10.20.1.x)."
  value       = { for k, v in aws_instance.this : k => v.private_ip }
}

output "security_group_ids" {
  description = "ID do SG proprio de cada instancia, chaveado por hostname."
  value       = { for k, v in aws_security_group.this : k => v.id }
}

output "client_security_group_id" {
  description = "ID do client SG (legacy ERP) nonprod, compartilhado pelas maquinas."
  value       = aws_security_group.client.id
}

output "status_alarm_names" {
  description = "Nome de cada alarme de status, chaveado por hostname:tipo."
  value       = { for k, v in aws_cloudwatch_metric_alarm.status : k => v.alarm_name }
}
