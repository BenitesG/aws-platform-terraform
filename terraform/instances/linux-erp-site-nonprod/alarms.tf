##################################################################
# alarms.tf - 2 alarmes de status por maquina (A28) + config do agente CW
#
# for_each sobre var.servers: um par de alarmes por maquina, por construcao.
# Maquina nova no mapa nasce COM alarme - nao depende de alguem lembrar.
#
# As duas metricas de status check sao DIFERENTES:
#   _System   = infra da AWS embaixo (host, rede, hipervisor). Correcao =
#               mover de hardware (recover)
#   _Instance = SO da propria maquina (kernel, disco cheio, rede do SO).
#               Correcao = reboot
# Nenhuma tem acao automatica ainda - entram como decisao explicita depois.
#
# treat_missing_data = "notBreaching": as maquinas sao desligadas por decisao
# e o erp-vmwaker cicla as operationalflow por demanda. Ausencia de metrica e
# condicao NORMAL aqui - sem isto todo alarme iria para INSUFFICIENT_DATA.
##################################################################

locals {
  # Achata (maquina x tipo-de-alarme) para um for_each unico, chave composta.
  status_alarms = merge([
    for host, cfg in var.servers : {
      "${host}:system" = {
        host        = host
        name        = cfg.name
        metric      = "StatusCheckFailed_System"
        suffix      = "status-system"
        project     = cfg.project
        application = cfg.application
        environment = cfg.environment
        auto_wake   = cfg.auto_wake
        request_id  = cfg.request_id
        description = "Falha de status do SISTEMA (hardware, rede ou hipervisor da AWS) em ${cfg.name}. Instancia parada NAO dispara: ver treat_missing_data."
      }
      "${host}:instance" = {
        host        = host
        name        = cfg.name
        metric      = "StatusCheckFailed_Instance"
        suffix      = "status-instance"
        project     = cfg.project
        application = cfg.application
        environment = cfg.environment
        auto_wake   = cfg.auto_wake
        request_id  = cfg.request_id
        description = "Falha de status da INSTANCIA (SO: kernel, disco, rede do SO) em ${cfg.name}. NAO avisa disco enchendo - avisa a maquina morrendo. Instancia parada NAO dispara."
      }
    }
  ]...)
}

resource "aws_cloudwatch_metric_alarm" "status" {
  for_each = local.status_alarms

  alarm_name        = "${each.value.name}-${each.value.suffix}"
  alarm_description = each.value.description

  namespace   = "AWS/EC2"
  metric_name = each.value.metric

  dimensions = {
    InstanceId = aws_instance.this[each.value.host].id
  }

  # Status check sai de minuto em minuto SEM custo de monitoramento detalhado.
  period = 60

  # "Maximum": a metrica vale 0 ou 1, um unico ponto em 1 JA e a falha.
  statistic = "Maximum"

  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2

  treat_missing_data = "notBreaching"

  alarm_actions = [data.aws_sns_topic.alarms.arn]
  ok_actions    = [data.aws_sns_topic.alarms.arn]

  tags = merge(
    {
      "acme:cost-allocation:Project"     = each.value.project
      "acme:cost-allocation:Application" = each.value.application
      "mb:automation:Environment"        = each.value.environment
      "mb:automation:AutoWake"           = each.value.auto_wake ? "true" : "false"
      Name                               = "${each.value.name}-${each.value.suffix}"
    },
    each.value.request_id != null ? { RequestId = each.value.request_id } : {},
  )
}
