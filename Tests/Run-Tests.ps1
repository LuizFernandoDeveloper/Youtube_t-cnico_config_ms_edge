[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$moduleRoot = Join-Path $root "Modules"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "Falha no teste: $Message"
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "Falha no teste: $Message. Esperado '$Expected', obtido '$Actual'."
    }
}

Import-Module (Join-Path $moduleRoot "Logger.psm1") -Force
Import-Module (Join-Path $moduleRoot "ProfileManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "ExtensionManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "AccountBrandingManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "ShortcutManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "ChannelMapManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "SecurityAssistant.psm1") -Force
Import-Module (Join-Path $moduleRoot "NativeEdgeProfileInspector.psm1") -Force

$psFiles = @(Get-ChildItem -Path $root -Recurse -Include *.ps1, *.psm1)
foreach ($file in $psFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-Equal 0 $errors.Count "Sintaxe PowerShell invalida em $($file.FullName)"
}

$mainScript = Get-Content -LiteralPath (Join-Path $root "New-EdgeProfiles.ps1") -Raw -Encoding UTF8
$configCallIndex = $mainScript.IndexOf("Set-ProfileAccountConfiguration -Config", [System.StringComparison]::Ordinal)
$initCallIndex = $mainScript.IndexOf("Invoke-ProfileInitialization -EdgePath", [System.StringComparison]::Ordinal)
Assert-True ($configCallIndex -ge 0) "Script principal deve aplicar branding/configuracao"
Assert-True ($initCallIndex -ge 0) "Script principal deve inicializar perfis"
Assert-True ($configCallIndex -lt $initCallIndex) "Branding/configuracao deve acontecer antes da inicializacao do Edge"

$edgeDetectionScript = Get-Content -LiteralPath (Join-Path $moduleRoot "EdgeDetection.psm1") -Raw -Encoding UTF8
Assert-True ($edgeDetectionScript.Contains("--disable-background-mode")) "Inicializacao do Edge deve desabilitar background mode"
Assert-True ($edgeDetectionScript.Contains("--disable-sync")) "Inicializacao do Edge deve desabilitar sync"
Assert-True ($edgeDetectionScript.Contains("Stop-Process -Id `$process.ProcessId -Force")) "Fechamento do Edge deve ter fallback forcado"

$shortcutManagerScript = Get-Content -LiteralPath (Join-Path $moduleRoot "ShortcutManager.psm1") -Raw -Encoding UTF8
Assert-True ($shortcutManagerScript.Contains("--disable-sync")) "Atalhos devem desabilitar sync"
Assert-True ($shortcutManagerScript.Contains("--disable-background-mode")) "Atalhos devem desabilitar background mode"

$configPath = Join-Path $root "profiles.json"
$packsPath = Join-Path $root "extension-packs.json"
$channelMapPath = Join-Path $root "channel-map.csv"
$accountAssetsPath = Join-Path $root "Assets\accounts\accounts-assets.json"

$config = Read-JsonFile -Path $configPath
$packs = Read-JsonFile -Path $packsPath
$baseDirectory = Resolve-FactoryPath -Path ([string]$config.baseDirectory) -BasePath $root

$packErrors = @(Test-ExtensionPacks -ExtensionPacks $packs)
Assert-Equal 0 $packErrors.Count "Pacotes de extensoes devem ser validos"

$profileErrors = @(Test-ProfileConfig -Config $config -BaseDirectory $baseDirectory -ExtensionPackNames (Get-ExtensionPackNames -ExtensionPacks $packs))
Assert-Equal 0 $profileErrors.Count "profiles.json deve ser valido"

$allProfiles = @(Get-ConfiguredProfiles -Config $config -IncludeInactive)
$activeProfiles = @(Get-ConfiguredProfiles -Config $config)
Assert-Equal 15 $allProfiles.Count "Quantidade total de perfis"
Assert-Equal 14 $activeProfiles.Count "Quantidade de perfis ativos"

$profile24 = @($allProfiles | Where-Object { (Get-ProfileCode -Profile $_) -eq "24" }) | Select-Object -First 1
Assert-True ($null -ne $profile24) "Perfil 24 deve existir"
Assert-True (-not (Test-ProfileEnabled -Profile $profile24)) "Perfil 24 deve estar desativado inicialmente"

$cofreProfile = @($allProfiles | Where-Object { (Get-ProfileCode -Profile $_) -eq "90" }) | Select-Object -First 1
Assert-True ($null -ne $cofreProfile) "Perfil 90 Cofre deve existir"
Assert-Equal "cofre" ([string]$cofreProfile.extensionPack) "Cofre deve usar pacote cofre"
foreach ($url in (Get-StartupPages -Profile $cofreProfile)) {
    Assert-True (-not ([string]$url -match "(youtube\.com|youtu\.be|facebook\.com|instagram\.com|tiktok\.com|x\.com|twitter\.com|reddit\.com)")) "Cofre nao deve abrir rede social: $url"
}

$cofrePack = Get-ExtensionPack -ExtensionPacks $packs -Name "cofre"
Assert-Equal 1 @($cofrePack.extensions).Count "Pacote cofre deve ter uma extensao"
Assert-True ([string]$cofrePack.extensions[0].name -match "Kaspersky Password Manager") "Pacote cofre deve conter Kaspersky Password Manager"

$accountAssets = Read-JsonFile -Path $accountAssetsPath
Assert-Equal 4 @($accountAssets.accounts).Count "Deve haver imagens para as quatro contas"
foreach ($account in @($accountAssets.accounts)) {
    $artPath = Join-Path (Split-Path -Parent $accountAssetsPath) ([string]$account.art)
    $cardPath = Join-Path (Split-Path -Parent $accountAssetsPath) ([string]$account.card)
    $iconPath = Join-Path (Split-Path -Parent $accountAssetsPath) ([string]$account.icon)
    Assert-True (Test-Path -LiteralPath $artPath -PathType Leaf) "Arte da conta deve existir: $artPath"
    Assert-True (Test-Path -LiteralPath $cardPath -PathType Leaf) "Card da conta deve existir: $cardPath"
    Assert-True (Test-Path -LiteralPath $iconPath -PathType Leaf) "Icone da conta deve existir: $iconPath"
}

foreach ($accountProperty in $config.accounts.PSObject.Properties) {
    $account = $accountProperty.Value
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$account.image)) "Conta '$($accountProperty.Name)' deve ter image"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$account.art)) "Conta '$($accountProperty.Name)' deve ter art"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$account.icon)) "Conta '$($accountProperty.Name)' deve ter icon"
    Assert-True (Test-Path -LiteralPath (Resolve-FactoryPath -Path ([string]$account.image) -BasePath $root) -PathType Leaf) "Imagem referenciada deve existir para '$($accountProperty.Name)'"
    Assert-True (Test-Path -LiteralPath (Resolve-FactoryPath -Path ([string]$account.art) -BasePath $root) -PathType Leaf) "Arte referenciada deve existir para '$($accountProperty.Name)'"
    Assert-True (Test-Path -LiteralPath (Resolve-FactoryPath -Path ([string]$account.icon) -BasePath $root) -PathType Leaf) "Icone referenciado deve existir para '$($accountProperty.Name)'"
}

