function Get-KasperskyProcessStatus {
    [CmdletBinding()]
    param()

    $knownProcesses = @(
        "avp",
        "avpui",
        "kpm",
        "kpm_service",
        "kpm_isolated",
        "ksde",
        "ksdeui",
        "ksec"
    )

    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $name = $_.ProcessName
            $knownProcesses | Where-Object { $name -like "$_*" -or $name -ieq $_ }
        } | Sort-Object ProcessName, Id | Select-Object ProcessName, Id, @{ Name = "HasPath"; Expression = { -not [string]::IsNullOrWhiteSpace($_.Path) } })

    [pscustomobject]@{
        AntivirusRunning = @($processes | Where-Object { $_.ProcessName -in @("avp", "avpui") }).Count -gt 0
        PasswordManagerRunning = @($processes | Where-Object { $_.ProcessName -like "kpm*" }).Count -gt 0
        VpnRunning = @($processes | Where-Object { $_.ProcessName -in @("ksde", "ksdeui", "ksec") }).Count -gt 0
        Processes = $processes
    }
}

function Get-KasperskyInstalledProducts {
    [CmdletBinding()]
    param()

    $registryRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $products = New-Object System.Collections.Generic.List[object]
    foreach ($root in $registryRoots) {
        $items = @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue | Where-Object {
                $_.DisplayName -match "Kaspersky"
            })

        foreach ($item in $items) {
            $products.Add([pscustomobject]@{
                    DisplayName = [string]$item.DisplayName
                    DisplayVersion = [string]$item.DisplayVersion
                    Publisher = [string]$item.Publisher
                })
        }
    }

    $products | Sort-Object DisplayName, DisplayVersion -Unique
}

function Get-KasperskySecurityStatus {
    [CmdletBinding()]
    param()

    $processStatus = Get-KasperskyProcessStatus
    $products = @(Get-KasperskyInstalledProducts)

    [pscustomobject]@{
        AntivirusRunning = $processStatus.AntivirusRunning
        PasswordManagerRunning = $processStatus.PasswordManagerRunning
        VpnRunning = $processStatus.VpnRunning
        ProcessCount = @($processStatus.Processes).Count
        Processes = $processStatus.Processes
        InstalledProducts = $products
    }
}

function Write-KasperskySecurityStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Status
    )

    Write-Host ""
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    Write-Host "Checagem segura do Kaspersky" -ForegroundColor Cyan
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    Write-Host ("Antivirus ativo:            {0}" -f ($(if ($Status.AntivirusRunning) { "sim" } else { "nao detectado" })))
    Write-Host ("Password Manager ativo:     {0}" -f ($(if ($Status.PasswordManagerRunning) { "sim" } else { "nao detectado" })))
    Write-Host ("VPN Kaspersky ativa:        {0}" -f ($(if ($Status.VpnRunning) { "sim" } else { "nao detectado" })))
    Write-Host ("Processos Kaspersky vistos: {0}" -f $Status.ProcessCount)

    foreach ($process in @($Status.Processes)) {
        Write-Host (" - {0} (PID {1})" -f $process.ProcessName, $process.Id)
    }

    if (@($Status.InstalledProducts).Count -gt 0) {
        Write-Host ""
        Write-Host "Produtos instalados:" -ForegroundColor Cyan
        foreach ($product in @($Status.InstalledProducts)) {
            $version = ""
            if (-not [string]::IsNullOrWhiteSpace([string]$product.DisplayVersion)) {
                $version = " $($product.DisplayVersion)"
            }
            Write-Host (" - {0}{1}" -f $product.DisplayName, $version)
        }
    }

    Write-Host ""
    Write-Host "Seguranca: esta checagem nao le senhas, tokens, cookies, cofres ou dados internos da extensao." -ForegroundColor Yellow
}

function Write-KasperskyManualLoginGuidance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Status
    )

    if ($Status.PasswordManagerRunning) {
        Write-Host "Use o Kaspersky Password Manager manualmente para preencher login/senha neste perfil." -ForegroundColor Yellow
        Write-Host "Eu nao consigo e nao devo clicar, revelar, copiar ou exportar a senha por voce." -ForegroundColor DarkYellow
    }
    else {
        Write-Host "Kaspersky Password Manager nao foi detectado como processo ativo agora." -ForegroundColor Yellow
        Write-Host "Abra/desbloqueie o Kaspersky Password Manager e use o preenchimento automatico manualmente." -ForegroundColor Yellow
    }
}

Export-ModuleMember -Function Get-KasperskyProcessStatus, Get-KasperskyInstalledProducts, Get-KasperskySecurityStatus, Write-KasperskySecurityStatus, Write-KasperskyManualLoginGuidance
