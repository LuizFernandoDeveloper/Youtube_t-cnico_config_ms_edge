function New-BackupSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [string]$ExtensionPacksPath,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [Parameter(Mandatory = $true)]
        [string]$BackupDirectory,

        [string]$ProfileSlug
    )

    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    }

    $setDirectory = Join-Path $BackupDirectory (Get-Date -Format "yyyy-MM-dd_HHmmss")
    New-Item -ItemType Directory -Path $setDirectory -Force | Out-Null

    Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $setDirectory "profiles.json") -Force
    if ($ExtensionPacksPath -and (Test-Path -LiteralPath $ExtensionPacksPath -PathType Leaf)) {
        Copy-Item -LiteralPath $ExtensionPacksPath -Destination (Join-Path $setDirectory "extension-packs.json") -Force
    }

    if (Get-Command Export-EdgeShortcuts -ErrorAction SilentlyContinue) {
        Export-EdgeShortcuts -Config $Config -BaseDirectory $BaseDirectory -DestinationDirectory (Join-Path $setDirectory "shortcuts")
    }

    $profiles = @($Config.profiles)
    if ($ProfileSlug) {
        $profiles = @($profiles | Where-Object { [string]$_.slug -ieq $ProfileSlug })
        if ($profiles.Count -eq 0) {
            throw "Perfil nao encontrado para backup: $ProfileSlug"
        }
    }

    foreach ($profile in $profiles) {
        $profileDirectory = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $profile
        if (-not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Level "WARN" -Message "Perfil ignorado no backup; diretorio nao existe: $profileDirectory"
            }
            continue
        }

        if (Get-Command Test-EdgeUserDataDirInUse -ErrorAction SilentlyContinue) {
            if (Test-EdgeUserDataDirInUse -UserDataDir $profileDirectory) {
                throw "Feche o Edge deste perfil antes do backup: $($profile.slug)"
            }
        }

        $zipPath = Join-Path $setDirectory ("{0}.zip" -f $profile.slug)
        $children = @(Get-ChildItem -LiteralPath $profileDirectory -Force)

        if ($children.Count -eq 0) {
            $marker = Join-Path $profileDirectory ".empty-profile"
            New-Item -ItemType File -Path $marker -Force | Out-Null
            try {
                Compress-Archive -LiteralPath $marker -DestinationPath $zipPath -Force
            }
            finally {
                Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Compress-Archive -LiteralPath $children.FullName -DestinationPath $zipPath -Force
        }

        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Level "OK" -Message "Backup criado: $zipPath"
        }
    }

    return $setDirectory
}

function Restore-ProfileBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupPath,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [string]$ProfileSlug,

        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) {
        throw "Diretorio de backup nao encontrado: $BackupPath"
    }

    $zipFiles = @(Get-ChildItem -LiteralPath $BackupPath -Filter "*.zip" -File)
    if ($ProfileSlug) {
        $zipFiles = @($zipFiles | Where-Object { $_.BaseName -ieq $ProfileSlug })
    }

    if ($zipFiles.Count -eq 0) {
        throw "Nenhum backup .zip encontrado para restaurar."
    }

    if (-not $Force) {
        $confirmation = Read-Host "Digite RESTAURAR para restaurar $($zipFiles.Count) perfil(is)"
        if ($confirmation -cne "RESTAURAR") {
            throw "Operacao cancelada pelo usuario."
        }
    }

    foreach ($zip in $zipFiles) {
        $slug = $zip.BaseName
        $target = Join-Path $BaseDirectory $slug

        if (Get-Command Test-EdgeUserDataDirInUse -ErrorAction SilentlyContinue) {
            if (Test-EdgeUserDataDirInUse -UserDataDir $target) {
                throw "Feche o Edge deste perfil antes da restauracao: $slug"
            }
        }

        if (Test-Path -LiteralPath $target) {
            $existingBackup = "{0}.pre-restore-{1}" -f $target, (Get-Date -Format "yyyyMMddHHmmss")
            Move-Item -LiteralPath $target -Destination $existingBackup
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Level "OK" -Message "Diretorio existente preservado em: $existingBackup"
            }
        }

        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Expand-Archive -LiteralPath $zip.FullName -DestinationPath $target -Force

        $marker = Join-Path $target ".empty-profile"
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            Remove-Item -LiteralPath $marker -Force
        }

        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Level "OK" -Message "Perfil restaurado: $slug"
        }
    }
}

function Remove-EdgeProfileDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [string]$ExtensionPacksPath,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [Parameter(Mandatory = $true)]
        [string]$BackupDirectory,

        [Parameter(Mandatory = $true)]
        [string]$ProfileSlug,

        [switch]$Force
    )

    $profile = Get-ProfileBySlug -Config $Config -Slug $ProfileSlug
    if ($null -eq $profile) {
        throw "Perfil nao encontrado: $ProfileSlug"
    }

    $profileDirectory = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $profile
    if (-not (Test-PathInsideDirectory -Path $profileDirectory -Directory $BaseDirectory)) {
        throw "Remocao bloqueada; caminho fora do diretorio base: $profileDirectory"
    }

    if (-not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Level "WARN" -Message "Perfil ja nao existe: $ProfileSlug"
        }
        return
    }

    if (Get-Command Test-EdgeUserDataDirInUse -ErrorAction SilentlyContinue) {
        if (Test-EdgeUserDataDirInUse -UserDataDir $profileDirectory) {
            throw "Feche o Edge deste perfil antes de remover: $ProfileSlug"
        }
    }

    if (-not $Force) {
        $confirmation = Read-Host "Digite EXCLUIR para fazer backup e remover '$ProfileSlug'"
        if ($confirmation -cne "EXCLUIR") {
            throw "Operacao cancelada pelo usuario."
        }
    }

    New-BackupSet -Config $Config -ConfigPath $ConfigPath -ExtensionPacksPath $ExtensionPacksPath -BaseDirectory $BaseDirectory -BackupDirectory $BackupDirectory -ProfileSlug $ProfileSlug | Out-Null
    Remove-Item -LiteralPath $profileDirectory -Recurse -Force

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level "OK" -Message "Perfil removido: $ProfileSlug"
    }
}

Export-ModuleMember -Function New-BackupSet, Restore-ProfileBackup, Remove-EdgeProfileDirectory
