##################################################################
#_____ WINDOWS SERVER IMAGE _____________________________________#
##################################################################
# AMI mais recente do Windows Server 2025 via SSM Parameter público da AWS.
# O valor é resolvido no apply; a instância usa lifecycle.ignore_changes = [ami]
# para não ser recriada quando a AWS publicar uma AMI nova.
data "aws_ssm_parameter" "win2025" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2025-English-Full-Base"
}

##################################################################
#_____ NETWORK __________________________________________________#
##################################################################
# Deriva a VPC a partir da subnet informada, para os security groups não
# precisarem de vpc_id explícito em network.
data "aws_subnet" "selected" {
  id = var.network.subnet_id
}

##################################################################
#_____ SNS - TOPICO DOS ALARMES (A28) ___________________________#
##################################################################
# Topico criado no console (fronteira de gestao) e descoberto por nome. Um
# unico topico na conta (acme-swe-prod-alarms), reusado por todo o parque -
# prod, nonprod e este site Windows. As metricas StatusCheckFailed_System/
# _Instance sao agnosticas de SO, entao o alarme e identico ao das Linux.
data "aws_sns_topic" "alarms" {
  name = var.alarms_topic_name
}
