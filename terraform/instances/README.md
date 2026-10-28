# instances/

Instâncias EC2 da conta `acme-swe-prod`. Cada **site/stack** é uma pasta com
state próprio — a raiz não provisiona recursos, é só o contêiner.

## Estrutura

| Pasta | O que é | State |
|-------|---------|-------|
| `_templates/` | molde para criar stack nova (copie e ajuste) | — |
| `linux-erp-site-nonprod/` | 3 Linux do site legacy ERP, nonprod + client SG | `instances/swe-nonprod/linux-erp-site` |
| `linux-erp-site-prod/` | 3 Linux do site legacy ERP, prod + client SG + agente CW | `instances/swe-prod/linux-erp-site` |
| `win-app-site/` | VMs App (Windows Server 2025), site SITE-A | `instances/swe-nonprod/win-app-site` |

Todas no estilo **mapa + `for_each`** (schema `servers` chaveado por hostname),
egress restrito a 443/80 (R07), SG por máquina, 2 alarmes de status (A28) por
máquina, IMDSv2.

## Criar um stack novo

```powershell
Copy-Item -Recurse instances\_templates instances\meu-site
```

Depois: troque a `key` do `backend.tf`, preencha `terraform.tfvars` (a partir do
`.example`), remova o que não se aplica (ex.: `clientsg.tf` se não fala com o
legacy ERP). Passo a passo em `_templates/README.md`.

Fluxo: `$env:AWS_PROFILE="acme-swe-prod"; terraform init; fmt; validate; plan`.
O backend não herda o profile — setar `AWS_PROFILE` antes do `init`. O apply das
instâncias exige o perfil admin (`iam:PassRole`).

## Documentação

- **Decisões de arquitetura** (ARQUIVO vs PASTA, quando criar state novo, egress
  R07, `state mv`, rename label vs arquivo): `docs/instances-decisoes.md`
- **Histórico** (README de quando as Linux viviam na raiz como módulo):
  `docs/instances-README-old.md`

## Histórico

As 6 Linux viviam na raiz como `module.ec2-instance` (um arquivo por máquina).
Migraram para `linux-erp-site-{nonprod,prod}` em 26/10 via `state mv` cross-state
(mudança de representação, não de posse), com `plan No changes` provado a cada
máquina.
