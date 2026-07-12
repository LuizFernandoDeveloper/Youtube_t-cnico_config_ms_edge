function Read-ChannelMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Mapa de canais nao encontrado: $Path"
    }

    $rows = @(Import-Csv -LiteralPath $Path -Encoding UTF8)
    $requiredColumns = @("ContaAtual", "CanalAtual", "PerfilDestino", "Acao", "NovoNome")
    foreach ($column in $requiredColumns) {
        if ($rows.Count -gt 0 -and -not ($rows[0].PSObject.Properties.Name -contains $column)) {
            throw "channel-map.csv precisa conter a coluna '$column'."
        }
    }

    return $rows
}

function Get-ProfileLookupByCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $lookup = @{}
    foreach ($profile in (Get-ConfiguredProfiles -Config $Config -IncludeInactive)) {
        $code = Get-ProfileCode -Profile $profile
        $lookup[$code] = $profile
    }

    return $lookup
}

function Get-ChannelMapValidationErrors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,

        [Parameter(Mandatory = $true)]
        $Config
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $lookup = Get-ProfileLookupByCode -Config $Config
    $validActions = @("Manter", "Renomear", "Consolidar", "Duplicado", "Arquivar", "Ignorar")

    foreach ($row in $Rows) {
        if ([string]::IsNullOrWhiteSpace([string]$row.ContaAtual)) {
            $errors.Add("Linha do channel-map.csv sem ContaAtual.")
        }
        elseif ([string]$row.ContaAtual -notmatch "^[^@\s]+@[^@\s]+\.[^@\s]+$") {
            $errors.Add("ContaAtual invalida no channel-map.csv: $($row.ContaAtual)")
        }

        if ([string]::IsNullOrWhiteSpace([string]$row.CanalAtual)) {
            $errors.Add("Linha do channel-map.csv sem CanalAtual.")
        }

        if ([string]::IsNullOrWhiteSpace([string]$row.PerfilDestino)) {
            $errors.Add("Linha do channel-map.csv sem PerfilDestino para '$($row.CanalAtual)'.")
        }
        elseif (-not $lookup.ContainsKey([string]$row.PerfilDestino)) {
            $errors.Add("PerfilDestino '$($row.PerfilDestino)' nao existe para '$($row.CanalAtual)'.")
        }

        if (-not ($validActions -contains [string]$row.Acao)) {
            $errors.Add("Acao invalida para '$($row.CanalAtual)': $($row.Acao)")
        }
    }

    return $errors.ToArray()
}

function Get-DuplicateChannelRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows
    )

    $groups = $Rows |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.CanalAtual) } |
        Group-Object { ([string]$_.CanalAtual).Trim().ToLowerInvariant() } |
        Where-Object {
            @($_.Group | Select-Object -ExpandProperty ContaAtual -Unique).Count -gt 1
        }

    foreach ($group in $groups) {
        $items = @($group.Group)
        [pscustomobject]@{
            CanalAtual = [string]$items[0].CanalAtual
            Contas = (@($items | Select-Object -ExpandProperty ContaAtual -Unique) -join " | ")
            PerfisDestino = (@($items | Select-Object -ExpandProperty PerfilDestino -Unique) -join " | ")
            Acoes = (@($items | Select-Object -ExpandProperty Acao -Unique) -join " | ")
            Opcoes = "MANTER | RENOMEAR | CONSOLIDAR MANUALMENTE | ARQUIVAR | IGNORAR"
        }
    }
}

