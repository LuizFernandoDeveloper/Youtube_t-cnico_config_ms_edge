function Read-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Arquivo JSON nao encontrado: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Arquivo JSON vazio: $Path"
    }

    try {
        return $raw | ConvertFrom-Json
    }
    catch {
        throw "JSON invalido em ${Path}: $($_.Exception.Message)"
    }
}

function Resolve-FactoryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Test-PathInsideDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullDirectory = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\')
    return $fullPath.Equals($fullDirectory, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullDirectory + "\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-FactoryProtectedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\')

    if ($fullPath.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $protected = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
            $env:windir,
            $env:SystemRoot,
            $env:ProgramFiles,
            [Environment]::GetEnvironmentVariable("ProgramFiles(x86)"),
            (Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data")
        )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $protected.Add(([System.IO.Path]::GetFullPath($candidate).TrimEnd('\')))
        }
    }

    foreach ($protectedPath in $protected) {
        if (Test-PathInsideDirectory -Path $fullPath -Directory $protectedPath) {
            return $true
        }
    }

    return $false
}

function Assert-SafeBaseDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    if (-not [System.IO.Path]::IsPathRooted($BaseDirectory)) {
        throw "O diretorio base deve ser absoluto: $BaseDirectory"
    }

    if (Test-FactoryProtectedPath -Path $BaseDirectory) {
        throw "Diretorio base bloqueado por seguranca: $BaseDirectory"
    }
}

function Get-ProfileDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [Parameter(Mandatory = $true)]
        $Profile
    )

    Join-Path $BaseDirectory $Profile.slug
}

function Get-StartupPages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Profile
    )

    if (($Profile.PSObject.Properties.Name -contains "startupPages") -and $null -ne $Profile.startupPages) {
        return @($Profile.startupPages)
    }

    return @()
}

function Test-ProfileEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Profile
    )

    if (($Profile.PSObject.Properties.Name -contains "active") -and $false -eq [bool]$Profile.active) {
        return $false
    }

    return $true
}

function Get-ConfiguredProfiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [switch]$IncludeInactive
    )

    $profiles = @($Config.profiles)
    if ($IncludeInactive) {
        return $profiles
    }

    return @($profiles | Where-Object { Test-ProfileEnabled -Profile $_ })
}

function Get-ProfileCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Profile
    )

    if ($Profile.PSObject.Properties.Name -contains "code" -and -not [string]::IsNullOrWhiteSpace([string]$Profile.code)) {
        return [string]$Profile.code
    }

    return [string]$Profile.slug
}

function Test-AbsoluteHttpUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {
        $uri = [Uri]$Url
        return $uri.IsAbsoluteUri -and @("http", "https").Contains($uri.Scheme.ToLowerInvariant())
    }
    catch {
        return $false
    }
}

