# Youtube_t-cnico_config_ms_edge

Projeto PowerShell para criar ambientes isolados do Microsoft Edge usando `--user-data-dir`, atalhos individuais, configuracao externa em JSON, logs, backup/restauracao e instalacao assistida de extensoes.

## Uso rapido

```powershell
.\New-EdgeProfiles.ps1 -DryRun
.\New-EdgeProfiles.ps1 -Create
.\New-EdgeProfiles.ps1 -UpdateShortcuts
.\New-EdgeProfiles.ps1 -Backup
.\New-EdgeProfiles.ps1 -Restore -BackupPath ".\Backups\2026-07-12_173000"
.\New-EdgeProfiles.ps1 -RemoveProfile "YT-Engenharia"
.\New-EdgeProfiles.ps1 -OpenAll
```

Por padrao, os perfis sao definidos em `profiles.json` e os pacotes de extensoes em `extension-packs.json`.

Quando o script detecta perfis ou atalhos criados em uma execucao anterior, ele mostra uma tela de recuperacao antes de continuar:

```text
1. Continuar de onde parou
2. Apagar o que foi feito e sair
3. Refazer tudo (backup + apagar + criar de novo)
4. Decidir perfil por perfil
```

No modo assistido de extensoes, a lista aparece marcada por padrao. Pressione `Enter` para abrir as selecionadas, digite numeros para alternar itens, `A` para aprovar todas ou `P`/`N` para pular.
