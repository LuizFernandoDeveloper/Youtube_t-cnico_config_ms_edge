# Youtube_t-cnico_config_ms_edge

Projeto PowerShell para criar ambientes isolados do Microsoft Edge usando `--user-data-dir`, atalhos individuais, configuracao externa em JSON, logs, backup/restauracao e instalacao assistida de extensoes.

## Uso rapido

```powershell
.\New-EdgeProfiles.ps1 -DryRun
.\New-EdgeProfiles.ps1 -Create
.\New-EdgeProfiles.ps1 -Create -YesToAll
.\New-EdgeProfiles.ps1 -Create -FullAuto
.\New-EdgeProfiles.ps1 -Create -ApplyBaseConfig
.\New-EdgeProfiles.ps1 -Reports
.\New-EdgeProfiles.ps1 -SecurityCheck
.\New-EdgeProfiles.ps1 -InspectNativeProfiles
.\New-EdgeProfiles.ps1 -AuditFactoryProfiles
.\New-EdgeProfiles.ps1 -SanitizeFactoryProfiles -NoBrowser
.\New-EdgeProfiles.ps1 -ShowBrowserPolicy
.\New-EdgeProfiles.ps1 -ApplyHollowBrowserPolicy
.\New-EdgeProfiles.ps1 -UndoHollowBrowserPolicy
.\New-EdgeProfiles.ps1 -UpdateShortcuts
.\New-EdgeProfiles.ps1 -Backup
.\New-EdgeProfiles.ps1 -Restore -BackupPath ".\Backups\2026-07-12_173000"
.\New-EdgeProfiles.ps1 -RemoveProfile "20-Engenharia-Eletrica-Automacao"
.\New-EdgeProfiles.ps1 -OpenAll
.\Tests\Run-Tests.ps1
```

Por padrao, os perfis sao definidos em `profiles.json`, os pacotes de extensoes em `extension-packs.json` e o plano de canais em `channel-map.csv`.

Importante: estes perfis sao ambientes isolados por `--user-data-dir`. Eles abrem pelos atalhos criados e nao aparecem como varias contas no seletor interno do Edge padrao.

Os atalhos gerados tambem usam `--disable-sync`, `--disable-background-mode` e `--no-default-browser-check` para reduzir a chance de o Edge puxar a conta Microsoft do Windows para dentro dos ambientes isolados.

Limite real da automacao: o script nao cria Contas Google, Brand Accounts nem perfis nativos dentro do seletor interno do Edge. A abordagem documentada e confiavel aqui e criar ambientes isolados por pasta de dados e atalhos. Login, escolha de Brand Account e instalacao final das extensoes continuam dependendo de acao manual no navegador.

Use `-InspectNativeProfiles` para listar os perfis que aparecem no seletor interno do Edge, como `Perfil 1`, `Perfil 3` e `Pessoal 2`. Esse modo e somente leitura.

Use `-AuditFactoryProfiles` para listar, sem abrir navegador, se algum perfil da fabrica recebeu estado de login/sync do proprio Edge. Se aparecer `MISTURA`, isso e o Edge mostrando a conta Microsoft/Windows no perfil isolado.

Use `-SanitizeFactoryProfiles -NoBrowser` para limpar esse estado de login/sync do Edge nos perfis da fabrica sem tocar em senhas, cookies, tokens, cofre do Kaspersky ou dados de login de sites. O script cria backup dos arquivos antes de alterar.

Por padrao, ao aplicar nome/foto/metadados, o script tambem deixa o perfil do navegador "oco": sem e-mail do Edge, sem sync do Edge e sem conta Microsoft/Windows gravada no card do perfil.

Limite importante: o Edge pode recolocar a conta Microsoft/Windows quando o navegador abre. A politica que impede isso (`BrowserSignin=0`, `SyncDisabled=1` e `HideFirstRunExperience=1`) e GLOBAL para o Microsoft Edge desse usuario: ela tambem remove/bloqueia login e sync da conta principal do Edge. Se voce quer manter a conta principal logada, nao use esse modo. Use `-UndoHollowBrowserPolicy` em PowerShell como Administrador para restaurar os valores anteriores salvos.

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

Na tela de plano, digitar apenas `Y` tambem vira "sim para tudo": aprova todos os perfis e abre todas as extensoes recomendadas sem perguntar uma por uma.

`-ApplyBaseConfig` copia configuracoes seguras do perfil base `00-Administracao-Google` para os demais perfis, sem copiar cookies, senhas, tokens, contas logadas, banco de dados ou dados internos do Kaspersky. Ele tambem aplica nome correto, metadata e icone/foto de conta aos perfis.

`-FullAuto` equivale a criacao automatica com `-YesToAll` e `-ApplyBaseConfig`.

`-NoBrowser` impede abertura de janelas do Edge durante a execucao. Com `-FullAuto`, o script tambem saneia login/sync do proprio Edge antes de inicializar cada perfil.

Para uma primeira execucao mais estavel, crie/configure os ambientes sem abrir paginas de extensao:

```powershell
.\New-EdgeProfiles.ps1 -Create -FullAuto -ExtensionMode None
```

Para fazer tudo no back, sem abrir navegador:

```powershell
.\New-EdgeProfiles.ps1 -Create -FullAuto -NoBrowser -ExtensionMode None
```

Para desfazer a politica global e permitir a conta principal de novo:

```powershell
# PowerShell como Administrador
cd F:\codex\config_contas_ms_edge
.\New-EdgeProfiles.ps1 -UndoHollowBrowserPolicy
```

Para fazer o modo oco funcionar de forma confiavel, aceitando que isso tambem afeta a conta principal do Edge, aplique a politica antes e feche/reabra o Edge:

```powershell
# PowerShell como Administrador
.\New-EdgeProfiles.ps1 -ApplyHollowBrowserPolicy -Force
.\New-EdgeProfiles.ps1 -Create -FullAuto -NoBrowser -ExtensionMode None
.\New-EdgeProfiles.ps1 -AuditFactoryProfiles
```

Depois, abra as paginas de extensoes recomendadas em uma fase separada:

```powershell
.\New-EdgeProfiles.ps1 -Create -YesToAll
```

`-SecurityCheck` faz uma checagem segura do Kaspersky: detecta processos/produtos como antivirus, VPN e Password Manager, mas nao le senhas, tokens, cookies, cofres ou dados internos da extensao. Durante o login manual, use o Kaspersky Password Manager voce mesmo para preencher as credenciais no Edge.

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