function ConvertTo-HtmlText {
    param([string]$Value)

    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function New-MigrationPlanHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,

        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $lookup = Get-ProfileLookupByCode -Config $Config
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("<!doctype html>")
    $lines.Add("<html lang=""pt-BR"">")
    $lines.Add("<head>")
    $lines.Add("<meta charset=""utf-8"">")
    $lines.Add("<title>Plano de migracao de canais</title>")
    $lines.Add("<style>body{font-family:Segoe UI,Arial,sans-serif;margin:32px;color:#1f2937}table{border-collapse:collapse;width:100%}th,td{border:1px solid #d1d5db;padding:8px;text-align:left}th{background:#f3f4f6}.Duplicado{background:#fff7ed}.Renomear{background:#eff6ff}.Consolidar{background:#fefce8}.Arquivar{background:#fef2f2}.Ignorar{background:#f9fafb}</style>")
    $lines.Add("</head>")
    $lines.Add("<body>")
    $lines.Add("<h1>Plano de migracao de canais</h1>")
    $generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $lines.Add("<p>Gerado em $generatedAt. Este relatorio nao altera canais nem perfis.</p>")
    $lines.Add("<table>")
    $lines.Add("<tr><th>Conta atual</th><th>Canal atual</th><th>Perfil destino</th><th>Acao</th><th>Novo nome</th></tr>")

    foreach ($row in $Rows) {
        $profileName = [string]$row.PerfilDestino
        if ($lookup.ContainsKey([string]$row.PerfilDestino)) {
            $profile = $lookup[[string]$row.PerfilDestino]
            $profileName = "{0} - {1}" -f (Get-ProfileCode -Profile $profile), $profile.name
        }

        $class = ConvertTo-HtmlText ([string]$row.Acao)
        $lines.Add(("<tr class=""{0}""><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>" -f
                $class,
                (ConvertTo-HtmlText ([string]$row.ContaAtual)),
                (ConvertTo-HtmlText ([string]$row.CanalAtual)),
                (ConvertTo-HtmlText $profileName),
                (ConvertTo-HtmlText ([string]$row.Acao)),
                (ConvertTo-HtmlText ([string]$row.NovoNome))))
    }

    $lines.Add("</table>")
    $lines.Add("</body>")
    $lines.Add("</html>")
    $lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-ProfileStatusReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rows = foreach ($profile in (Get-ConfiguredProfiles -Config $Config -IncludeInactive)) {
        $directory = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $profile
        $initialized = $false
        if (Test-Path -LiteralPath $directory -PathType Container) {
            $initialized = (Test-Path -LiteralPath (Join-Path $directory "Local State") -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $directory "Default") -PathType Container)
        }

        [pscustomobject]@{
            Codigo = Get-ProfileCode -Profile $profile
            Nome = [string]$profile.name
            Slug = [string]$profile.slug
            Ativo = Test-ProfileEnabled -Profile $profile
            ContaGoogle = [string]$profile.googleAccount
            ContaRotulo = [string]$profile.googleAccountLabel
            BrandAccountPadrao = [string]$profile.defaultBrandAccount
            PacoteExtensoes = [string]$profile.extensionPack
            DiretorioExiste = (Test-Path -LiteralPath $directory -PathType Container)
            Inicializado = $initialized
            Diretorio = $directory
        }
    }

    $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function New-ChannelReports {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChannelMapPath,

        [Parameter(Mandatory = $true)]
        [string]$ReportsDirectory,

        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    if (-not (Test-Path -LiteralPath $ReportsDirectory)) {
        New-Item -ItemType Directory -Path $ReportsDirectory -Force | Out-Null
    }

    $rows = @(Read-ChannelMap -Path $ChannelMapPath)
    $errors = @(Get-ChannelMapValidationErrors -Rows $rows -Config $Config)
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            Success = $false
            Errors = $errors
            DuplicateCount = 0
            ReportsDirectory = $ReportsDirectory
        }
    }

    $duplicates = @(Get-DuplicateChannelRows -Rows $rows)
    $duplicatePath = Join-Path $ReportsDirectory "duplicate-channels.csv"
    $migrationPath = Join-Path $ReportsDirectory "migration-plan.html"
    $statusPath = Join-Path $ReportsDirectory "profile-status.csv"

    $duplicates | Export-Csv -LiteralPath $duplicatePath -NoTypeInformation -Encoding UTF8
    New-MigrationPlanHtml -Rows $rows -Config $Config -Path $migrationPath
    New-ProfileStatusReport -Config $Config -BaseDirectory $BaseDirectory -Path $statusPath

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level "OK" -Message "Relatorios gerados em: $ReportsDirectory"
    }

    return [pscustomobject]@{
        Success = $true
        Errors = @()
        DuplicateCount = $duplicates.Count
        ReportsDirectory = $ReportsDirectory
        DuplicateChannelsPath = $duplicatePath
        MigrationPlanPath = $migrationPath
        ProfileStatusPath = $statusPath
    }
}

function Write-ChannelDuplicateSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DuplicateChannelsPath
    )

    if (-not (Test-Path -LiteralPath $DuplicateChannelsPath -PathType Leaf)) {
        return
    }

    $duplicates = @(Import-Csv -LiteralPath $DuplicateChannelsPath -Encoding UTF8)
    foreach ($duplicate in $duplicates) {
        Write-Host ("[DUPLICADO] {0}" -f $duplicate.CanalAtual) -ForegroundColor Yellow
        foreach ($account in ([string]$duplicate.Contas -split "\s*\|\s*")) {
            if (-not [string]::IsNullOrWhiteSpace($account)) {
                Write-Host ("  - {0}" -f $account)
            }
        }
    }
}

Export-ModuleMember -Function Read-ChannelMap, Get-ChannelMapValidationErrors, Get-DuplicateChannelRows, New-ChannelReports, Write-ChannelDuplicateSummary
