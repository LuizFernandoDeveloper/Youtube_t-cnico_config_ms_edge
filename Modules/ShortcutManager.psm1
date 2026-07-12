function Get-SafeShortcutFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $invalidPattern = "[{0}]" -f ([regex]::Escape((-join [System.IO.Path]::GetInvalidFileNameChars())))
    $safe = $Name -replace $invalidPattern, ""
    $safe = $safe -replace "\s+", " "
    $safe = $safe.Trim()

    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = "Perfil"
    }

    return $safe
}

function Get-ShortcutPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    $targets = New-Object System.Collections.Generic.List[object]
    $desktop = [Environment]::GetFolderPath("DesktopDirectory")
    $startMenuFolder = "YouTube Tecnico"

    if ($Config.PSObject.Properties.Name -contains "startMenuFolder" -and -not [string]::IsNullOrWhiteSpace([string]$Config.startMenuFolder)) {
        $startMenuFolder = [string]$Config.startMenuFolder
    }

    $startMenu = Join-Path (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs") $startMenuFolder

    foreach ($profile in @($Config.profiles)) {
        $fileName = "Microsoft Edge - {0}.lnk" -f (Get-SafeShortcutFileName -Name ([string]$profile.name))
        $userDataDir = Get-ProfileDirectory -BaseDirectory $BaseDirectory -Profile $profile

        if ([bool]$Config.createDesktopShortcuts) {
            $targets.Add([pscustomobject]@{
                Path = Join-Path $desktop $fileName
                UserDataDir = $userDataDir
                Profile = $profile
                Kind = "Desktop"
            })
        }

        if ([bool]$Config.createStartMenuShortcuts) {
            $targets.Add([pscustomobject]@{
                Path = Join-Path $startMenu $fileName
                UserDataDir = $userDataDir
                Profile = $profile
                Kind = "StartMenu"
            })
        }
    }

    return $targets.ToArray()
}

function New-EdgeProfileShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutPath,

        [Parameter(Mandatory = $true)]
        [string]$EdgePath,

        [Parameter(Mandatory = $true)]
        [string]$UserDataDir,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName
    )

    $shortcutDirectory = Split-Path -Parent $ShortcutPath
    if (-not (Test-Path -LiteralPath $shortcutDirectory)) {
        New-Item -ItemType Directory -Path $shortcutDirectory -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $EdgePath
    $shortcut.Arguments = '--user-data-dir="{0}" --no-first-run' -f $UserDataDir
    $shortcut.WorkingDirectory = Split-Path -Parent $EdgePath
    $shortcut.IconLocation = "$EdgePath,0"
    $shortcut.Description = "Microsoft Edge isolado - $ProfileName"
    $shortcut.Save()

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level "OK" -Message "Atalho criado/atualizado: $ShortcutPath"
    }
}

function New-EdgeProfileShortcuts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [Parameter(Mandatory = $true)]
        [string]$EdgePath,

        [string]$OnlySlug
    )

    $created = New-Object System.Collections.Generic.List[string]
    foreach ($target in (Get-ShortcutPlan -Config $Config -BaseDirectory $BaseDirectory)) {
        if ($OnlySlug -and ([string]$target.Profile.slug -ine $OnlySlug)) {
            continue
        }

        New-EdgeProfileShortcut -ShortcutPath $target.Path -EdgePath $EdgePath -UserDataDir $target.UserDataDir -ProfileName ([string]$target.Profile.name)
        $created.Add($target.Path)
    }

    return $created.ToArray()
}

function Export-EdgeShortcuts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }

    foreach ($target in (Get-ShortcutPlan -Config $Config -BaseDirectory $BaseDirectory)) {
        if (Test-Path -LiteralPath $target.Path -PathType Leaf) {
            Copy-Item -LiteralPath $target.Path -Destination (Join-Path $DestinationDirectory (Split-Path -Leaf $target.Path)) -Force
        }
    }
}

Export-ModuleMember -Function Get-SafeShortcutFileName, Get-ShortcutPlan, New-EdgeProfileShortcut, New-EdgeProfileShortcuts, Export-EdgeShortcuts
