function Get-NativeEdgeUserDataDir {
    [CmdletBinding()]
    param()

    Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"
}

function Get-NativeEdgeProfiles {
    [CmdletBinding()]
    param(
        [string]$UserDataDir = (Get-NativeEdgeUserDataDir)
    )

    $localStatePath = Join-Path $UserDataDir "Local State"
    if (-not (Test-Path -LiteralPath $localStatePath -PathType Leaf)) {
        return @()
    }

    $localState = Get-Content -LiteralPath $localStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($localState.PSObject.Properties.Name -contains "profile") -or
        $null -eq $localState.profile -or
        -not ($localState.profile.PSObject.Properties.Name -contains "info_cache") -or
        $null -eq $localState.profile.info_cache) {
        return @()
    }

    foreach ($property in $localState.profile.info_cache.PSObject.Properties) {
        $profileDirectoryName = [string]$property.Name
        $profileInfo = $property.Value
        $profilePath = Join-Path $UserDataDir $profileDirectoryName

        [pscustomobject]@{
            DirectoryName = $profileDirectoryName
            Name = [string]$profileInfo.name
            UserName = [string]$profileInfo.user_name
            GaiaName = [string]$profileInfo.gaia_name
            IsUsingDefaultName = [bool]$profileInfo.is_using_default_name
            AvatarIcon = [string]$profileInfo.avatar_icon
            Path = $profilePath
            Exists = Test-Path -LiteralPath $profilePath -PathType Container
        }
    }
}

function Write-NativeEdgeProfileReport {
    [CmdletBinding()]
    param(
        [object[]]$Profiles
    )

    Write-Host ""
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    Write-Host "Perfis nativos do Microsoft Edge" -ForegroundColor Cyan
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    Write-Host "Esses sao os perfis que aparecem no seletor interno do Edge." -ForegroundColor Yellow
    Write-Host "Os ambientes deste projeto usam --user-data-dir e aparecem pelos atalhos, nao aqui." -ForegroundColor Yellow
    Write-Host ""

    if (@($Profiles).Count -eq 0) {
        Write-Host "Nenhum perfil nativo encontrado."
        return
    }

    foreach ($profile in @($Profiles | Sort-Object DirectoryName)) {
        Write-Host ("[{0}] {1}" -f $profile.DirectoryName, $profile.Name) -ForegroundColor White
        if (-not [string]::IsNullOrWhiteSpace([string]$profile.UserName)) {
            Write-Host ("  Conta: {0}" -f $profile.UserName)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$profile.GaiaName)) {
            Write-Host ("  Nome Google/Microsoft: {0}" -f $profile.GaiaName)
        }
        Write-Host ("  Caminho: {0}" -f $profile.Path) -ForegroundColor DarkGray
    }
}

Export-ModuleMember -Function Get-NativeEdgeUserDataDir, Get-NativeEdgeProfiles, Write-NativeEdgeProfileReport
