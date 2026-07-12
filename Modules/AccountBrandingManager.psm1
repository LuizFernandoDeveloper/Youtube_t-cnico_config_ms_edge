function Add-OrSetProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        $Value
    )

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Get-FactoryConfigDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    if ($Config.PSObject.Properties.Name -contains "_configDirectory" -and -not [string]::IsNullOrWhiteSpace([string]$Config._configDirectory)) {
        return [string]$Config._configDirectory
    }

    return (Get-Location).Path
}

function Resolve-FactoryAssetPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $Config
    )

    $configDirectory = Get-FactoryConfigDirectory -Config $Config
    return Resolve-FactoryPath -Path $Path -BasePath $configDirectory
}

function Get-AccountForProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        $Profile
    )

    if (-not ($Config.PSObject.Properties.Name -contains "accounts") -or $null -eq $Config.accounts) {
        return $null
    }

    $googleAccount = [string]$Profile.googleAccount
    foreach ($property in $Config.accounts.PSObject.Properties) {
        $account = $property.Value
        if (-not [string]::IsNullOrWhiteSpace($googleAccount) -and [string]$account.email -ieq $googleAccount) {
            return [pscustomobject]@{
                Key = $property.Name
                Account = $account
            }
        }
    }

    $label = [string]$Profile.googleAccountLabel
    foreach ($property in $Config.accounts.PSObject.Properties) {
        $account = $property.Value
        if (-not [string]::IsNullOrWhiteSpace($label) -and [string]$account.label -like "*$label*") {
            return [pscustomobject]@{
                Key = $property.Name
                Account = $account
            }
        }
    }

    return $null
}

function Get-ProfileAccountAssetPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        $Profile,

        [ValidateSet("image", "art", "icon")]
        [string]$Kind = "image"
    )

    $match = Get-AccountForProfile -Config $Config -Profile $Profile
    if ($null -eq $match) {
        return ""
    }

    $account = $match.Account
    if (-not ($account.PSObject.Properties.Name -contains $Kind) -or [string]::IsNullOrWhiteSpace([string]$account.$Kind)) {
        return ""
    }

    $assetPath = Resolve-FactoryAssetPath -Path ([string]$account.$Kind) -Config $Config
    if (Test-Path -LiteralPath $assetPath -PathType Leaf) {
        return $assetPath
    }

    return ""
}

function Get-ProfileShortcutIconPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        $Profile
    )

    return Get-ProfileAccountAssetPath -Config $Config -Profile $Profile -Kind "icon"
}

function Read-JsonObjectOrEmpty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            return ($raw | ConvertFrom-Json)
        }
    }

    return [pscustomobject]@{}
}

function Write-JsonObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $Object | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Ensure-ChildObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not ($Object.PSObject.Properties.Name -contains $Name) -or $null -eq $Object.$Name) {
        Add-OrSetProperty -Object $Object -Name $Name -Value ([pscustomobject]@{})
    }

    return $Object.$Name
}

function Get-NestedValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $current = $Object
    foreach ($part in ($Path -split "\.")) {
        if ($null -eq $current -or -not ($current.PSObject.Properties.Name -contains $part)) {
            return $null
        }
        $current = $current.$part
    }

    return $current
}

function Set-NestedValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        $Value
    )

    $parts = $Path -split "\."
    $current = $Object
    for ($index = 0; $index -lt ($parts.Count - 1); $index++) {
        $current = Ensure-ChildObject -Object $current -Name $parts[$index]
    }

    Add-OrSetProperty -Object $current -Name $parts[-1] -Value $Value
}

function Copy-FileWithBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        return $false
    }

    $destinationDirectory = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $backupPath = "{0}.pre-baseline-{1}" -f $Destination, (Get-Date -Format "yyyyMMddHHmmss")
        Copy-Item -LiteralPath $Destination -Destination $backupPath -Force
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return $true
}

