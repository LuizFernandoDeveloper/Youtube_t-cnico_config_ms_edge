function Get-ExtensionPackNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ExtensionPacks
    )

    if (-not ($ExtensionPacks.PSObject.Properties.Name -contains "packs")) {
        return @()
    }

    return @($ExtensionPacks.packs.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-ExtensionPack {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ExtensionPacks,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $ExtensionPacks.packs.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Test-ExtensionPacks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ExtensionPacks
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $packNames = Get-ExtensionPackNames -ExtensionPacks $ExtensionPacks

    if ($packNames.Count -eq 0) {
        $errors.Add("Nenhum pacote de extensoes foi definido.")
    }

    foreach ($packName in $packNames) {
        $pack = Get-ExtensionPack -ExtensionPacks $ExtensionPacks -Name $packName
        if (-not ($pack.PSObject.Properties.Name -contains "extensions") -or $null -eq $pack.extensions) {
            $errors.Add("Pacote sem extensoes: $packName")
            continue
        }

        foreach ($extension in @($pack.extensions)) {
            if ([string]::IsNullOrWhiteSpace([string]$extension.name)) {
                $errors.Add("Extensao sem nome no pacote: $packName")
            }

            if ([string]::IsNullOrWhiteSpace([string]$extension.url) -or -not (Test-AbsoluteHttpUrl -Url ([string]$extension.url))) {
                $errors.Add("URL invalida para extensao '$($extension.name)' no pacote '$packName': $($extension.url)")
            }
        }
    }

    $vaultPack = Get-ExtensionPack -ExtensionPacks $ExtensionPacks -Name "cofre"
    if ($vaultPack) {
        $vaultNames = @($vaultPack.extensions | ForEach-Object { [string]$_.name })
        if ($vaultNames.Count -ne 1 -or $vaultNames[0] -notmatch "Kaspersky Password Manager") {
            $errors.Add("O pacote 'cofre' deve conter somente Kaspersky Password Manager.")
        }
    }

    return $errors.ToArray()
}

function Get-ProfileExtensionItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Profile,

        [Parameter(Mandatory = $true)]
        $ExtensionPacks
    )

    $pack = Get-ExtensionPack -ExtensionPacks $ExtensionPacks -Name ([string]$Profile.extensionPack)
    if ($null -eq $pack) {
        return @()
    }

    return @($pack.extensions)
}