$engineeringProfile = @($allProfiles | Where-Object { (Get-ProfileCode -Profile $_) -eq "20" }) | Select-Object -First 1
$engineeringIcon = Get-ProfileShortcutIconPath -Config $config -Profile $engineeringProfile
Assert-True (Test-Path -LiteralPath $engineeringIcon -PathType Leaf) "Perfil de engenharia deve resolver icone de atalho"

$signinTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("EdgeProfileFactorySigninTest_{0}" -f ([Guid]::NewGuid().ToString("N")))
try {
    $signinProfileDir = Get-ProfileDirectory -BaseDirectory $signinTestRoot -Profile $engineeringProfile
    New-Item -ItemType Directory -Path (Join-Path $signinProfileDir "Default") -Force | Out-Null

    $mixedPreferences = [pscustomobject]@{
        account_info = @([pscustomobject]@{ email = "luiz.fernando.rodrigues.andrade.souza@hotmail.com" })
        signin = [pscustomobject]@{ allowed = $true }
        sync = [pscustomobject]@{ requested = $true }
        profile = [pscustomobject]@{ name = "Conta misturada" }
    }
    $mixedPreferences | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $signinProfileDir "Default\Preferences") -Encoding UTF8

    $mixedLocalState = [pscustomobject]@{
        profile = [pscustomobject]@{
            info_cache = [pscustomobject]@{
                Default = [pscustomobject]@{
                    user_name = "luiz.fernando.rodrigues.andrade.souza@hotmail.com"
                    gaia_name = "Luiz Fernando"
                    signin_required = $true
                }
            }
        }
    }
    $mixedLocalState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $signinProfileDir "Local State") -Encoding UTF8

    $signinStateBefore = Get-EdgeBrowserSigninState -UserDataDir $signinProfileDir
    Assert-True ([bool]$signinStateBefore.HasBrowserSigninState) "Auditoria deve detectar estado de login do navegador"
    Assert-Equal "luiz.fernando.rodrigues.andrade.souza@hotmail.com" ([string]$signinStateBefore.LocalStateUser) "Auditoria deve ler e-mail do Local State"

    $factoryAudit = @(Get-FactoryProfileSigninAudit -Config $config -BaseDirectory $signinTestRoot | Where-Object { $_.Slug -eq [string]$engineeringProfile.slug })
    Assert-Equal 1 $factoryAudit.Count "Auditoria da fabrica deve retornar o perfil de engenharia"
    Assert-True ([bool]$factoryAudit[0].LooksMixed) "Auditoria da fabrica deve marcar mistura de login"

    $clearResult = Clear-EdgeBrowserSigninState -UserDataDir $signinProfileDir
    Assert-True ([bool]$clearResult.Changed) "Limpeza deve alterar arquivos quando ha login/sync"
    Assert-True (@($clearResult.Backups).Count -ge 2) "Limpeza deve criar backups antes de escrever"

    $signinStateAfter = Get-EdgeBrowserSigninState -UserDataDir $signinProfileDir
    Assert-True (-not [bool]$signinStateAfter.HasBrowserSigninState) "Limpeza deve remover estado de login do navegador"

    $preferencesAfterClear = Get-Content -LiteralPath (Join-Path $signinProfileDir "Default\Preferences") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (-not ($preferencesAfterClear.PSObject.Properties.Name -contains "account_info")) "Limpeza deve remover account_info"
    Assert-True (-not ($preferencesAfterClear.PSObject.Properties.Name -contains "signin")) "Limpeza deve remover signin"
    Assert-True (-not ($preferencesAfterClear.PSObject.Properties.Name -contains "sync")) "Limpeza deve remover sync"

    $localStateAfterClear = Get-Content -LiteralPath (Join-Path $signinProfileDir "Local State") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal "" ([string]$localStateAfterClear.profile.info_cache.Default.user_name) "Limpeza deve apagar user_name do Edge"
    Assert-Equal "" ([string]$localStateAfterClear.profile.info_cache.Default.gaia_name) "Limpeza deve apagar gaia_name do Edge"
    Assert-True (-not [bool]$localStateAfterClear.profile.info_cache.Default.signin_required) "Limpeza deve remover exigencia de signin"
}
finally {
    if (Test-Path -LiteralPath $signinTestRoot) {
        Remove-Item -LiteralPath $signinTestRoot -Recurse -Force
    }
}

$brandingTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("EdgeProfileFactoryBrandingTest_{0}" -f ([Guid]::NewGuid().ToString("N")))
try {
    $sourceDir = Join-Path $brandingTestRoot "00-Administracao-Google"
    $targetDir = Join-Path $brandingTestRoot "20-Engenharia-Eletrica-Automacao"
    New-Item -ItemType Directory -Path (Join-Path $sourceDir "Default") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $targetDir "Default") -Force | Out-Null

    $sourcePreferences = [pscustomobject]@{
        bookmark_bar = [pscustomobject]@{ show_on_all_tabs = $true }
        browser = [pscustomobject]@{ show_home_button = $true; enable_spellchecking = $true }
        homepage = "https://example.com/"
        homepage_is_newtabpage = $false
        signin = [pscustomobject]@{ allowed = $true }
        account_info = @("nao-copiar")
        password_manager = [pscustomobject]@{ enabled = $true }
    }
    $sourcePreferences | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $sourceDir "Default\Preferences") -Encoding UTF8
    '{"roots":{"bookmark_bar":{"children":[]}}}' | Set-Content -LiteralPath (Join-Path $sourceDir "Default\Bookmarks") -Encoding UTF8

    $targetPreferences = [pscustomobject]@{
        browser = [pscustomobject]@{ show_home_button = $false }
    }
    $targetPreferences | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $targetDir "Default\Preferences") -Encoding UTF8

    $baselineResult = Copy-SafeEdgeBaselineConfig -SourceUserDataDir $sourceDir -TargetUserDataDir $targetDir
    Assert-True $baselineResult.Applied "Baseline seguro deve ser aplicado"

    $targetAfterBaseline = Get-Content -LiteralPath (Join-Path $targetDir "Default\Preferences") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([bool]$targetAfterBaseline.bookmark_bar.show_on_all_tabs) "Preferencia segura bookmark_bar deve ser copiada"
    Assert-True ([bool]$targetAfterBaseline.browser.show_home_button) "Preferencia segura browser.show_home_button deve ser copiada"
    Assert-True (-not ($targetAfterBaseline.PSObject.Properties.Name -contains "account_info")) "account_info nao deve ser copiado"
    Assert-True (-not ($targetAfterBaseline.PSObject.Properties.Name -contains "password_manager")) "password_manager nao deve ser copiado"
    Assert-True (-not ($targetAfterBaseline.PSObject.Properties.Name -contains "signin")) "signin nao deve ser copiado"
    Assert-True (Test-Path -LiteralPath (Join-Path $targetDir "Default\Bookmarks") -PathType Leaf) "Bookmarks devem ser copiados com backup seguro"

    Set-ProfileAccountConfiguration -Config $config -BaseDirectory $brandingTestRoot -Profile $engineeringProfile -BaselineSourceSlug "00-Administracao-Google" -ApplyBaseConfig
    $targetAfterBranding = Get-Content -LiteralPath (Join-Path $targetDir "Default\Preferences") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal ([string]$engineeringProfile.name) ([string]$targetAfterBranding.profile.name) "Nome interno do perfil deve ser aplicado"

    $metadataPath = Join-Path $targetDir ".edge-profile-factory\profile-metadata.json"
    Assert-True (Test-Path -LiteralPath $metadataPath -PathType Leaf) "Metadata de branding deve existir"
    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal "20" ([string]$metadata.code) "Metadata deve conter codigo do perfil"
    Assert-True (-not ($metadata.PSObject.Properties.Name -contains "password")) "Metadata nao deve conter campo password"
    Assert-True (-not ($metadata.PSObject.Properties.Name -contains "token")) "Metadata nao deve conter campo token"
    Assert-True (-not ($metadata.PSObject.Properties.Name -contains "cookie")) "Metadata nao deve conter campo cookie"
}
finally {
    if (Test-Path -LiteralPath $brandingTestRoot) {
        Remove-Item -LiteralPath $brandingTestRoot -Recurse -Force
    }
}

