# ---------------------------------------------------------------------------
# network-peering/main.tf
#
# VPC peering entre acme-swe-prod (111122223333) e a conta de producao.
# Cartoes A33 -> A34 do plano de acao.
#
# METADE DO TRABALHO E NA OUTRA CONTA e nao pode estar aqui: nao temos
# credencial lado de la. Aceitacao, rota de volta e "accepter DNS resolution"
# sao passos manuais do responsavel da conta de producao.
#
# ORDEM DE EXECUCAO - sao DOIS applies, de proposito:
#
#   apply 1 (agora)  : cria a solicitacao de peering
#   -> o outro lado ACEITA
#   apply 2 (depois) : rota na rt-private + resolucao de DNS do nosso lado
#
# Por que nao tudo de uma vez: rota e opcoes de DNS exigem que a conexao
# esteja ACTIVE. Com a conexao em pending-acceptance, o apply falharia no
# meio, com a solicitacao ja criada e o estado parcialmente aplicado.
# ---------------------------------------------------------------------------

# ===========================================================================
# ETAPA 1 - a solicitacao
# ===========================================================================

resource "aws_vpc_peering_connection" "production" {
  vpc_id = var.vpc_id # requester: acme-swe-prod

  peer_vpc_id   = var.production_vpc_id
  peer_owner_id = var.production_account_id

  # Mesma regiao (us-west-2), entao peer_region nao e declarado. Declarar
  # peer_region igual a regiao do provider cria peering INTER-regiao e muda o
  # custo: transferencia passa a ser cobrada por GB.
  #
  # auto_accept so funciona quando as duas VPCs estao na MESMA conta. Aqui a
  # aceitacao e obrigatoriamente manual, na conta de producao.
  auto_accept = false

  tags = {
    Name = "acme-swe-prod-peering-production"
  }

  # A solicitacao PENDENTE expira em 7 dias. Se expirar, o Terraform vera a
  # conexao como "expired" e o proximo plan proporá recriar - o que e o
  # comportamento correto, mas significa combinar nova janela com o outro lado.
  lifecycle {
    precondition {
      condition     = var.production_vpc_cidr != "10.20.0.0/16"
      error_message = "CIDR identico ao da acme-swe-prod. A AWS recusa peering com CIDRs sobrepostos."
    }
  }
}

# ===========================================================================
# ETAPA 2 - REATIVADA EM 16/10/2026
#
# Historico, porque ela foi e voltou duas vezes:
#
#   15/10  aplicada para a pcx-0a1b2c3d4e5f90001
#   16/10  comentada - a troca de VPC destruiu a conexao (peer_vpc_id e
#          ForceNew) e a nova nasceu em pending-acceptance
#   16/10  reativada - a pcx-0a1b2c3d4e5f90002 esta active e aceita
#
# A ROTA FOI IMPORTADA, NAO CRIADA POR ESTE CODIGO. Ela foi feita a mao
# durante o diagnostico do CIDR errado, e trazida para o estado com:
#
#   terraform import aws_route.to_production "rtb-0a1b2c3d4e5f80001_172.31.0.0/16"
#
# POR QUE IMPORT E NAO APAGAR E RECRIAR: ha TRAFEGO REAL passando por esta
# rota. Import nao faz chamada nenhuma na AWS - so escreve a ligacao no
# estado -, enquanto apagar e recriar teria uma janela sem rota.
#
# E POR QUE IMPORTAR EM VEZ DE DEIXAR FORA: rota fora do estado e invisivel
# para o Terraform. O risco concreto: se a conexao for substituida outra vez,
# ele destruiria a conexao e NAO a rota, deixando uma rota em BLACKHOLE
# apontando para peering inexistente - engolindo em silencio o trafego para
# 172.31.0.0/16. Em 16/10 aconteceu o oposto, e foi bom: a rota estava no
# estado, o Terraform a destruiu junto e a tabela ficou limpa.
# ===========================================================================

# ---------------------------------------------------------------------------
# Rota de ida: da acme-swe-prod para a producao.
#
# Vai na rt-private porque e ela que esta associada explicitamente a
# private-c e private-d - as subnets onde as instancias vivem. A rt-main fica
# so com "local" de proposito (ver decisao do A15) e NAO recebe esta rota.
#
# A TABELA ESTA FORA DO TERRAFORM, E ISSO E DELIBERADO. O aws_route gerencia
# UMA rota dentro de uma tabela existente, referenciada por ID - nao exige
# que a tabela esteja no estado. Nao confundir essa fronteira EXPLICITA com a
# rota ter ficado fora do estado, que foi acidente e acabou de ser corrigido.
#
# ESTA ROTA SOZINHA NAO FAZ TRAFEGO PASSAR. Precisa da rota reciproca
# (10.20.0.0/16 -> a conexao) na conta de producao. Ela existe - a integracao
# esta funcionando desde 16/10 -, mas FALTA CONFIRMAR em qual route table
# dela: tabela main so vale para subnet sem associacao explicita.
# ---------------------------------------------------------------------------

resource "aws_route" "to_production" {
  route_table_id            = var.private_route_table_id
  destination_cidr_block    = var.production_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.production.id
}

# ---------------------------------------------------------------------------
# Resolucao de DNS do NOSSO lado (requester).
#
# Por padrao o peering NAO resolve o DNS privado da outra VPC. O sintoma e
# "o host nao existe" - parece erro de aplicacao, nao de rede.
#
# So importa se a integracao usar NOME em vez de IP. Hoje a integracao usa IP
# direto (ver erp_host_cidr no tfvars de instances/), entao isto e dispensavel
# para o que ja funciona. Ligar nao tem custo nem efeito colateral, e evita um
# diagnostico futuro se alguem passar a usar nome.
#
# ESTE E O UNICO RECURSO QUE ESTE APPLY CRIA DE FATO: hoje o valor na AWS e
# false, porque foi destruido junto com a conexao antiga.
#
# O lado accepter e espelho deste e NAO pode ser declarado aqui: exigiria
# credencial da conta de producao. E passo manual de la
# (Actions -> Edit DNS settings -> Accepter DNS resolution), e continua
# pendente de confirmacao.
# ---------------------------------------------------------------------------

resource "aws_vpc_peering_connection_options" "requester" {
  vpc_peering_connection_id = aws_vpc_peering_connection.production.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

# ===========================================================================
# O QUE DELIBERADAMENTE NAO ESTA AQUI
#
# As REGRAS DE SECURITY GROUP (cartao A35). Dependem de duas respostas da
# engenharia que ainda nao temos: quem inicia a conexao e em qual porta.
#
# O peering existir NAO faz trafego nenhum passar - quem decide isso e o
# security group, e o acme-swe-prod-app01-sg continua com entrada vazia e
# saida restrita a 443/80. E por isso que criar o peering agora e seguro.
#
# Atencao ao A35: abrir a porta da integracao e facil de reverter no papel e
# dificil na pratica. Depois que o trafego real estiver passando, fechar
# derruba a integracao.
# ===========================================================================

output "peering_connection_id" {
  description = "Passar para o responsavel da conta de producao - e o que ele procura para aceitar"
  value       = aws_vpc_peering_connection.production.id
}

output "peering_status" {
  description = "pending-acceptance ate o outro lado aceitar"
  value       = aws_vpc_peering_connection.production.accept_status
}
