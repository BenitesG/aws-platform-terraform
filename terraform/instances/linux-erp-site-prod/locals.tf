##################################################################
#_____ LOCALS ___________________________________________________#
##################################################################
# Tags que VARIAM por maquina, montadas UMA vez e reusadas em instancia, SG,
# disco raiz e alarmes - para nao divergir entre eles.
#
# per_server_tags: so as que variam por maquina (Project/Application/
#   Environment/AutoWake/RequestId). O provider cola default_tags por cima nos
#   recursos que SUPORTAM - instancia, SG, alarme, ENI.
#
# root_device_tags: conjunto COMPLETO (per_server + common). O
#   root_block_device NAO herda default_tags do provider, entao precisa das
#   comuns explicitas aqui, senao o disco nasce so com Name (bug pego no plan
#   do primeiro state mv, 26/10).
locals {
  per_server_tags = {
    for host, cfg in var.servers : host => merge(
      {
        "acme:cost-allocation:Project"     = cfg.project
        "acme:cost-allocation:Application" = cfg.application
        "mb:automation:Environment"        = cfg.environment
        "mb:automation:AutoWake"           = cfg.auto_wake ? "true" : "false"
      },
      cfg.request_id != null ? { RequestId = cfg.request_id } : {},
    )
  }

  root_device_tags = {
    for host, cfg in var.servers : host => merge(
      var.common_tags,
      local.per_server_tags[host],
    )
  }
}
