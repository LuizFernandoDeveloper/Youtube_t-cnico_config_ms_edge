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

    $edge = Find-EdgeExecutable -PromptIfMissing -NonInteractive:$NonInteractive

    if (Test-AnyEdgeRunning) {
        Write-Log -Level "WARN" -Message "Ha processos do Edge em execucao. O script nao altera perfis internos, mas backup/recriacao exigem fechar o perfil alvo."
    }

    if (-not (Test-Path -LiteralPath $BaseDirectory)) {
        New-Item -ItemType Directory -Path $BaseDirectory -Force | Out-Null
        Write-Log -Level "OK" -Message "Diretorio base criado: $BaseDirectory"
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

            if ($NonInteractive -or $Force) {
                Write-Log -Level "INFO" -Message "Modo nao interativo/force: mantendo diretorio e atualizando atalho de $($profile.slug)."
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
