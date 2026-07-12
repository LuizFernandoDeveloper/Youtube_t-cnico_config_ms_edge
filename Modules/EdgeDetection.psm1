function Write-FactoryLog {
    param(
        [string]$Level,
        [string]$Message
    )

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level $Level -Message $Message
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

function Find-EdgeExecutable {
    [CmdletBinding()]
    param(
        [switch]$PromptIfMissing,
        [switch]$NonInteractive
    )

    $candidates = @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Write-FactoryLog -Level "INFO" -Message "Microsoft Edge localizado em: $candidate"
            return [pscustomobject]@{
                Path = $candidate
                WorkingDirectory = Split-Path -Parent $candidate
            }
        }
    }

    if ($PromptIfMissing -and -not $NonInteractive) {
        Write-FactoryLog -Level "WARN" -Message "Microsoft Edge nao foi encontrado nos caminhos padrao."
        $manualPath = Read-Host "Informe o caminho completo do msedge.exe"

        if ($manualPath -and (Test-Path -LiteralPath $manualPath -PathType Leaf) -and ((Split-Path -Leaf $manualPath) -ieq "msedge.exe")) {
            return [pscustomobject]@{
                Path = [System.IO.Path]::GetFullPath($manualPath)
                WorkingDirectory = Split-Path -Parent $manualPath
            }
        }
    }

    throw "Microsoft Edge nao encontrado. Atalhos invalidos nao serao criados."
}

function Get-EdgeProcessDetails {
    [CmdletBinding()]
    param()

    try {
        Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction Stop |
            Select-Object ProcessId, CommandLine
    }
    catch {
        Get-Process -Name msedge -ErrorAction SilentlyContinue |
            Select-Object @{ Name = "ProcessId"; Expression = { $_.Id } }, @{ Name = "CommandLine"; Expression = { "" } }
    }
}

function Get-EdgeProcessesForUserDataDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserDataDir
    )

    $fullPath = [System.IO.Path]::GetFullPath($UserDataDir)
    $escaped = $fullPath -replace "\\", "\\"

    Get-EdgeProcessDetails | Where-Object {
        $_.CommandLine -and
        ($_.CommandLine.IndexOf("--user-data-dir", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -and
        (
            $_.CommandLine.IndexOf($fullPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $_.CommandLine.IndexOf($escaped, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        )
    }
}

function Test-EdgeUserDataDirInUse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserDataDir
    )

    @((Get-EdgeProcessesForUserDataDir -UserDataDir $UserDataDir)).Count -gt 0
}

function Stop-EdgeProcessesForUserDataDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserDataDir,

        [int]$TimeoutSeconds = 10
    )

    $processes = @(Get-EdgeProcessesForUserDataDir -UserDataDir $UserDataDir)
    foreach ($process in $processes) {
        Write-FactoryLog -Level "INFO" -Message "Fechando processo do Edge criado para $UserDataDir (PID $($process.ProcessId))."
        Stop-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-EdgeUserDataDirInUse -UserDataDir $UserDataDir)) {
            return
        }
        Start-Sleep -Milliseconds 300
    }

    if (Test-EdgeUserDataDirInUse -UserDataDir $UserDataDir) {
        Write-FactoryLog -Level "WARN" -Message "Ainda ha processos do Edge usando $UserDataDir."
    }
}

function Test-AnyEdgeRunning {
    [CmdletBinding()]
    param()

    @((Get-EdgeProcessDetails)).Count -gt 0
}

function Start-EdgeProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EdgePath,

        [Parameter(Mandatory = $true)]
        [string]$UserDataDir,

        [string[]]$Urls = @(),

        [switch]$NoFirstRun,

        [switch]$NewWindow
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add(("--user-data-dir=""{0}""" -f $UserDataDir))

    if ($NoFirstRun) {
        $arguments.Add("--no-first-run")
    }

    if ($NewWindow) {
        $arguments.Add("--new-window")
    }

    foreach ($url in $Urls) {
        if (-not [string]::IsNullOrWhiteSpace($url)) {
            $arguments.Add($url)
        }
    }

    Write-FactoryLog -Level "INFO" -Message "Abrindo Edge com user-data-dir: $UserDataDir"
    Start-Process -FilePath $EdgePath -ArgumentList $arguments.ToArray() -WorkingDirectory (Split-Path -Parent $EdgePath) -PassThru
}

function Wait-EdgeProfileInitialized {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserDataDir,

        [int]$TimeoutSeconds = 30
    )

    $localState = Join-Path $UserDataDir "Local State"
    $defaultDir = Join-Path $UserDataDir "Default"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        if ((Test-Path -LiteralPath $localState -PathType Leaf) -or (Test-Path -LiteralPath $defaultDir -PathType Container)) {
            Write-FactoryLog -Level "OK" -Message "Diretorio inicializado: $UserDataDir"
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    Write-FactoryLog -Level "WARN" -Message "Tempo esgotado aguardando inicializacao de $UserDataDir."
    return $false
}

Export-ModuleMember -Function Find-EdgeExecutable, Get-EdgeProcessDetails, Get-EdgeProcessesForUserDataDir, Test-EdgeUserDataDirInUse, Stop-EdgeProcessesForUserDataDir, Test-AnyEdgeRunning, Start-EdgeProfile, Wait-EdgeProfileInitialized