function Copy-SafeEdgeBaselineConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceUserDataDir,

        [Parameter(Mandatory = $true)]
        [string]$TargetUserDataDir
    )

    if ([System.IO.Path]::GetFullPath($SourceUserDataDir).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($TargetUserDataDir).TrimEnd('\')) {
        return [pscustomobject]@{
            Applied = $false
            Reason = "Origem e destino sao o mesmo perfil."
            CopiedFiles = @()
            CopiedPreferences = @()
        }
    }

    if (-not (Test-Path -LiteralPath $SourceUserDataDir -PathType Container)) {
        return [pscustomobject]@{
            Applied = $false
            Reason = "Perfil base ainda nao existe: $SourceUserDataDir"
            CopiedFiles = @()
            CopiedPreferences = @()
        }
    }

    if ((Get-Command Test-EdgeUserDataDirInUse -ErrorAction SilentlyContinue) -and (Test-EdgeUserDataDirInUse -UserDataDir $TargetUserDataDir)) {
        throw "Feche o Edge do perfil destino antes de aplicar configuracao base: $TargetUserDataDir"
    }

    $copiedFiles = New-Object System.Collections.Generic.List[string]
    $copiedPreferences = New-Object System.Collections.Generic.List[string]

    $sourceBookmarks = Join-Path $SourceUserDataDir "Default\Bookmarks"
    $targetBookmarks = Join-Path $TargetUserDataDir "Default\Bookmarks"
    if (Copy-FileWithBackup -Source $sourceBookmarks -Destination $targetBookmarks) {
        $copiedFiles.Add("Default\Bookmarks")
    }

    $sourcePreferencesPath = Join-Path $SourceUserDataDir "Default\Preferences"
    $targetPreferencesPath = Join-Path $TargetUserDataDir "Default\Preferences"
    if (Test-Path -LiteralPath $sourcePreferencesPath -PathType Leaf) {
        $sourcePreferences = Read-JsonObjectOrEmpty -Path $sourcePreferencesPath
        $targetPreferences = Read-JsonObjectOrEmpty -Path $targetPreferencesPath

        $allowList = @(
            "bookmark_bar.show_on_all_tabs",
            "browser.show_home_button",
            "homepage",
            "homepage_is_newtabpage",
            "download.prompt_for_download",
            "translate.enabled",
            "webkit.webprefs.default_font_size",
            "webkit.webprefs.default_fixed_font_size",
            "webkit.webprefs.minimum_font_size",
            "browser.enable_spellchecking",
            "spellcheck.dictionaries"
        )

        foreach ($path in $allowList) {
            $value = Get-NestedValue -Object $sourcePreferences -Path $path
            if ($null -ne $value) {
                Set-NestedValue -Object $targetPreferences -Path $path -Value $value
                $copiedPreferences.Add($path)
            }
        }

        Write-JsonObject -Object $targetPreferences -Path $targetPreferencesPath
    }

    return [pscustomobject]@{
        Applied = (($copiedFiles.Count + $copiedPreferences.Count) -gt 0)
        Reason = ""
        CopiedFiles = $copiedFiles.ToArray()
        CopiedPreferences = $copiedPreferences.ToArray()
    }
}

function Get-AvatarIndexForProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        $Profile
    )

    $account = Get-AccountForProfile -Config $Config -Profile $Profile
    if ($null -eq $account) {
        return 1
    }

    switch ($account.Key) {
        "matriz" { return 4 }
        "academica" { return 12 }
        "engenharia" { return 26 }
        "diversa" { return 20 }
        default { return 1 }
    }
}