function Test-ProfileConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [Parameter(Mandatory = $true)]
        [string[]]$ExtensionPackNames
    )

    $errors = New-Object System.Collections.Generic.List[string]

    if (-not ($Config.PSObject.Properties.Name -contains "profiles") -or $null -eq $Config.profiles) {
        $errors.Add("A configuracao precisa conter a lista 'profiles'.")
        return $errors.ToArray()
    }

    $names = @{}
    $slugs = @{}
    $codes = @{}
    $directories = @{}
    $invalidCharsPattern = "[{0}]" -f ([regex]::Escape((-join [System.IO.Path]::GetInvalidFileNameChars())))
    $reservedNames = @("CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9")

    foreach ($profile in @($Config.profiles)) {
        $name = [string]$profile.name
        $slug = [string]$profile.slug
        $code = [string]$profile.code
        $extensionPack = [string]$profile.extensionPack

        if ([string]::IsNullOrWhiteSpace($name)) {
            $errors.Add("Existe perfil sem nome.")
            continue
        }

        if ([string]::IsNullOrWhiteSpace($slug)) {
            $errors.Add("Perfil '$name' esta sem slug.")
            continue
        }

        $nameKey = $name.ToLowerInvariant()
        if ($names.ContainsKey($nameKey)) {
            $errors.Add("Nome duplicado: $name")
        }
        else {
            $names[$nameKey] = $true
        }

        $slugKey = $slug.ToLowerInvariant()
        if ($slugs.ContainsKey($slugKey)) {
            $errors.Add("Slug duplicado: $slug")
        }
        else {
            $slugs[$slugKey] = $true
        }

        if (-not [string]::IsNullOrWhiteSpace($code)) {
            $codeKey = $code.ToLowerInvariant()
            if ($codes.ContainsKey($codeKey)) {
                $errors.Add("Codigo duplicado: $code")
            }
            else {
                $codes[$codeKey] = $true
            }
        }

        if ($slug -match $invalidCharsPattern -or $slug -match "[\\/]" -or $slug -match "\.\." -or $slug.Trim() -ne $slug) {
            $errors.Add("Slug contem caracteres invalidos: $slug")
        }

        if ($reservedNames -contains $slug.ToUpperInvariant()) {
            $errors.Add("Slug reservado pelo Windows: $slug")
        }

        $directory = [System.IO.Path]::GetFullPath((Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $profile))
        if (-not (Test-PathInsideDirectory -Path $directory -Directory $BaseDirectory)) {
            $errors.Add("Diretorio do perfil escapa do diretorio base: $name -> $directory")
        }

        $directoryKey = $directory.ToLowerInvariant()
        if ($directories.ContainsKey($directoryKey)) {
            $errors.Add("Diretorio repetido: $directory")
        }
        else {
            $directories[$directoryKey] = $true
        }

        if ([string]::IsNullOrWhiteSpace($extensionPack)) {
            $errors.Add("Perfil '$name' nao informa extensionPack.")
        }
        elseif (-not ($ExtensionPackNames -contains $extensionPack)) {
            $errors.Add("Pacote de extensoes inexistente em '$name': $extensionPack")
        }

        if ($profile.PSObject.Properties.Name -contains "googleAccount") {
            $googleAccount = [string]$profile.googleAccount
            if (-not [string]::IsNullOrWhiteSpace($googleAccount) -and $googleAccount -notmatch "^[^@\s]+@[^@\s]+\.[^@\s]+$") {
                $errors.Add("Conta Google invalida em '$name': $googleAccount")
            }
        }

        foreach ($url in (Get-StartupPages -Profile $profile)) {
            if (-not (Test-AbsoluteHttpUrl -Url ([string]$url))) {
                $errors.Add("URL invalida em '$name': $url")
            }
        }

        $isVault = $slug -ieq "Cofre" -or $name -ieq "Cofre" -or $slug -match "(^|-)Cofre($|-)" -or $name -match "^Cofre\b" -or $code -eq "90"
        if ($isVault) {
            if ($extensionPack -ne "cofre") {
                $errors.Add("O perfil Cofre deve usar somente o pacote 'cofre'.")
            }

            foreach ($url in (Get-StartupPages -Profile $profile)) {
                if ($url -match "(youtube\.com|youtu\.be|facebook\.com|instagram\.com|tiktok\.com|x\.com|twitter\.com|reddit\.com)") {
                    $errors.Add("O perfil Cofre nao deve abrir YouTube ou redes sociais: $url")
                }
            }
        }
    }

    return $errors.ToArray()
}

function New-ProfileDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Level "OK" -Message "Diretorio criado: $Path"
        }
    }
    else {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Level "INFO" -Message "Diretorio existente: $Path"
        }
    }
}

function Get-ProfileBySlug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$Slug
    )

    foreach ($profile in @($Config.profiles)) {
        if ([string]$profile.slug -ieq $Slug) {
            return $profile
        }
    }

    return $null
}

Export-ModuleMember -Function Read-JsonFile, Resolve-FactoryPath, Test-PathInsideDirectory, Test-FactoryProtectedPath, Assert-SafeBaseDirectory, Get-ProfileDirectory, Get-StartupPages, Test-ProfileEnabled, Get-ConfiguredProfiles, Get-ProfileCode, Test-AbsoluteHttpUrl, Test-ProfileConfig, New-ProfileDirectory, Get-ProfileBySlug
