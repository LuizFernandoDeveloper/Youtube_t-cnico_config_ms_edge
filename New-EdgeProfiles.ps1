[CmdletBinding()]
param(
    [string]$Config = ".\profiles.json",
    [string]$ExtensionPacks = ".\extension-packs.json",
    [string]$ChannelMap = "",

    [switch]$DryRun,
    [switch]$Create,
    [switch]$UpdateShortcuts,
    [switch]$Backup,
    [switch]$Restore,
    [switch]$Reports,
    [switch]$SecurityCheck,
    [string]$BackupPath,
    [string]$RemoveProfile,
    [switch]$OpenAll,

    [ValidateSet("Assisted", "Enterprise", "None")]
    [string]$ExtensionMode = "Assisted",

    [switch]$ApplyBaseConfig,
    [string]$BaseProfileSlug = "00-Administracao-Google",
    [switch]$FullAuto,

    [switch]$UndoExtensionPolicies,
    [switch]$CloseAfterInit,
    [switch]$SkipEdgeInitialization,
    [switch]$Force,
    [switch]$NonInteractive,
    [Alias("Auto", "Y")]
    [switch]$YesToAll
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleRoot = Join-Path $scriptRoot "Modules"

Import-Module (Join-Path $moduleRoot "Logger.psm1") -Force
Import-Module (Join-Path $moduleRoot "ProfileManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "EdgeDetection.psm1") -Force
Import-Module (Join-Path $moduleRoot "AccountBrandingManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "ShortcutManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "ExtensionManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "BackupManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "ChannelMapManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "SecurityAssistant.psm1") -Force

if ($FullAuto) {
    $YesToAll = $true
    $ApplyBaseConfig = $true
}

$script:AutoApprovedAll = [bool]$YesToAll

function Write-ValidationAndExit {
    param([string[]]$Errors)

    foreach ($errorMessage in $Errors) {
        Write-Log -Level "ERROR" -Message $errorMessage
    }

    throw "Corrija os erros de validacao antes de continuar."
}

function Get-ConfigBoolean {
    param(
        $Object,
        [string]$Name,
        [bool]$Default
    )

    if ($Object.PSObject.Properties.Name -contains $Name) {
        return [bool]$Object.$Name
    }

    return $Default
}

function Get-ProfileExtensionNames {
    param(
        $Profile,
        $ExtensionPacksObject
    )

    return @((Get-ProfileExtensionItems -Profile $Profile -ExtensionPacks $ExtensionPacksObject) | ForEach-Object { [string]$_.name })
}

function Read-ProfileExecutionPlan {
    param(
        $ConfigObject,
        $ExtensionPacksObject
    )

    $profiles = @(Get-ConfiguredProfiles -Config $ConfigObject)
    $status = @{}
    foreach ($profile in $profiles) {
        $status[[string]$profile.slug] = "Y"
    }

    if ($NonInteractive -or $YesToAll) {
        $script:AutoApprovedAll = $true
        return $status
    }

    while ($true) {
        Write-Host ""
        Write-Host ("-" * 96) -ForegroundColor DarkGray
        Write-Host "Plano de perfis do Edge" -ForegroundColor Cyan
        Write-Host "Observacao: estes ambientes aparecem pelos atalhos criados, nao no seletor interno do Edge padrao." -ForegroundColor Yellow
        Write-Host ("-" * 96) -ForegroundColor DarkGray
        foreach ($profile in $profiles) {
            $code = Get-ProfileCode -Profile $profile
            $extensionNames = @(Get-ProfileExtensionNames -Profile $profile -ExtensionPacksObject $ExtensionPacksObject)
            $brand = [string]$profile.defaultBrandAccount
            if ([string]::IsNullOrWhiteSpace($brand)) {
                $brand = "Sem canal padrao"
            }

            $line = "{0,2} [{1}] {2} | {3} | {4} ext. | {5}" -f
                $code,
                $status[[string]$profile.slug],
                $profile.name,
                $profile.googleAccountLabel,
                $extensionNames.Count,
                $brand

            $color = "White"
            if ($status[[string]$profile.slug] -eq "N") {
                $color = "DarkGray"
            }
            elseif ($status[[string]$profile.slug] -eq "B") {
                $color = "Red"
            }

            Write-Host $line -ForegroundColor $color
            Write-Host ("     Extensoes: {0}" -f ($extensionNames -join ", ")) -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "Enter executa Y | A tudo Y | Y 20 21 sim | N 30 pula | B 90 bloqueia | E 22 detalhes" -ForegroundColor Yellow
        $answer = Read-Host "Comando"

        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match "^[iI]$") {
            return $status
        }

        if ($answer -match "^[aAyY]$") {
            foreach ($profile in $profiles) {
                $status[[string]$profile.slug] = "Y"
            }
            $script:AutoApprovedAll = $true
            return $status
        }

        if ($answer -match "^[lL]$") {
            foreach ($profile in $profiles) {
                $status[[string]$profile.slug] = "N"
            }
            continue
        }

        $parts = @($answer -split "[,\s;]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($parts.Count -eq 0) {
            continue
        }

        $command = $parts[0].ToUpperInvariant()
        if ($command -eq "E") {
            foreach ($codeText in @($parts | Select-Object -Skip 1)) {
                $match = @($profiles | Where-Object { (Get-ProfileCode -Profile $_) -ieq $codeText -or [string]$_.slug -ieq $codeText }) | Select-Object -First 1
                if ($match) {
                    Write-Host ""
                    Write-Host ("{0} - {1}" -f (Get-ProfileCode -Profile $match), $match.name) -ForegroundColor Cyan
                    foreach ($extensionName in (Get-ProfileExtensionNames -Profile $match -ExtensionPacksObject $ExtensionPacksObject)) {
                        Write-Host (" - {0}" -f $extensionName)
                    }
                }
            }
            continue
        }

        if ($command -notin @("Y", "N", "B")) {
            Write-Host "Comando invalido. Use Y, N, B, A ou E." -ForegroundColor Yellow
            continue
        }

        $targets = @($parts | Select-Object -Skip 1)
        if ($targets.Count -eq 0) {
            foreach ($profile in $profiles) {
                $status[[string]$profile.slug] = $command
            }
            continue
        }

        foreach ($target in $targets) {
            $matches = @($profiles | Where-Object { (Get-ProfileCode -Profile $_) -ieq $target -or [string]$_.slug -ieq $target })
            foreach ($profile in $matches) {
                $status[[string]$profile.slug] = $command
            }
        }
    }
}

function Invoke-DryRun {
    param(
        $ConfigObject,
        [string]$BaseDirectory,
        [string]$ConfigPath,
        [string]$ExtensionPacksPath
    )

    Write-Log -Level "DRYRUN" -Message "Nenhuma alteracao sera realizada."

    $profiles = @(Get-ConfiguredProfiles -Config $ConfigObject)
    $allProfiles = @(Get-ConfiguredProfiles -Config $ConfigObject -IncludeInactive)
    $newProfiles = 0
    foreach ($profile in $profiles) {
        $profileDirectory = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $profile
        if (-not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
            $newProfiles++
        }
    }

    $shortcutPlan = @(Get-ShortcutPlan -Config $ConfigObject -BaseDirectory $BaseDirectory)
    $shortcutsToCreate = @($shortcutPlan | Where-Object { -not (Test-Path -LiteralPath $_.Path -PathType Leaf) }).Count
    $driveName = ([System.IO.Path]::GetPathRoot($BaseDirectory)).TrimEnd("\").TrimEnd(":")
    $spaceText = "indisponivel"
    $drive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    if ($drive) {
        $spaceText = "{0:N0} GB" -f ($drive.Free / 1GB)
    }

    $edgeStatus = "nao localizado"
    try {
        $edge = Find-EdgeExecutable -NonInteractive
        $edgeStatus = $edge.Path
    }
    catch {
        $edgeStatus = $_.Exception.Message
    }

    $configHash = Get-FileSha256 -Path $ConfigPath
    $packsHash = Get-FileSha256 -Path $ExtensionPacksPath

    Write-Host ""
    Write-Host "Perfis configurados: $($allProfiles.Count)"
    Write-Host "Perfis ativos: $($profiles.Count)"
    Write-Host "Perfis desativados: $($allProfiles.Count - $profiles.Count)"
    Write-Host "Perfis novos: $newProfiles"
    Write-Host "Diretorios a criar: $newProfiles"
    Write-Host "Atalhos a criar: $shortcutsToCreate"
    Write-Host "Conflitos encontrados: 0"
    Write-Host "Espaco disponivel: $spaceText"
    Write-Host "Edge: $edgeStatus"
    Write-Host "Hash profiles.json: $configHash"
    Write-Host "Hash extension-packs.json: $packsHash"
}

function Invoke-ProfileInitialization {
    param(
        [string]$EdgePath,
        $Profile,
        [string]$UserDataDir
    )

    if ($SkipEdgeInitialization) {
        Write-Log -Level "INFO" -Message "Inicializacao do Edge ignorada para $($Profile.name)."
        return
    }

    if (Test-EdgeUserDataDirInUse -UserDataDir $UserDataDir) {
        Write-Log -Level "WARN" -Message "Perfil ja esta aberto; inicializacao ignorada: $($Profile.name)"
        return
    }

    $urls = @(Get-StartupPages -Profile $Profile)
    Start-EdgeProfile -EdgePath $EdgePath -UserDataDir $UserDataDir -Urls $urls -NoFirstRun -NewWindow | Out-Null
    Wait-EdgeProfileInitialized -UserDataDir $UserDataDir -TimeoutSeconds 45 | Out-Null

    if ($CloseAfterInit) {
        Stop-EdgeProcessesForUserDataDir -UserDataDir $UserDataDir
    }
}

function Invoke-ManualBrandAccountCheck {
    param(
        [string]$EdgePath,
        $Profile,
        [string]$UserDataDir
    )

    $googleAccount = [string]$Profile.googleAccount
    $brandAccount = [string]$Profile.defaultBrandAccount

    if ([string]::IsNullOrWhiteSpace($googleAccount) -and [string]::IsNullOrWhiteSpace($brandAccount)) {
        return
    }

    if ($NonInteractive -or $YesToAll) {
        Write-Log -Level "INFO" -Message "Instrucao manual de conta/canal registrada para $($Profile.name): conta '$googleAccount', Brand Account '$brandAccount'."
        return
    }

    Write-Host ""
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    Write-Host ("Perfil criado: {0}" -f $Profile.name) -ForegroundColor Cyan
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    $kasperskyStatus = Get-KasperskySecurityStatus
    Write-KasperskyManualLoginGuidance -Status $kasperskyStatus
    Write-Host ""
    if (-not (Test-EdgeUserDataDirInUse -UserDataDir $UserDataDir)) {
        Start-EdgeProfile -EdgePath $EdgePath -UserDataDir $UserDataDir -Urls @("https://www.youtube.com/") -NoFirstRun -NewWindow | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($googleAccount)) {
        Write-Host "1. Entre manualmente na Conta Google:"
        Write-Host ("   {0}" -f $googleAccount) -ForegroundColor Yellow
    }
    else {
        Write-Host "1. Este perfil nao deve receber login geral."
    }

    Write-Host "2. Abra o YouTube."

    if (-not [string]::IsNullOrWhiteSpace($brandAccount)) {
        Write-Host "3. Selecione a Brand Account:"
        Write-Host ("   {0}" -f $brandAccount) -ForegroundColor Yellow
    }
    else {
        Write-Host "3. Mantenha sem canal padrao."
    }

    Write-Host "4. Feche o Edge."
    Write-Host "5. Pressione ENTER para testar a persistencia."
    Read-Host "Pronto" | Out-Null

    if (Test-EdgeUserDataDirInUse -UserDataDir $UserDataDir) {
        Write-Log -Level "WARN" -Message "O Edge ainda parece aberto para $($Profile.name); tentando fechar apenas esta instancia."
        Stop-EdgeProcessesForUserDataDir -UserDataDir $UserDataDir
    }

    Start-EdgeProfile -EdgePath $EdgePath -UserDataDir $UserDataDir -Urls @("https://www.youtube.com/") -NoFirstRun -NewWindow | Out-Null
    Write-Host ""
    Write-Host "O YouTube abriu na Brand Account correta?" -ForegroundColor Cyan
    Write-Host "[S] Sim"
    Write-Host "[N] Nao"
    $answer = Read-Host "Confirmacao"

    if ($answer -match "^[sSyY]") {
        Write-Log -Level "OK" -Message "Persistencia confirmada manualmente para $($Profile.name)."
    }
    else {
        Write-Log -Level "WARN" -Message "Persistencia nao confirmada para $($Profile.name). Revise login/Brand Account manualmente."
    }
}

function Test-EdgeProfileInitializedDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserDataDir
    )

    $localState = Join-Path $UserDataDir "Local State"
    $defaultDir = Join-Path $UserDataDir "Default"
    return (Test-Path -LiteralPath $localState -PathType Leaf) -or (Test-Path -LiteralPath $defaultDir -PathType Container)
}

function Get-ExistingFactoryArtifacts {
    param(
        $ConfigObject,
        [string]$BaseDirectory
    )

    $profileDirectories = New-Object System.Collections.Generic.List[object]
    foreach ($profile in (Get-ConfiguredProfiles -Config $ConfigObject)) {
        $profileDirectory = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $profile
        if (Test-Path -LiteralPath $profileDirectory -PathType Container) {
            $profileDirectories.Add([pscustomobject]@{
                Profile = $profile
                Path = $profileDirectory
            })
        }
    }

    $shortcuts = @(Get-ShortcutPlan -Config $ConfigObject -BaseDirectory $BaseDirectory | Where-Object {
            Test-Path -LiteralPath $_.Path -PathType Leaf
        })

    return [pscustomobject]@{
        ProfileDirectories = $profileDirectories.ToArray()
        Shortcuts = $shortcuts
        HasAny = (($profileDirectories.Count + $shortcuts.Count) -gt 0)
    }
}

function Read-RecoveryMode {
    param(
        $Artifacts
    )

    if (-not $Artifacts.HasAny) {
        return "Fresh"
    }

    if ($NonInteractive -or $Force -or $YesToAll) {
        Write-Log -Level "INFO" -Message "Artefatos existentes detectados; continuando automaticamente por -NonInteractive/-Force/-YesToAll."
        return "Continue"
    }

    Write-Host ""
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    Write-Host "Recuperacao de execucao anterior" -ForegroundColor Cyan
    Write-Host ("Diretorios de perfil encontrados: {0}" -f $Artifacts.ProfileDirectories.Count)
    Write-Host ("Atalhos encontrados: {0}" -f $Artifacts.Shortcuts.Count)
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    Write-Host "1. Continuar de onde parou"
    Write-Host "2. Apagar o que foi feito e sair"
    Write-Host "3. Refazer tudo (backup + apagar + criar de novo)"
    Write-Host "4. Decidir perfil por perfil"

    while ($true) {
        $choice = Read-Host "Escolha [1]"
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -match "^(1|c|C)$") {
            return "Continue"
        }
        if ($choice -match "^(2|a|A)$") {
            return "Remove"
        }
        if ($choice -match "^(3|r|R)$") {
            return "Recreate"
        }
        if ($choice -match "^(4|p|P)$") {
            return "PerProfile"
        }
        Write-Host "Opcao invalida." -ForegroundColor Yellow
    }
}

function Remove-ConfiguredProfileDirectories {
    param(
        $ConfigObject,
        [string]$BaseDirectory
    )

    foreach ($profile in (Get-ConfiguredProfiles -Config $ConfigObject)) {
        $profileDirectory = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $profile
        if (-not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
            continue
        }

        if (-not (Test-PathInsideDirectory -Path $profileDirectory -Directory $BaseDirectory)) {
            throw "Remocao bloqueada; caminho fora do diretorio base: $profileDirectory"
        }

        if (Test-EdgeUserDataDirInUse -UserDataDir $profileDirectory) {
            throw "Feche o Edge deste perfil antes de apagar/refazer: $($profile.slug)"
        }
    }

    foreach ($profile in (Get-ConfiguredProfiles -Config $ConfigObject)) {
        $profileDirectory = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $profile
        if (Test-Path -LiteralPath $profileDirectory -PathType Container) {
            Remove-Item -LiteralPath $profileDirectory -Recurse -Force
            Write-Log -Level "OK" -Message "Diretorio removido: $profileDirectory"
        }
    }
}

function Invoke-RecoveryAction {
    param(
        [string]$RecoveryMode,
        $ConfigObject,
        [string]$ConfigPath,
        [string]$ExtensionPacksPath,
        [string]$BaseDirectory,
        [string]$BackupDirectory
    )

    if ($RecoveryMode -notin @("Remove", "Recreate")) {
        return $false
    }

    $artifacts = Get-ExistingFactoryArtifacts -ConfigObject $ConfigObject -BaseDirectory $BaseDirectory
    if ($artifacts.ProfileDirectories.Count -gt 0) {
        Write-Log -Level "INFO" -Message "Criando backup antes de apagar/refazer perfis existentes."
        New-BackupSet -Config $ConfigObject -ConfigPath $ConfigPath -ExtensionPacksPath $ExtensionPacksPath -BaseDirectory $BaseDirectory -BackupDirectory $BackupDirectory | Out-Null
    }

    Remove-ConfiguredProfileDirectories -ConfigObject $ConfigObject -BaseDirectory $BaseDirectory
    Remove-EdgeProfileShortcuts -Config $ConfigObject -BaseDirectory $BaseDirectory

    if ($RecoveryMode -eq "Remove") {
        Write-Log -Level "OK" -Message "Artefatos removidos. Execucao encerrada por escolha do usuario."
        return $true
    }

    Write-Log -Level "OK" -Message "Ambiente limpo. Recriando perfis do zero."
    return $false
}

function Recreate-ProfileDirectory {
    param(
        $ConfigObject,
        [string]$ConfigPath,
        [string]$ExtensionPacksPath,
        [string]$BaseDirectory,
        [string]$BackupDirectory,
        $Profile
    )

    $profileDirectory = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $Profile

    if (Test-EdgeUserDataDirInUse -UserDataDir $profileDirectory) {
        throw "Feche o Edge deste perfil antes de recriar: $($Profile.slug)"
    }

    if (Test-Path -LiteralPath $profileDirectory -PathType Container) {
        New-BackupSet -Config $ConfigObject -ConfigPath $ConfigPath -ExtensionPacksPath $ExtensionPacksPath -BaseDirectory $BaseDirectory -BackupDirectory $BackupDirectory -ProfileSlug ([string]$Profile.slug) | Out-Null
        Remove-Item -LiteralPath $profileDirectory -Recurse -Force
        Write-Log -Level "OK" -Message "Diretorio antigo removido apos backup: $profileDirectory"
    }

    New-ProfileDirectory -Path $profileDirectory
}

function Invoke-CreateProfiles {
    param(
        $ConfigObject,
        $ExtensionPacksObject,
        [string]$ConfigPath,
        [string]$ExtensionPacksPath,
        [string]$BaseDirectory,
        [string]$BackupDirectory
    )

    if (-not (Test-Path -LiteralPath $BaseDirectory)) {
        New-Item -ItemType Directory -Path $BaseDirectory -Force | Out-Null
        Write-Log -Level "OK" -Message "Diretorio base criado: $BaseDirectory"
    }

    $artifacts = Get-ExistingFactoryArtifacts -ConfigObject $ConfigObject -BaseDirectory $BaseDirectory
    $recoveryMode = Read-RecoveryMode -Artifacts $artifacts
    $stopAfterRecovery = Invoke-RecoveryAction -RecoveryMode $recoveryMode -ConfigObject $ConfigObject -ConfigPath $ConfigPath -ExtensionPacksPath $ExtensionPacksPath -BaseDirectory $BaseDirectory -BackupDirectory $BackupDirectory
    if ($stopAfterRecovery) {
        return
    }

    $executionPlan = Read-ProfileExecutionPlan -ConfigObject $ConfigObject -ExtensionPacksObject $ExtensionPacksObject

    $edge = Find-EdgeExecutable -PromptIfMissing -NonInteractive:$NonInteractive

    if (Test-AnyEdgeRunning) {
        Write-Log -Level "WARN" -Message "Ha processos do Edge em execucao. O script nao altera perfis internos, mas backup/recriacao exigem fechar o perfil alvo."
    }

    Write-Log -Level "INFO" -Message "Hash do arquivo de configuracao: $(Get-FileSha256 -Path $ConfigPath)"

    if ($ExtensionMode -eq "Enterprise") {
        $policyBackupDir = Join-Path (Join-Path $BaseDirectory "Logs") "RegistryBackups"
        $policyStatePath = Join-Path (Join-Path $BaseDirectory "Logs") "enterprise-extension-policy-state.json"
        Set-EnterpriseExtensionPolicies -Profiles (Get-ConfiguredProfiles -Config $ConfigObject) -ExtensionPacks $ExtensionPacksObject -PolicyBackupDirectory $policyBackupDir -PolicyStatePath $policyStatePath -Force:$Force
    }

    foreach ($profile in (Get-ConfiguredProfiles -Config $ConfigObject)) {
        $plannedStatus = "Y"
        if ($executionPlan.ContainsKey([string]$profile.slug)) {
            $plannedStatus = $executionPlan[[string]$profile.slug]
        }

        if ($plannedStatus -eq "N") {
            Write-Log -Level "INFO" -Message "Perfil pulado pelo plano desta execucao: $($profile.slug)"
            continue
        }

        if ($plannedStatus -eq "B") {
            Write-Log -Level "WARN" -Message "Perfil bloqueado pelo plano desta execucao: $($profile.slug)"
            continue
        }

        $profileDirectory = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $profile
        $shouldInitialize = $false
        $shouldUpdateShortcut = $true
        $shouldInstallExtensions = ($ExtensionMode -eq "Assisted")

        if (Test-Path -LiteralPath $profileDirectory -PathType Container) {
            Write-Host ""
            Write-Host "[EXISTENTE] $($profile.name)" -ForegroundColor Yellow

            if ($recoveryMode -eq "Continue" -or $NonInteractive -or $Force -or $YesToAll) {
                Write-Log -Level "INFO" -Message "Continuando execucao: mantendo diretorio e atualizando atalho de $($profile.slug)."
                if (-not (Test-EdgeProfileInitializedDirectory -UserDataDir $profileDirectory)) {
                    Write-Log -Level "WARN" -Message "Diretorio existe, mas parece incompleto; inicializando novamente: $($profile.slug)"
                    $shouldInitialize = $true
                }
                $shouldInstallExtensions = ($ExtensionMode -eq "Assisted")
            }
            else {
                Write-Host "1. Manter"
                Write-Host "2. Atualizar atalho"
                Write-Host "3. Recriar"
                Write-Host "4. Fazer backup e recriar"
                Write-Host "5. Excluir"
                $choice = Read-Host "Escolha"

                switch ($choice) {
                    "1" {
                        $shouldUpdateShortcut = $false
                        $shouldInstallExtensions = $false
                        Write-Log -Level "INFO" -Message "Perfil mantido sem alteracoes: $($profile.slug)"
                    }
                    "2" {
                        Write-Log -Level "INFO" -Message "Atalho sera atualizado: $($profile.slug)"
                    }
                    "3" {
                        Recreate-ProfileDirectory -ConfigObject $ConfigObject -ConfigPath $ConfigPath -ExtensionPacksPath $ExtensionPacksPath -BaseDirectory $BaseDirectory -BackupDirectory $BackupDirectory -Profile $profile
                        $shouldInitialize = $true
                    }
                    "4" {
                        Recreate-ProfileDirectory -ConfigObject $ConfigObject -ConfigPath $ConfigPath -ExtensionPacksPath $ExtensionPacksPath -BaseDirectory $BaseDirectory -BackupDirectory $BackupDirectory -Profile $profile
                        $shouldInitialize = $true
                    }
                    "5" {
                        Remove-EdgeProfileDirectory -Config $ConfigObject -ConfigPath $ConfigPath -ExtensionPacksPath $ExtensionPacksPath -BaseDirectory $BaseDirectory -BackupDirectory $BackupDirectory -ProfileSlug ([string]$profile.slug)
                        $shouldUpdateShortcut = $false
                        $shouldInstallExtensions = $false
                    }
                    default {
                        $shouldUpdateShortcut = $false
                        $shouldInstallExtensions = $false
                        Write-Log -Level "WARN" -Message "Opcao invalida; perfil ignorado: $($profile.slug)"
                    }
                }
            }
        }
        else {
            Write-Host ""
            Write-Host "[CRIADO] $($profile.name)" -ForegroundColor Green
            New-ProfileDirectory -Path $profileDirectory
            $shouldInitialize = $true
        }

        if ($shouldUpdateShortcut) {
            New-EdgeProfileShortcuts -Config $ConfigObject -BaseDirectory $BaseDirectory -EdgePath $edge.Path -OnlySlug ([string]$profile.slug) | Out-Null
        }

        if ($shouldInitialize) {
            Invoke-ProfileInitialization -EdgePath $edge.Path -Profile $profile -UserDataDir $profileDirectory
        }

        if ($shouldUpdateShortcut -or $shouldInitialize -or $ApplyBaseConfig) {
            if (Test-EdgeUserDataDirInUse -UserDataDir $profileDirectory) {
                Stop-EdgeProcessesForUserDataDir -UserDataDir $profileDirectory
            }
            Set-ProfileAccountConfiguration -Config $ConfigObject -BaseDirectory $BaseDirectory -Profile $profile -BaselineSourceSlug $BaseProfileSlug -ApplyBaseConfig:$ApplyBaseConfig
        }

        if ($shouldInitialize) {
            Invoke-ManualBrandAccountCheck -EdgePath $edge.Path -Profile $profile -UserDataDir $profileDirectory
        }

        if ($shouldInstallExtensions) {
            Invoke-AssistedExtensionInstall -EdgePath $edge.Path -Profile $profile -UserDataDir $profileDirectory -ExtensionPacks $ExtensionPacksObject -NonInteractive:$NonInteractive -YesToAll:($YesToAll -or $script:AutoApprovedAll)
        }
    }
}

$configPath = Resolve-FactoryPath -Path $Config -BasePath (Get-Location).Path
$extensionPacksPath = Resolve-FactoryPath -Path $ExtensionPacks -BasePath (Get-Location).Path
$configObject = Read-JsonFile -Path $configPath
$extensionPacksObject = Read-JsonFile -Path $extensionPacksPath

$configDirectory = Split-Path -Parent $configPath
if ($configObject.PSObject.Properties.Name -contains "_configDirectory") {
    $configObject._configDirectory = $configDirectory
}
else {
    $configObject | Add-Member -MemberType NoteProperty -Name "_configDirectory" -Value $configDirectory
}

$baseDirectory = Resolve-FactoryPath -Path ([string]$configObject.baseDirectory) -BasePath $configDirectory
$backupDirectory = ".\Backups"
if ($configObject.PSObject.Properties.Name -contains "backupDirectory" -and -not [string]::IsNullOrWhiteSpace([string]$configObject.backupDirectory)) {
    $backupDirectory = [string]$configObject.backupDirectory
}
$backupDirectory = Resolve-FactoryPath -Path $backupDirectory -BasePath $configDirectory

$reportsDirectory = ".\Reports"
if ($configObject.PSObject.Properties.Name -contains "reportsDirectory" -and -not [string]::IsNullOrWhiteSpace([string]$configObject.reportsDirectory)) {
    $reportsDirectory = [string]$configObject.reportsDirectory
}
$reportsDirectory = Resolve-FactoryPath -Path $reportsDirectory -BasePath $configDirectory

if ([string]::IsNullOrWhiteSpace($ChannelMap)) {
    if ($configObject.PSObject.Properties.Name -contains "channelMap" -and -not [string]::IsNullOrWhiteSpace([string]$configObject.channelMap)) {
        $ChannelMap = [string]$configObject.channelMap
    }
    else {
        $ChannelMap = ".\channel-map.csv"
    }
}
$channelMapPath = Resolve-FactoryPath -Path $ChannelMap -BasePath $configDirectory

Assert-SafeBaseDirectory -BaseDirectory $baseDirectory

if (-not $DryRun) {
    $logDirectory = Join-Path $BaseDirectory "Logs"
    Initialize-Logger -LogDirectory $logDirectory
}

$extensionErrors = @(Test-ExtensionPacks -ExtensionPacks $extensionPacksObject)
if ($extensionErrors.Count -gt 0) {
    Write-ValidationAndExit -Errors $extensionErrors
}

$profileErrors = @(Test-ProfileConfig -Config $configObject -BaseDirectory $baseDirectory -ExtensionPackNames (Get-ExtensionPackNames -ExtensionPacks $extensionPacksObject))
if ($profileErrors.Count -gt 0) {
    Write-ValidationAndExit -Errors $profileErrors
}

if (Test-Path -LiteralPath $channelMapPath -PathType Leaf) {
    $channelRows = @(Read-ChannelMap -Path $channelMapPath)
    $channelErrors = @(Get-ChannelMapValidationErrors -Rows $channelRows -Config $configObject)
    if ($channelErrors.Count -gt 0) {
        Write-ValidationAndExit -Errors $channelErrors
    }
}

if ($SecurityCheck) {
    $securityStatus = Get-KasperskySecurityStatus
    Write-KasperskySecurityStatus -Status $securityStatus
    return
}

if ($DryRun) {
    Invoke-DryRun -ConfigObject $configObject -BaseDirectory $baseDirectory -ConfigPath $configPath -ExtensionPacksPath $extensionPacksPath
    return
}

if ($Reports) {
    $reportResult = New-ChannelReports -ChannelMapPath $channelMapPath -ReportsDirectory $reportsDirectory -Config $configObject -BaseDirectory $baseDirectory
    if (-not $reportResult.Success) {
        Write-ValidationAndExit -Errors $reportResult.Errors
    }
    Write-ChannelDuplicateSummary -DuplicateChannelsPath $reportResult.DuplicateChannelsPath
    return
}

if ($UndoExtensionPolicies) {
    $policyBackupDir = Join-Path (Join-Path $baseDirectory "Logs") "RegistryBackups"
    $policyStatePath = Join-Path (Join-Path $baseDirectory "Logs") "enterprise-extension-policy-state.json"
    Undo-EnterpriseExtensionPolicies -PolicyBackupDirectory $policyBackupDir -PolicyStatePath $policyStatePath -Force:$Force
    return
}

if ($Backup) {
    New-BackupSet -Config $configObject -ConfigPath $configPath -ExtensionPacksPath $extensionPacksPath -BaseDirectory $baseDirectory -BackupDirectory $backupDirectory | Out-Null
    return
}

if ($Restore) {
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw "Use -Restore com -BackupPath apontando para o diretorio do backup."
    }

    $resolvedBackupPath = Resolve-FactoryPath -Path $BackupPath -BasePath (Get-Location).Path
    Restore-ProfileBackup -BackupPath $resolvedBackupPath -BaseDirectory $baseDirectory -Force:$Force
    return
}

