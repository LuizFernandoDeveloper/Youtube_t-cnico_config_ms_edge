[CmdletBinding()]
param(
    [string]$Config = ".\profiles.json",
    [string]$ExtensionPacks = ".\extension-packs.json",

    [switch]$DryRun,
    [switch]$Create,
    [switch]$UpdateShortcuts,
    [switch]$Backup,
    [switch]$Restore,
    [string]$BackupPath,
    [string]$RemoveProfile,
    [switch]$OpenAll,

    [ValidateSet("Assisted", "Enterprise", "None")]
    [string]$ExtensionMode = "Assisted",

    [switch]$UndoExtensionPolicies,
    [switch]$CloseAfterInit,
    [switch]$SkipEdgeInitialization,
    [switch]$Force,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleRoot = Join-Path $scriptRoot "Modules"

Import-Module (Join-Path $moduleRoot "Logger.psm1") -Force
Import-Module (Join-Path $moduleRoot "ProfileManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "EdgeDetection.psm1") -Force
Import-Module (Join-Path $moduleRoot "ShortcutManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "ExtensionManager.psm1") -Force
Import-Module (Join-Path $moduleRoot "BackupManager.psm1") -Force

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

function Invoke-DryRun {
    param(
        $ConfigObject,
        [string]$BaseDirectory,
        [string]$ConfigPath,
        [string]$ExtensionPacksPath
    )

    Write-Log -Level "DRYRUN" -Message "Nenhuma alteracao sera realizada."

    $profiles = @($ConfigObject.profiles)
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
    Write-Host "Perfis configurados: $($profiles.Count)"
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
    foreach ($profile in @($ConfigObject.profiles)) {
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

    if ($NonInteractive -or $Force) {
        Write-Log -Level "INFO" -Message "Artefatos existentes detectados; continuando automaticamente por -NonInteractive/-Force."
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

    foreach ($profile in @($ConfigObject.profiles)) {
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

    foreach ($profile in @($ConfigObject.profiles)) {
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

    $edge = Find-EdgeExecutable -PromptIfMissing -NonInteractive:$NonInteractive

    if (Test-AnyEdgeRunning) {
        Write-Log -Level "WARN" -Message "Ha processos do Edge em execucao. O script nao altera perfis internos, mas backup/recriacao exigem fechar o perfil alvo."
    }

    Write-Log -Level "INFO" -Message "Hash do arquivo de configuracao: $(Get-FileSha256 -Path $ConfigPath)"

    if ($ExtensionMode -eq "Enterprise") {
        $policyBackupDir = Join-Path (Join-Path $BaseDirectory "Logs") "RegistryBackups"
        $policyStatePath = Join-Path (Join-Path $BaseDirectory "Logs") "enterprise-extension-policy-state.json"
        Set-EnterpriseExtensionPolicies -Profiles @($ConfigObject.profiles) -ExtensionPacks $ExtensionPacksObject -PolicyBackupDirectory $policyBackupDir -PolicyStatePath $policyStatePath -Force:$Force
    }

    foreach ($profile in @($ConfigObject.profiles)) {
        $profileDirectory = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $profile
        $shouldInitialize = $false
        $shouldUpdateShortcut = $true
        $shouldInstallExtensions = ($ExtensionMode -eq "Assisted")

        if (Test-Path -LiteralPath $profileDirectory -PathType Container) {
            Write-Host ""
            Write-Host "[EXISTENTE] $($profile.name)" -ForegroundColor Yellow

            if ($recoveryMode -eq "Continue" -or $NonInteractive -or $Force) {
                Write-Log -Level "INFO" -Message "Continuando execucao: mantendo diretorio e atualizando atalho de $($profile.slug)."
                if (-not (Test-EdgeProfileInitializedDirectory -UserDataDir $profileDirectory)) {
                    Write-Log -Level "WARN" -Message "Diretorio existe, mas parece incompleto; inicializando novamente: $($profile.slug)"
                    $shouldInitialize = $true
                }
                $shouldInstallExtensions = $shouldInitialize -and ($ExtensionMode -eq "Assisted")
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

        if ($shouldInstallExtensions) {
            Invoke-AssistedExtensionInstall -EdgePath $edge.Path -Profile $profile -UserDataDir $profileDirectory -ExtensionPacks $ExtensionPacksObject -NonInteractive:$NonInteractive
        }
    }
}

$configPath = Resolve-FactoryPath -Path $Config -BasePath (Get-Location).Path
$extensionPacksPath = Resolve-FactoryPath -Path $ExtensionPacks -BasePath (Get-Location).Path
$configObject = Read-JsonFile -Path $configPath
$extensionPacksObject = Read-JsonFile -Path $extensionPacksPath

$configDirectory = Split-Path -Parent $configPath
$baseDirectory = Resolve-FactoryPath -Path ([string]$configObject.baseDirectory) -BasePath $configDirectory
$backupDirectory = ".\Backups"
if ($configObject.PSObject.Properties.Name -contains "backupDirectory" -and -not [string]::IsNullOrWhiteSpace([string]$configObject.backupDirectory)) {
    $backupDirectory = [string]$configObject.backupDirectory
}
$backupDirectory = Resolve-FactoryPath -Path $backupDirectory -BasePath $configDirectory

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

if ($DryRun) {
    Invoke-DryRun -ConfigObject $configObject -BaseDirectory $baseDirectory -ConfigPath $configPath -ExtensionPacksPath $extensionPacksPath
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
    foreach ($profile in @($configObject.profiles)) {
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