function Set-EdgeProfileBranding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        $Profile,

        [Parameter(Mandatory = $true)]
        [string]$UserDataDir,

        [string]$BaselineSourceSlug,

        [bool]$BaselineApplied = $false
    )

    if ((Get-Command Test-EdgeUserDataDirInUse -ErrorAction SilentlyContinue) -and (Test-EdgeUserDataDirInUse -UserDataDir $UserDataDir)) {
        throw "Feche o Edge deste perfil antes de aplicar nome/foto/configuracao: $($Profile.slug)"
    }

    $profileName = [string]$Profile.name
    $avatarIndex = Get-AvatarIndexForProfile -Config $Config -Profile $Profile
    $imagePath = Get-ProfileAccountAssetPath -Config $Config -Profile $Profile -Kind "image"
    $iconPath = Get-ProfileAccountAssetPath -Config $Config -Profile $Profile -Kind "icon"

    $preferencesPath = Join-Path $UserDataDir "Default\Preferences"
    $preferences = Read-JsonObjectOrEmpty -Path $preferencesPath
    Set-NestedValue -Object $preferences -Path "profile.name" -Value $profileName
    Set-NestedValue -Object $preferences -Path "profile.avatar_index" -Value $avatarIndex
    Set-NestedValue -Object $preferences -Path "profile.using_default_name" -Value $false
    Write-JsonObject -Object $preferences -Path $preferencesPath

    $localStatePath = Join-Path $UserDataDir "Local State"
    $localState = Read-JsonObjectOrEmpty -Path $localStatePath
    Set-NestedValue -Object $localState -Path "profile.info_cache.Default.name" -Value $profileName
    Set-NestedValue -Object $localState -Path "profile.info_cache.Default.avatar_icon" -Value ("chrome://theme/IDR_PROFILE_AVATAR_{0}" -f $avatarIndex)
    Set-NestedValue -Object $localState -Path "profile.info_cache.Default.is_using_default_name" -Value $false
    Set-NestedValue -Object $localState -Path "profile.info_cache.Default.gaia_picture_file_name" -Value ""
    Write-JsonObject -Object $localState -Path $localStatePath

    $metadataDirectory = Join-Path $UserDataDir ".edge-profile-factory"
    if (-not (Test-Path -LiteralPath $metadataDirectory)) {
        New-Item -ItemType Directory -Path $metadataDirectory -Force | Out-Null
    }

    $metadata = [pscustomobject]@{
        code = Get-ProfileCode -Profile $Profile
        name = $profileName
        slug = [string]$Profile.slug
        googleAccount = [string]$Profile.googleAccount
        googleAccountLabel = [string]$Profile.googleAccountLabel
        defaultBrandAccount = [string]$Profile.defaultBrandAccount
        accountImage = $imagePath
        accountIcon = $iconPath
        baselineSourceSlug = $BaselineSourceSlug
        baselineApplied = $BaselineApplied
        updatedAt = (Get-Date).ToString("s")
        securityNote = "Nao contem senha, cookie, token nem credencial."
    }
    Write-JsonObject -Object $metadata -Path (Join-Path $metadataDirectory "profile-metadata.json")

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level "OK" -Message "Nome/foto/metadados aplicados ao perfil: $($Profile.slug)"
    }
}

function Set-ProfileAccountConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [Parameter(Mandatory = $true)]
        $Profile,

        [string]$BaselineSourceSlug = "00-Administracao-Google",

        [switch]$ApplyBaseConfig
    )

    $targetDirectory = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $Profile
    $baselineApplied = $false

    if ($ApplyBaseConfig -and -not [string]::IsNullOrWhiteSpace($BaselineSourceSlug) -and [string]$Profile.slug -ine $BaselineSourceSlug) {
        $sourceProfile = Get-ProfileBySlug -Config $Config -Slug $BaselineSourceSlug
        if ($null -ne $sourceProfile) {
            $sourceDirectory = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $sourceProfile
            $result = Copy-SafeEdgeBaselineConfig -SourceUserDataDir $sourceDirectory -TargetUserDataDir $targetDirectory
            $baselineApplied = [bool]$result.Applied
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                if ($result.Applied) {
                    Write-Log -Level "OK" -Message "Configuracao segura do perfil base aplicada em $($Profile.slug)."
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$result.Reason)) {
                    Write-Log -Level "WARN" -Message $result.Reason
                }
            }
        }
        elseif (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Level "WARN" -Message "Perfil base nao encontrado: $BaselineSourceSlug"
        }
    }

    Set-EdgeProfileBranding -Config $Config -Profile $Profile -UserDataDir $targetDirectory -BaselineSourceSlug $BaselineSourceSlug -BaselineApplied:$baselineApplied
}

Export-ModuleMember -Function Get-AccountForProfile, Get-ProfileAccountAssetPath, Get-ProfileShortcutIconPath, Copy-SafeEdgeBaselineConfig, Set-EdgeProfileBranding, Set-ProfileAccountConfiguration
