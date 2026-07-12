# Youtube_t-cnico_config_ms_edge

Projeto PowerShell para criar ambientes isolados do Microsoft Edge usando `--user-data-dir`, atalhos individuais, configuracao externa em JSON, logs, backup/restauracao e instalacao assistida de extensoes.

## Uso rapido

```powershell
.\New-EdgeProfiles.ps1 -DryRun
.\New-EdgeProfiles.ps1 -Create
.\New-EdgeProfiles.ps1 -Create -YesToAll
.\New-EdgeProfiles.ps1 -Reports
.\New-EdgeProfiles.ps1 -UpdateShortcuts
.\New-EdgeProfiles.ps1 -Backup
.\New-EdgeProfiles.ps1 -Restore -BackupPath ".\Backups\2026-07-12_173000"
.\New-EdgeProfiles.ps1 -RemoveProfile "20-Engenharia-Eletrica-Automacao"
.\New-EdgeProfiles.ps1 -OpenAll
.\Tests\Run-Tests.ps1
```

Por padrao, os perfis sao definidos em `profiles.json`, os pacotes de extensoes em `extension-packs.json` e o plano de canais em `channel-map.csv`.

Quando o script detecta perfis ou atalhos criados em uma execucao anterior, ele mostra uma tela de recuperacao antes de continuar:

```text
1. Continuar de onde parou
2. Apagar o que foi feito e sair
3. Refazer tudo (backup + apagar + criar de novo)
4. Decidir perfil por perfil
```

Antes da criacao, o script lista os perfis ativos com conta, Brand Account e extensoes. Use `Y`, `N` ou `B` para marcar perfis como executar, pular ou bloquear nesta rodada.

No modo assistido de extensoes, a lista aparece marcada como `Y` por padrao. Pressione `Enter` para abrir as extensoes `Y`, use `Y 1 3`, `N 2` ou `B 4` para decidir por item, `A` para aprovar todas ou `P`/`N` para pular o perfil.

`-YesToAll` aprova os passos seguros automaticamente: continua execucoes parciais, aprova todos os perfis ativos e abre todas as paginas de extensao recomendadas. O script continua sem digitar e-mail, senha, CAPTCHA, 2FA ou selecionar Brand Account automaticamente.

`-Reports` gera:

```text
Reports\duplicate-channels.csv
Reports\migration-plan.html
Reports\profile-status.csv
```

As imagens das quatro contas ficam em:

```text
Assets\accounts
├── accounts-assets.json
├── accounts-preview.png
├── 00-conta-matriz-administracao-card.png
├── 10-base-academica-card.png
├── 20-engenharia-tecnologia-aplicada-card.png
└── 30-conteudo-diversificado-card.png
```
