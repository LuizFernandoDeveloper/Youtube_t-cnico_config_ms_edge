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
