# ---------------------------------------------------------------------------
# modules/distribution/main.tf
#
# Para onde a AMI vai e COMO ELA E TAGUEADA.
#
# ESTE MODULO NAO EXISTE no repositorio de referencia da equipe, e o exemplo
# de la nao passa distribution_arn ao pipeline. A consequencia e concreta:
#
#   - a AMI e o snapshot nascem SEM as tags da norma
#   - e a politica de retencao do A41 para de funcionar, porque ela seleciona
#     por tag (resource_selection.tag_map Application = golden-image). Imagem
#     sem a tag fica fora da politica e acumula sem limite, em silencio
#
# ami_tags e o UNICO lugar que tagueia a AMI e o snapshot. O default_tags do
# provider nao alcanca nenhum dos dois, porque quem os cria e o Image Builder
# durante a build, nao o Terraform.
#
# VERIFICADO EM 14/10/2026: as tags do ami_tags propagam TAMBEM para o
# snapshot EBS - confirmado no snap-0a1b2c3d4e5fc0001, que veio com as treze
# tags. Nao e preciso tratamento extra para o snapshot, e a documentacao
# anterior que dizia o contrario estava errada.
# ---------------------------------------------------------------------------

resource "aws_imagebuilder_distribution_configuration" "this" {
  name        = var.name
  description = var.description

  distribution {
    region = var.region

    ami_distribution_configuration {
      # {{ imagebuilder:buildDate }} e substituido pelo servico no momento da
      # build, entao cada AMI sai com nome unico.
      name = "${var.name}-{{ imagebuilder:buildDate }}"

      # Tags da norma mais rastreabilidade.
      #
      # RecipeVersion e ParentImage respondem "de onde esta AMI veio", que e a
      # pergunta de qualquer diagnostico futuro. No caso da imagem empilhada,
      # ParentImage e a AMI da nossa propria imagem base - e e assim que a
      # cadeia fica auditavel.
      ami_tags = merge(
        var.common_tags,
        {
          Name          = var.name
          RecipeVersion = var.recipe_version
          ParentImage   = var.parent_image
        },
        var.extra_ami_tags
      )

      # Com quem a AMI e compartilhada. Vazio = so esta conta.
      #
      # Compartilhar entre contas exigiria CMK: snapshot criptografado com a
      # chave gerenciada aws/ebs NAO e compartilhavel. E o que sera preciso
      # quando as imagens mudarem para a conta de servicos compartilhados
      # (A32) - construir aqui e provisorio.
      target_account_ids = length(var.target_account_ids) > 0 ? var.target_account_ids : null
    }
  }
}
