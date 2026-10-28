##################################################################
# alarms.tf - 2 alarmes de status por maquina (A28)
#
# Mesmo padrao das Linux (linux-erp-site): as metricas de status check sao
# AGNOSTICAS de SO - vem do hipervisor/EC2, nao do Windows - entao o bloco e
# identico. Adicionado aqui para o site Windows ter o mesmo monitoramento de
# base que o parque Linux, antes de abstrair os dois num modulo comum.
#
# As duas metricas sao DIFERENTES:
#   _System   = infra da AWS embaixo (host, rede, hipervisor). Correcao =
#               mover de hardware (recover)
#   _Instance = SO da propria maquina (kernel, disco cheio, rede do SO).
#               Correcao = reboot
#
# treat_missing_data = "notBreaching": maquinas de business-hours sao
# desligadas fora do horario (Schedule=business-hours no default_tags), e
# instancia parada nao publica metrica. Sem isto todo alarme iria para
# INSUFFICIENT_DATA e geraria ruido.
#
# Tags: herdadas do default_tags do provider (aws_configs.default_tags). So o
# Name e explicito aqui.
##################################################################

locals {
  status_alarms = merge([
    for host, cfg in var.servers : {
      "${host}:system" = {
        host        = host
        role        = cfg.role
        metric      = "StatusCheckFailed_System"
        suffix      = "status-system"
        description = "Falha de status do SISTEMA (hardware, rede ou hipervisor da AWS) em ${host} (${cfg.role}). Instancia parada NAO dispara: ver treat_missing_data."
      }
      "${host}:instance" = {
        host        = host
        role        = cfg.role
        metric      = "StatusCheckFailed_Instance"
        suffix      = "status-instance"
        description = "Falha de status da INSTANCIA (SO: kernel, disco, rede do SO) em ${host} (${cfg.role}). NAO avisa disco enchendo - avisa a maquina morrendo. Instancia parada NAO dispara."
      }
    }
  ]...)
}

resource "aws_cloudwatch_metric_alarm" "status" {
  for_each = local.status_alarms

  alarm_name        = "${each.value.host}-${each.value.suffix}"
  alarm_description = each.value.description

  namespace   = "AWS/EC2"
  metric_name = each.value.metric

  dimensions = {
    InstanceId = aws_instance.this[each.value.host].id
  }

  period    = 60
  statistic = "Maximum"

  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2

  treat_missing_data = "notBreaching"

  alarm_actions = [data.aws_sns_topic.alarms.arn]
  ok_actions    = [data.aws_sns_topic.alarms.arn]

  tags = {
    Name = "${each.value.host}-${each.value.suffix}"
  }
}