function Invoke-AssistedExtensionInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EdgePath,

        [Parameter(Mandatory = $true)]
        $Profile,

        [Parameter(Mandatory = $true)]
        [string]$UserDataDir,

        [Parameter(Mandatory = $true)]
        $ExtensionPacks,

        [switch]$NonInteractive
    )

    $items = @(Get-ProfileExtensionItems -Profile $Profile -ExtensionPacks $ExtensionPacks)
    if ($items.Count -eq 0) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Level "WARN" -Message "Nenhuma extensao encontrada para $($Profile.name)."
        }
        return
    }

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level "WARN" -Message "Extensoes do perfil '$($Profile.name)' aguardam instalacao manual assistida."
    }

    if ($NonInteractive) {
        Write-Host ""
        Write-Host "Extensoes recomendadas para $($Profile.name):" -ForegroundColor Cyan
        Write-Host "Modo nao interativo: paginas de extensoes nao serao abertas."
        foreach ($item in $items) {
            Write-Host ("   {0}: {1}" -f $item.name, $item.url)
        }
        return
    }

    $selected = New-Object bool[] $items.Count
    for ($index = 0; $index -lt $items.Count; $index++) {
        $selected[$index] = $true
    }

    while ($true) {
        Write-Host ""
        Write-Host ("-" * 72) -ForegroundColor DarkGray
        Write-Host "Extensoes assistidas" -ForegroundColor Cyan
        Write-Host ("Perfil: {0}" -f $Profile.name)
        Write-Host ("Pacote: {0}" -f $Profile.extensionPack) -ForegroundColor DarkGray
        Write-Host ("-" * 72) -ForegroundColor DarkGray
        for ($index = 0; $index -lt $items.Count; $index++) {
            $mark = "[ ]"
            $color = "DarkGray"
            if ($selected[$index]) {
                $mark = "[x]"
                $color = "White"
            }

            Write-Host (" {0,2}. {1} {2}" -f ($index + 1), $mark, $items[$index].name) -ForegroundColor $color
        }

        Write-Host ""
        Write-Host "Enter abre selecionadas | A aprova todas | 1 3 alterna itens | L limpa | T marca | P/N pula" -ForegroundColor Yellow
        $answer = Read-Host "Comando"

        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match "^[iI]$") {
            break
        }

        if ($answer -match "^[aA]$") {
            for ($index = 0; $index -lt $items.Count; $index++) {
                $selected[$index] = $true
            }
            break
        }

        if ($answer -match "^[tT]$") {
            for ($index = 0; $index -lt $items.Count; $index++) {
                $selected[$index] = $true
            }
            continue
        }

        if ($answer -match "^[lL]$") {
            for ($index = 0; $index -lt $items.Count; $index++) {
                $selected[$index] = $false
            }
            continue
        }

        if ($answer -match "^[pPqQnN]$") {
            Write-Log -Level "INFO" -Message "Instalacao assistida de extensoes ignorada para $($Profile.name)."
            return
        }

        $numbers = @($answer -split "[,\s;]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $changed = $false
        foreach ($numberText in $numbers) {
            $number = 0
            if ([int]::TryParse($numberText, [ref]$number) -and $number -ge 1 -and $number -le $items.Count) {
                $selected[$number - 1] = -not $selected[$number - 1]
                $changed = $true
            }
        }

        if (-not $changed) {
            Write-Host "Comando invalido." -ForegroundColor Yellow
        }
    }

    $urls = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $items.Count; $index++) {
        if ($selected[$index]) {
            $urls.Add([string]$items[$index].url)
        }
    }

    if ($urls.Count -eq 0) {
        Write-Log -Level "INFO" -Message "Nenhuma extensao selecionada para $($Profile.name)."
        return
    }

    Start-EdgeProfile -EdgePath $EdgePath -UserDataDir $UserDataDir -Urls $urls.ToArray() -NoFirstRun -NewWindow | Out-Null
    Write-Log -Level "WARN" -Message "Instale manualmente as extensoes abertas para $($Profile.name)."
    Read-Host "Quando terminar este perfil, pressione Enter para continuar" | Out-Null
}

function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-EnterpriseExtensionCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Profiles,

        [Parameter(Mandatory = $true)]
        $ExtensionPacks
    )

    $byId = @{}
    foreach ($profile in @($Profiles)) {
        foreach ($item in (Get-ProfileExtensionItems -Profile $profile -ExtensionPacks $ExtensionPacks)) {
            $id = [string]$item.id
            $updateUrl = [string]$item.updateUrl
            if (-not [string]::IsNullOrWhiteSpace($id) -and -not [string]::IsNullOrWhiteSpace($updateUrl)) {
                $key = $id.ToLowerInvariant()
                if (-not $byId.ContainsKey($key)) {
                    $byId[$key] = [pscustomobject]@{
                        Name = [string]$item.name
                        Id = $id
                        UpdateUrl = $updateUrl
                    }
                }
            }
        }
    }

    return @($byId.Values)
}

function Backup-EdgePolicyRegistryKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }

    $backupFile = Join-Path $DestinationDirectory ("EdgePolicies_{0}.reg" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $regPath = "HKLM\SOFTWARE\Policies\Microsoft\Edge"
    $result = & reg.exe export $regPath $backupFile /y 2>$null
    if ($LASTEXITCODE -ne 0) {
        "Chave inexistente antes da alteracao: $regPath" | Set-Content -LiteralPath $backupFile -Encoding UTF8
    }

    return $backupFile
}

