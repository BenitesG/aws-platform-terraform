##################################################################
#_____ DATA SOURCES _____________________________________________#
##################################################################

# Topico SNS dos alarmes (A28). Criado no console (fronteira de gestao) e
# descoberto por nome - nao por ARN no tfvars. Topico por nome nao muda
# sozinho, entao nao se aplica aqui a proibicao de data source que existe para
# AMI (onde "latest" recriaria a instancia).
#
# As inscricoes (user-a, user-b, user-c) foram
# confirmadas e a entrega provada de ponta a ponta em 22/10. "Successfully
# executed action" significa que o CloudWatch entregou ao SNS - NAO que o
# e-mail chegou; o SNS nao da delivery status para e-mail.
data "aws_sns_topic" "alarms" {
  name = var.alarms_topic_name
}
