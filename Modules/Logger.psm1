$script:EdgeProfileFactoryLogFile = $null

function Initialize-Logger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [string]$LogFileName = "EdgeProfileFactory.log"
    )

    if (-not [System.IO.Path]::IsPathRooted($LogDirectory)) {
        throw "O diretorio de log deve ser absoluto: $LogDirectory"
    }

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $script:EdgeProfileFactoryLogFile = Join-Path $LogDirectory $LogFileName

    if (-not (Test-Path -LiteralPath $script:EdgeProfileFactoryLogFile)) {
        New-Item -ItemType File -Path $script:EdgeProfileFactoryLogFile -Force | Out-Null
    }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [ValidateSet("INFO", "OK", "WARN", "ERROR", "DRYRUN")]
        [string]$Level = "INFO",

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [switch]$NoConsole
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message

    if ($script:EdgeProfileFactoryLogFile) {
        Add-Content -LiteralPath $script:EdgeProfileFactoryLogFile -Value $line -Encoding UTF8
    }

    if (-not $NoConsole) {
        switch ($Level) {
            "ERROR" { Write-Host $line -ForegroundColor Red }
            "WARN"  { Write-Host $line -ForegroundColor Yellow }
            "OK"    { Write-Host $line -ForegroundColor Green }
            "DRYRUN"{ Write-Host $line -ForegroundColor Cyan }
            default { Write-Host $line }
        }
    }
}

function Get-FileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Arquivo nao encontrado para hash: $Path"
    }

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

Export-ModuleMember -Function Initialize-Logger, Write-Log, Get-FileSha256