function Set-EnterpriseExtensionPolicies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Profiles,

        [Parameter(Mandatory = $true)]
        $ExtensionPacks,

        [Parameter(Mandatory = $true)]
        [string]$PolicyBackupDirectory,

        [Parameter(Mandatory = $true)]
        [string]$PolicyStatePath,

        [switch]$Force
    )

    if (-not (Test-IsAdministrator)) {
        throw "Modo empresarial exige PowerShell como Administrador."
    }

    $items = @(Get-EnterpriseExtensionCandidates -Profiles $Profiles -ExtensionPacks $ExtensionPacks)
    if ($items.Count -eq 0) {
        throw "Nenhuma extensao possui id/updateUrl em extension-packs.json. Preencha esses campos antes de usar o modo empresarial."
    }

    Write-Host ""
    Write-Host "ATENCAO: o modo empresarial cria politicas no Registro e o Edge pode exibir 'Gerenciado pela sua organizacao'." -ForegroundColor Yellow
    Write-Host "Extensoes que serao forçadas: $($items.Count)" -ForegroundColor Yellow

    if (-not $Force) {
        $confirmation = Read-Host "Digite APLICAR para continuar"
        if ($confirmation -cne "APLICAR") {
            throw "Operacao cancelada pelo usuario."
        }
    }

    $backupFile = Backup-EdgePolicyRegistryKey -DestinationDirectory $PolicyBackupDirectory
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level "OK" -Message "Backup das politicas do Edge criado: $backupFile"
    }

    $keyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist"
    if (-not (Test-Path -LiteralPath $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }

    $existing = Get-ItemProperty -LiteralPath $keyPath -ErrorAction SilentlyContinue
    $usedNumbers = New-Object System.Collections.Generic.List[int]
    if ($existing) {
        foreach ($property in $existing.PSObject.Properties) {
            if ($property.Name -match "^\d+$") {
                $usedNumbers.Add([int]$property.Name)
            }
        }
    }

    $next = 1
    if ($usedNumbers.Count -gt 0) {
        $next = (($usedNumbers | Measure-Object -Maximum).Maximum + 1)
    }

    $state = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        $valueName = [string]$next
        $valueData = "{0};{1}" -f $item.Id, $item.UpdateUrl
        New-ItemProperty -LiteralPath $keyPath -Name $valueName -Value $valueData -PropertyType String -Force | Out-Null
        $state.Add([pscustomobject]@{
            ValueName = $valueName
            ValueData = $valueData
            ExtensionName = $item.Name
            CreatedAt = (Get-Date).ToString("s")
        })
        $next++
    }

    $stateDirectory = Split-Path -Parent $PolicyStatePath
    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $PolicyStatePath -Encoding UTF8

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level "OK" -Message "Politicas empresariais de extensoes aplicadas."
    }
}

function Undo-EnterpriseExtensionPolicies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyBackupDirectory,

        [Parameter(Mandatory = $true)]
        [string]$PolicyStatePath,

        [switch]$Force
    )

    if (-not (Test-IsAdministrator)) {
        throw "Desfazer politicas exige PowerShell como Administrador."
    }

    if (-not (Test-Path -LiteralPath $PolicyStatePath -PathType Leaf)) {
        throw "Arquivo de estado das politicas nao encontrado: $PolicyStatePath"
    }

    if (-not $Force) {
        $confirmation = Read-Host "Digite DESFAZER para remover as politicas criadas por este script"
        if ($confirmation -cne "DESFAZER") {
            throw "Operacao cancelada pelo usuario."
        }
    }

    $backupFile = Backup-EdgePolicyRegistryKey -DestinationDirectory $PolicyBackupDirectory
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level "OK" -Message "Backup das politicas atuais criado: $backupFile"
    }

    $state = Get-Content -LiteralPath $PolicyStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $keyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist"
    foreach ($entry in @($state)) {
        if (Test-Path -LiteralPath $keyPath) {
            Remove-ItemProperty -LiteralPath $keyPath -Name ([string]$entry.ValueName) -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -LiteralPath $PolicyStatePath -Force

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level "OK" -Message "Politicas empresariais criadas por este script foram removidas."
    }
}

Export-ModuleMember -Function Get-ExtensionPackNames, Get-ExtensionPack, Test-ExtensionPacks, Get-ProfileExtensionItems, Invoke-AssistedExtensionInstall, Test-IsAdministrator, Set-EnterpriseExtensionPolicies, Undo-EnterpriseExtensionPolicies
