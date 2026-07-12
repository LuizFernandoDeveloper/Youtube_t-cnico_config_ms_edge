function Get-EdgePolicyRegistryPath {
    [CmdletBinding()]
    param()

    return "HKCU:\SOFTWARE\Policies\Microsoft\Edge"
}

function Read-EdgePolicyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$RegistryPath = (Get-EdgePolicyRegistryPath)
    )

    $item = Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not ($item.PSObject.Properties.Name -contains $Name)) {
        return [pscustomobject]@{
            Exists = $false
            Value = $null
        }
    }

    return [pscustomobject]@{
        Exists = $true
        Value = $item.$Name
    }
}

function Get-EdgeBrowserPolicyStatus {
    [CmdletBinding()]
    param(
        [string]$RegistryPath = (Get-EdgePolicyRegistryPath)
    )

    $browserSignin = Read-EdgePolicyValue -Name "BrowserSignin" -RegistryPath $RegistryPath
    $syncDisabled = Read-EdgePolicyValue -Name "SyncDisabled" -RegistryPath $RegistryPath
    $hideFirstRun = Read-EdgePolicyValue -Name "HideFirstRunExperience" -RegistryPath $RegistryPath
    $forceSync = Read-EdgePolicyValue -Name "ForceSync" -RegistryPath $RegistryPath

    [pscustomobject]@{
        RegistryPath = $RegistryPath
        BrowserSignin = $browserSignin.Value
        BrowserSigninExists = $browserSignin.Exists
        SyncDisabled = $syncDisabled.Value
        SyncDisabledExists = $syncDisabled.Exists
        HideFirstRunExperience = $hideFirstRun.Value
        HideFirstRunExperienceExists = $hideFirstRun.Exists
        ForceSync = $forceSync.Value
        ForceSyncExists = $forceSync.Exists
        HollowEnforced = ($browserSignin.Exists -and [int]$browserSignin.Value -eq 0 -and $syncDisabled.Exists -and [int]$syncDisabled.Value -eq 1)
    }
}

function Save-EdgePolicyBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,

        [string]$RegistryPath = (Get-EdgePolicyRegistryPath)
    )

    $stateDirectory = Split-Path -Parent $StatePath
    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        return
    }

    $values = @{}
    foreach ($name in @("BrowserSignin", "SyncDisabled", "HideFirstRunExperience", "ForceSync")) {
        $value = Read-EdgePolicyValue -Name $name -RegistryPath $RegistryPath
        $values[$name] = [pscustomobject]@{
            Exists = [bool]$value.Exists
            Value = $value.Value
        }
    }

    $state = [pscustomobject]@{
        registryPath = $RegistryPath
        savedAt = (Get-Date).ToString("s")
        values = $values
    }

    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Set-EdgeHollowBrowserPolicies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,

        [string]$RegistryPath = (Get-EdgePolicyRegistryPath)
    )

    Save-EdgePolicyBackup -StatePath $StatePath -RegistryPath $RegistryPath

    if (-not (Test-Path -Path $RegistryPath)) {
        New-Item -Path $RegistryPath -Force -ErrorAction Stop | Out-Null
    }

    New-ItemProperty -Path $RegistryPath -Name "BrowserSignin" -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $RegistryPath -Name "SyncDisabled" -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $RegistryPath -Name "HideFirstRunExperience" -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null

    if ((Read-EdgePolicyValue -Name "ForceSync" -RegistryPath $RegistryPath).Exists) {
        Remove-ItemProperty -Path $RegistryPath -Name "ForceSync" -Force -ErrorAction Stop
    }

    $status = Get-EdgeBrowserPolicyStatus -RegistryPath $RegistryPath
    if (-not $status.HollowEnforced) {
        throw "A politica foi escrita, mas o Edge ainda nao reporta BrowserSignin=0 e SyncDisabled=1."
    }

    return $status
}

function Restore-EdgeHollowBrowserPolicies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath
    )

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "Backup de politica nao encontrado: $StatePath"
    }

    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $registryPath = [string]$state.registryPath
    if ([string]::IsNullOrWhiteSpace($registryPath)) {
        $registryPath = Get-EdgePolicyRegistryPath
    }

    if (-not (Test-Path -Path $registryPath)) {
        New-Item -Path $registryPath -Force -ErrorAction Stop | Out-Null
    }

    foreach ($name in @("BrowserSignin", "SyncDisabled", "HideFirstRunExperience", "ForceSync")) {
        $saved = $state.values.$name
        if ($null -eq $saved -or -not [bool]$saved.Exists) {
            if ((Read-EdgePolicyValue -Name $name -RegistryPath $registryPath).Exists) {
                Remove-ItemProperty -Path $registryPath -Name $name -Force -ErrorAction Stop
            }
            continue
        }

        New-ItemProperty -Path $registryPath -Name $name -PropertyType DWord -Value ([int]$saved.Value) -Force -ErrorAction Stop | Out-Null
    }

    Get-EdgeBrowserPolicyStatus -RegistryPath $registryPath
}

function Write-EdgeBrowserPolicyStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Status
    )

    Write-Host ""
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    Write-Host "Politicas do Microsoft Edge para perfil oco" -ForegroundColor Cyan
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    Write-Host ("Registro: {0}" -f $Status.RegistryPath)
    Write-Host ("BrowserSignin: {0}" -f $(if ($Status.BrowserSigninExists) { $Status.BrowserSignin } else { "(nao definido)" }))
    Write-Host ("SyncDisabled: {0}" -f $(if ($Status.SyncDisabledExists) { $Status.SyncDisabled } else { "(nao definido)" }))
    Write-Host ("HideFirstRunExperience: {0}" -f $(if ($Status.HideFirstRunExperienceExists) { $Status.HideFirstRunExperience } else { "(nao definido)" }))
    Write-Host ("ForceSync: {0}" -f $(if ($Status.ForceSyncExists) { $Status.ForceSync } else { "(nao definido)" }))
    Write-Host ("Perfil oco imposto: {0}" -f $(if ($Status.HollowEnforced) { "SIM" } else { "NAO" }))
}

Export-ModuleMember -Function Get-EdgePolicyRegistryPath, Get-EdgeBrowserPolicyStatus, Set-EdgeHollowBrowserPolicies, Restore-EdgeHollowBrowserPolicies, Write-EdgeBrowserPolicyStatus