if ($RemoveProfile) {
    Remove-EdgeProfileDirectory -Config $configObject -ConfigPath $configPath -ExtensionPacksPath $extensionPacksPath -BaseDirectory $baseDirectory -BackupDirectory $backupDirectory -ProfileSlug $RemoveProfile -Force:$Force
    return
}

if ($UpdateShortcuts) {
    $edge = Find-EdgeExecutable -PromptIfMissing -NonInteractive:$NonInteractive
    New-EdgeProfileShortcuts -Config $configObject -BaseDirectory $baseDirectory -EdgePath $edge.Path | Out-Null
    return
}

if ($OpenAll) {
    $edge = Find-EdgeExecutable -PromptIfMissing -NonInteractive:$NonInteractive
    foreach ($profile in (Get-ConfiguredProfiles -Config $configObject)) {
        $profileDirectory = Get-ProfileDirectory -BaseDirectory $baseDirectory -Profile $profile
        if (-not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
            Write-Log -Level "WARN" -Message "Perfil ainda nao existe; ignorando OpenAll: $($profile.slug)"
            continue
        }
        Start-EdgeProfile -EdgePath $edge.Path -UserDataDir $profileDirectory -Urls (Get-StartupPages -Profile $profile) -NoFirstRun -NewWindow | Out-Null
    }
    return
}

if (-not $Create) {
    $Create = $true
}

if ($Create) {
    Invoke-CreateProfiles -ConfigObject $configObject -ExtensionPacksObject $extensionPacksObject -ConfigPath $configPath -ExtensionPacksPath $extensionPacksPath -BaseDirectory $baseDirectory -BackupDirectory $backupDirectory
}
