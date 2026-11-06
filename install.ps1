<#
.SYNOPSIS
    Sets up Windows Terminal + PowerShell 7 + oh-my-posh + Nerd Font.

.DESCRIPTION
    Remote: irm https://raw.githubusercontent.com/iliakh02/terminal-setup/main/install.ps1 | iex
    Local:  .\install.ps1 [-SkipVSCode] [-SkipFonts] [-NoBackup] [-DryRun]

    Works in Windows PowerShell 5.1 and PowerShell 7. Safe to run repeatedly.
    Keep this file ASCII-only: 5.1 reads BOM-less scripts as ANSI.
#>
[CmdletBinding()]
param(
    [switch]$SkipVSCode,
    [switch]$SkipFonts,
    [switch]$NoBackup,
    [switch]$DryRun,
    # Internal: 'Configure' is the second half, re-run under pwsh 7
    [ValidateSet('All', 'Configure')][string]$Stage = 'All'
)

# Captured before entering the function; empty when run via irm | iex
$TerminalSetupScriptPath = $PSCommandPath

# Everything lives in one function so irm | iex does not leak
# preferences or helpers into the caller's session.
function Invoke-TerminalSetup {
    [CmdletBinding()]
    param(
        [string]$ScriptPath,
        [switch]$SkipVSCode,
        [switch]$SkipFonts,
        [switch]$NoBackup,
        [switch]$DryRun,
        [string]$Stage
    )

    Set-StrictMode -Version 2
    $ErrorActionPreference = 'Stop'
    # Progress bars make Invoke-WebRequest very slow in 5.1
    $ProgressPreference = 'SilentlyContinue'

    $RepoUrl = 'https://github.com/iliakh02/terminal-setup'
    $RepoBranch = 'main'
    $RepoDir = Join-Path $HOME 'terminal-setup'
    $FontName = 'CascadiaCode'
    $FontFamily = 'CaskaydiaCove NF'
    $BlockStart = '# >>> terminal-setup >>>'
    $BlockEnd = '# <<< terminal-setup <<<'

    $Results = New-Object System.Collections.Generic.List[object]

    # --- Output ---------------------------------------------------------------

    function Write-Step {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive installer output')]
        param(
            [ValidateSet('OK', 'SKIP', 'FAIL', 'DRY')][string]$Status,
            [string]$Name,
            [string]$Detail
        )
        $color = @{ OK = 'Green'; SKIP = 'DarkGray'; FAIL = 'Red'; DRY = 'Cyan' }[$Status]
        Write-Host ('[{0}]' -f $Status).PadRight(7) -ForegroundColor $color -NoNewline
        Write-Host " $Name" -NoNewline
        if ($Detail) { Write-Host " - $Detail" -ForegroundColor DarkGray } else { Write-Host '' }
        $Results.Add([pscustomobject]@{ Status = $Status; Name = $Name; Detail = $Detail })
    }

    function Write-Header {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive installer output')]
        param([string]$Text)
        Write-Host ''
        Write-Host "== $Text" -ForegroundColor Magenta
    }

    function Write-Summary {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive installer output')]
        param()
        Write-Header 'Summary'
        foreach ($s in 'OK', 'SKIP', 'DRY', 'FAIL') {
            $n = @($Results | Where-Object { $_.Status -eq $s }).Count
            if ($n) { Write-Host ("  {0,-5} {1}" -f $s, $n) }
        }
        $failed = @($Results | Where-Object { $_.Status -eq 'FAIL' })
        foreach ($f in $failed) { Write-Host "  FAIL: $($f.Name) - $($f.Detail)" -ForegroundColor Red }
        Write-Host ''
        if ($DryRun) {
            Write-Host 'Dry run: nothing was changed.' -ForegroundColor Cyan
        }
        else {
            Write-Host 'Done. Restart Windows Terminal to apply everything.' -ForegroundColor Green
        }
    }

    # --- Helpers --------------------------------------------------------------

    function Test-Command([string]$Name) {
        [bool](Get-Command $Name -ErrorAction SilentlyContinue)
    }

    # Merge machine + user PATH into this session so fresh installs are usable now
    function Update-SessionPath {
        $parts = @($env:Path -split ';') +
            @([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';') +
            @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';')
        $seen = @{}
        $unique = foreach ($p in $parts) {
            $key = $p.TrimEnd('\')
            if ($key -and -not $seen.ContainsKey($key)) { $seen[$key] = $true; $p }
        }
        $env:Path = @($unique) -join ';'
    }

    function Test-FontInstalled([string]$Family) {
        Add-Type -AssemblyName System.Drawing
        $fonts = New-Object System.Drawing.Text.InstalledFontCollection
        [bool]($fonts.Families | Where-Object { $_.Name -eq $Family })
    }

    # Copies a file to <name>.bak-<timestamp>; returns a note for the step output
    function Backup-File([string]$Path) {
        if ($NoBackup -or -not (Test-Path $Path)) { return '' }
        $dest = '{0}.bak-{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $Path -Destination $dest -Force
        return "backup: $dest"
    }

    function Write-Utf8File([string]$Path, [string]$Text, [switch]$NoBom) {
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding (-not $NoBom)))
    }

    # Replaces items in $Existing whose $Key matches an item in $Incoming, appends the rest
    function Merge-ById($Existing, $Incoming, [string]$Key) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($e in @($Existing)) { if ($null -ne $e) { $list.Add($e) } }
        foreach ($item in @($Incoming)) {
            $idx = -1
            for ($i = 0; $i -lt $list.Count; $i++) {
                if ($list[$i] -is [Collections.IDictionary] -and $list[$i][$Key] -eq $item[$Key]) { $idx = $i; break }
            }
            if ($idx -ge 0) { $list[$idx] = $item } else { $list.Add($item) }
        }
        , $list.ToArray()
    }

    # --- Steps ----------------------------------------------------------------

    function Test-Winget {
        if (Test-Command 'winget') {
            Write-Step OK 'winget' 'found'
            return $true
        }
        Write-Step FAIL 'winget' 'not found'
        Write-Warning ("winget is missing. Install or update 'App Installer' from the Microsoft Store " +
            '(https://apps.microsoft.com/detail/9NBLGGH4NNS1), then run this script again.')
        return $false
    }

    function Install-WingetPackage {
        param(
            [string]$Id,
            [string]$Command,
            [string]$AppxName
        )
        if ($Command -and (Test-Command $Command)) {
            Write-Step SKIP $Id "'$Command' already available"
            return
        }
        if ($AppxName -and (Get-AppxPackage -Name $AppxName -ErrorAction SilentlyContinue)) {
            Write-Step SKIP $Id 'already installed'
            return
        }
        $null = winget list -e --id $Id --accept-source-agreements
        if ($LASTEXITCODE -eq 0) {
            Write-Step SKIP $Id 'already installed'
            return
        }
        if ($DryRun) {
            Write-Step DRY $Id 'would install via winget'
            return
        }
        winget install -e --id $Id --source winget --silent --accept-source-agreements --accept-package-agreements
        # 0x8A15002B: no applicable upgrade, 0x8A150061: already installed
        if ($LASTEXITCODE -in 0, -1978335189, -1978335135) {
            Write-Step OK $Id 'installed'
        }
        else {
            Write-Step FAIL $Id ('winget exit code {0}' -f $LASTEXITCODE)
        }
    }

    function Get-RepoZip([string]$Destination) {
        $zip = Join-Path ([IO.Path]::GetTempPath()) "terminal-setup-$([guid]::NewGuid().ToString('N')).zip"
        $tmp = $zip -replace '\.zip$', ''
        try {
            Invoke-WebRequest -Uri "$RepoUrl/archive/refs/heads/$RepoBranch.zip" -OutFile $zip -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $src = Get-ChildItem $tmp -Directory | Select-Object -First 1
            $null = New-Item -ItemType Directory -Path $Destination -Force
            Copy-Item -Path (Join-Path $src.FullName '*') -Destination $Destination -Recurse -Force
        }
        finally {
            Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Returns the repo root that config files are read from
    function Sync-Repo {
        # Local run: this script sits in a checkout next to the config folders
        $root = if ($ScriptPath) { Split-Path $ScriptPath -Parent }
        if ($root -and (Test-Path (Join-Path $root 'powershell'))) {
            Write-Step SKIP 'Repository' "running locally from $root"
            return $root
        }
        $hasGit = Test-Command 'git'
        if (Test-Path (Join-Path $RepoDir '.git')) {
            if ($DryRun) { Write-Step DRY 'Repository' "would git pull in $RepoDir"; return $RepoDir }
            if ($hasGit) {
                git -C $RepoDir pull --ff-only --quiet
                if ($LASTEXITCODE -ne 0) { throw "git pull failed in $RepoDir" }
                Write-Step OK 'Repository' "updated $RepoDir"
                return $RepoDir
            }
        }
        if ($DryRun) {
            # Read-only preview: fetch into a temp folder, never into $RepoDir
            $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) 'terminal-setup-dryrun'
            Get-RepoZip $tmpRoot
            Write-Step DRY 'Repository' "would clone to $RepoDir (preview copy in $tmpRoot)"
            return $tmpRoot
        }
        if ($hasGit -and -not (Test-Path $RepoDir)) {
            git clone --quiet --branch $RepoBranch "$RepoUrl.git" $RepoDir
            if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
            Write-Step OK 'Repository' "cloned to $RepoDir"
        }
        else {
            Get-RepoZip $RepoDir
            Write-Step OK 'Repository' "downloaded zip to $RepoDir"
        }
        return $RepoDir
    }

    function Install-NerdFont {
        if ($SkipFonts) { Write-Step SKIP 'Nerd Font' '-SkipFonts'; return }
        if (Test-FontInstalled $FontFamily) { Write-Step SKIP 'Nerd Font' "'$FontFamily' already installed"; return }
        if (-not (Test-Command 'oh-my-posh')) { Write-Step FAIL 'Nerd Font' 'oh-my-posh not found'; return }
        if ($DryRun) { Write-Step DRY 'Nerd Font' "would run: oh-my-posh font install $FontName --user"; return }
        oh-my-posh font install $FontName --user
        if ($LASTEXITCODE -eq 0) { Write-Step OK 'Nerd Font' "$FontName installed for current user" }
        else { Write-Step FAIL 'Nerd Font' "oh-my-posh exit code $LASTEXITCODE" }
    }

    # --- Configure steps (pwsh 7 only) ---------------------------------------

    function Install-TerminalIcons {
        if (Get-Module -ListAvailable -Name Terminal-Icons) {
            Write-Step SKIP 'Terminal-Icons' 'already installed'
            return
        }
        if ($DryRun) { Write-Step DRY 'Terminal-Icons' 'would install from PSGallery (CurrentUser)'; return }
        # PSResourceGet ships with pwsh 7.4+ and needs no NuGet provider
        if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
            Install-PSResource -Name Terminal-Icons -Repository PSGallery -Scope CurrentUser -TrustRepository -Quiet
        }
        else {
            if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
                $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
            }
            Install-Module -Name Terminal-Icons -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
        }
        Write-Step OK 'Terminal-Icons' 'installed for current user'
    }

    function Install-ProfileLoader([string]$Root) {
        # Console host profile; CurrentUserAllHosts resolves the real
        # Documents folder, including OneDrive redirection.
        $profilePath = Join-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) 'Microsoft.PowerShell_profile.ps1'
        $repoProfile = Join-Path $Root 'powershell\Microsoft.PowerShell_profile.ps1'
        $block = @(
            $BlockStart
            '# Managed by terminal-setup (install.ps1). Changes inside this block are overwritten.'
            ('$TerminalSetupProfile = ''{0}''' -f $repoProfile.Replace("'", "''"))
            'if (Test-Path $TerminalSetupProfile) { . $TerminalSetupProfile }'
            $BlockEnd
        ) -join "`r`n"

        $current = if (Test-Path $profilePath) { [IO.File]::ReadAllText($profilePath) } else { '' }
        $pattern = '(?s)' + [regex]::Escape($BlockStart) + '.*?' + [regex]::Escape($BlockEnd)
        if ($current -match $pattern) {
            if ($Matches[0] -eq $block) { Write-Step SKIP 'Profile loader' "up to date in $profilePath"; return }
            # Keep anything the user added around the block
            $new = [regex]::Replace($current, $pattern, { param($m) $block })
            $action = 'updated'
        }
        else {
            # Old full profile is replaced: its content now lives in the repo
            $new = $block + "`r`n"
            $action = if ($current.Trim()) { 'replaced old profile with' } else { 'created' }
        }
        if ($DryRun) { Write-Step DRY 'Profile loader' "would write $profilePath ($action loader)"; return }
        $note = Backup-File $profilePath
        Write-Utf8File $profilePath $new
        Write-Step OK 'Profile loader' ("$action loader in $profilePath $note").Trim()
    }

    function Get-TerminalSettingsPath {
        $candidates = @(
            "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
            "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
            "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
        )
        $found = @($candidates | Where-Object { Test-Path $_ })
        # Installed but never launched: seed the Store location, WT adds the rest on first start
        if (-not $found -and (Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue)) {
            $found = @($candidates[0])
        }
        $found
    }

    # Overlay wins for its own keys; machine-specific profiles and settings are kept
    function Merge-TerminalSettings($Settings, $Overlay) {
        foreach ($k in $Overlay.Keys) {
            if ($k -notin 'profiles', 'schemes', 'actions', 'keybindings') { $Settings[$k] = $Overlay[$k] }
        }
        $Settings['schemes'] = Merge-ById $Settings['schemes'] $Overlay['schemes'] 'name'

        # Drop other bindings on the same keys so ours are not shadowed,
        # including legacy actions that carry their own "keys"
        $myKeys = @($Overlay['keybindings'] | ForEach-Object { $_['keys'] })
        $myIds = @($Overlay['keybindings'] | ForEach-Object { $_['id'] })
        $actions = @($Settings['actions'] | Where-Object { $null -ne $_ -and -not ($_.Contains('keys') -and $_['keys'] -in $myKeys) })
        $Settings['actions'] = Merge-ById $actions $Overlay['actions'] 'id'
        $kept = @($Settings['keybindings'] | Where-Object { $null -ne $_ -and -not ($_['keys'] -in $myKeys -and $_['id'] -notin $myIds) })
        $Settings['keybindings'] = Merge-ById $kept $Overlay['keybindings'] 'id'

        $profiles = $Settings['profiles']
        if ($profiles -isnot [Collections.IDictionary]) {
            # Legacy format: profiles is a plain list
            $profiles = [ordered]@{ list = @($profiles | Where-Object { $null -ne $_ }) }
            $Settings['profiles'] = $profiles
        }
        if ($profiles['defaults'] -isnot [Collections.IDictionary]) { $profiles['defaults'] = [ordered]@{} }
        foreach ($k in $Overlay['profiles']['defaults'].Keys) { $profiles['defaults'][$k] = $Overlay['profiles']['defaults'][$k] }

        $list = New-Object System.Collections.Generic.List[object]
        foreach ($p in @($profiles['list'])) { if ($null -ne $p) { $list.Add($p) } }
        foreach ($mine in $Overlay['profiles']['list']) {
            $match = $list | Where-Object { $_['guid'] -eq $mine['guid'] } | Select-Object -First 1
            if ($match) { foreach ($k in $mine.Keys) { $match[$k] = $mine[$k] } }
            else { $list.Add($mine) }
        }
        $profiles['list'] = $list.ToArray()
        $Settings
    }

    function Set-TerminalSettings([string]$Root) {
        $overlayPath = Join-Path $Root 'windows-terminal\settings.overlay.json'
        $paths = @(Get-TerminalSettingsPath)
        if (-not $paths) {
            Write-Step SKIP 'Windows Terminal' 'settings.json not found; start Windows Terminal once and run again'
            return
        }
        foreach ($path in $paths) {
            try {
                $raw = if (Test-Path $path) { Get-Content $path -Raw } else { '' }
                $before = if ($raw.Trim()) { $raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
                $current = ConvertTo-Json $before -Depth 32
                # Parse again so the merge does not mutate $before
                $settings = if ($raw.Trim()) { $raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
                $overlay = Get-Content $overlayPath -Raw | ConvertFrom-Json -AsHashtable
                $merged = ConvertTo-Json (Merge-TerminalSettings $settings $overlay) -Depth 32
                if ($merged -eq $current) { Write-Step SKIP 'Windows Terminal' "up to date: $path"; continue }
                if ($DryRun) { Write-Step DRY 'Windows Terminal' "would merge into $path"; continue }
                $note = Backup-File $path
                Write-Utf8File $path $merged -NoBom
                Write-Step OK 'Windows Terminal' ("merged into $path $note").Trim()
            }
            catch {
                Write-Step FAIL 'Windows Terminal' "$path - $($_.Exception.Message)"
            }
        }
    }

    function Invoke-ConfigureSteps([string]$Root) {
        Write-Header 'PowerShell 7'
        Install-TerminalIcons
        Install-ProfileLoader $Root

        Write-Header 'Windows Terminal'
        Set-TerminalSettings $Root
    }

    # From Windows PowerShell 5.1: run the configure stage in pwsh 7 and
    # collect its results for one combined summary.
    function Start-ConfigureInPwsh([string]$Root) {
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if (-not $pwsh) {
            if ($DryRun) { Write-Step DRY 'PowerShell 7 stage' 'would continue in pwsh after it is installed' }
            else { Write-Step FAIL 'PowerShell 7 stage' 'pwsh not found; open a new terminal and run install.ps1 again' }
            return
        }
        $resultFile = Join-Path ([IO.Path]::GetTempPath()) "terminal-setup-$([guid]::NewGuid().ToString('N')).json"
        $pwshArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'install.ps1'), '-Stage', 'Configure')
        if ($SkipVSCode) { $pwshArgs += '-SkipVSCode' }
        if ($SkipFonts) { $pwshArgs += '-SkipFonts' }
        if ($NoBackup) { $pwshArgs += '-NoBackup' }
        if ($DryRun) { $pwshArgs += '-DryRun' }
        $env:TERMINAL_SETUP_RESULTS = $resultFile
        try { & $pwsh.Source @pwshArgs }
        finally { Remove-Item Env:\TERMINAL_SETUP_RESULTS -ErrorAction SilentlyContinue }
        if (Test-Path $resultFile) {
            foreach ($r in @(Get-Content $resultFile -Raw | ConvertFrom-Json)) { $Results.Add($r) }
            Remove-Item $resultFile -Force
        }
        else {
            Write-Step FAIL 'PowerShell 7 stage' "pwsh exited with code $LASTEXITCODE"
        }
    }

    # --- Main -----------------------------------------------------------------

    # Windows PowerShell 5.1 may default to TLS 1.0
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    try {
        if ($Stage -eq 'Configure') {
            Invoke-ConfigureSteps (Split-Path $ScriptPath -Parent)
        }
        else {
            Write-Header 'Packages'
            if (-not (Test-Winget)) { Write-Summary; return }
            Install-WingetPackage -Id 'Microsoft.PowerShell' -Command 'pwsh'
            Install-WingetPackage -Id 'Microsoft.WindowsTerminal' -AppxName 'Microsoft.WindowsTerminal*'
            Install-WingetPackage -Id 'JanDeDobbeleer.OhMyPosh' -Command 'oh-my-posh'
            Install-WingetPackage -Id 'Git.Git' -Command 'git'
            Update-SessionPath

            Write-Header 'Repository'
            $root = Sync-Repo

            Write-Header 'Font'
            Install-NerdFont

            if ($PSVersionTable.PSVersion.Major -ge 7) { Invoke-ConfigureSteps $root }
            else { Start-ConfigureInPwsh $root }
        }
    }
    catch {
        Write-Step FAIL 'Unexpected error' $_.Exception.Message
    }

    # Child configure stage hands results back to the 5.1 parent
    if ($Stage -eq 'Configure' -and $env:TERMINAL_SETUP_RESULTS) {
        ConvertTo-Json -InputObject $Results.ToArray() | Set-Content -Path $env:TERMINAL_SETUP_RESULTS -Encoding UTF8
        return
    }
    Write-Summary
}

Invoke-TerminalSetup -ScriptPath $TerminalSetupScriptPath -SkipVSCode:$SkipVSCode -SkipFonts:$SkipFonts -NoBackup:$NoBackup -DryRun:$DryRun -Stage $Stage
Remove-Item Function:\Invoke-TerminalSetup -ErrorAction SilentlyContinue
Remove-Variable TerminalSetupScriptPath -ErrorAction SilentlyContinue