$channelRows = @(Read-ChannelMap -Path $channelMapPath)
Assert-True ($channelRows.Count -ge 50) "channel-map.csv deve ter conteudo util"
$channelErrors = @(Get-ChannelMapValidationErrors -Rows $channelRows -Config $config)
Assert-Equal 0 $channelErrors.Count "channel-map.csv deve ser valido"
$duplicates = @(Get-DuplicateChannelRows -Rows $channelRows)
Assert-True ($duplicates.Count -ge 4) "Deve detectar canais duplicados entre contas"

$securityStatus = Get-KasperskySecurityStatus
Assert-True ($null -ne $securityStatus) "Checagem segura do Kaspersky deve retornar status"
Assert-True ($securityStatus.PSObject.Properties.Name -contains "PasswordManagerRunning") "Status deve informar PasswordManagerRunning"
Assert-True ($securityStatus.PSObject.Properties.Name -contains "Processes") "Status deve informar Processes"

$nativeUserDataDir = Get-NativeEdgeUserDataDir
Assert-True (-not [string]::IsNullOrWhiteSpace($nativeUserDataDir)) "Diretorio nativo do Edge deve ser resolvido"
$nativeProfiles = @(Get-NativeEdgeProfiles)
Assert-True ($null -ne $nativeProfiles) "Inspecao de perfis nativos deve retornar uma lista"

$testReports = Join-Path ([System.IO.Path]::GetTempPath()) ("EdgeProfileFactoryReportsTest_{0}" -f ([Guid]::NewGuid().ToString("N")))
$reportResult = New-ChannelReports -ChannelMapPath $channelMapPath -ReportsDirectory $testReports -Config $config -BaseDirectory $baseDirectory
Assert-True $reportResult.Success "Geracao de relatorios deve ter sucesso"
Assert-True (Test-Path -LiteralPath $reportResult.DuplicateChannelsPath -PathType Leaf) "duplicate-channels.csv deve ser gerado"
Assert-True (Test-Path -LiteralPath $reportResult.MigrationPlanPath -PathType Leaf) "migration-plan.html deve ser gerado"
Assert-True (Test-Path -LiteralPath $reportResult.ProfileStatusPath -PathType Leaf) "profile-status.csv deve ser gerado"
Remove-Item -LiteralPath $testReports -Recurse -Force

Write-Host "Todos os testes passaram." -ForegroundColor Green
