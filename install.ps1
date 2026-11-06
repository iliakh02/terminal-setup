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
    [switch]$DryRun
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
        [switch]$DryRun
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

    # --- Main -----------------------------------------------------------------

    # Windows PowerShell 5.1 may default to TLS 1.0
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    try {
        Write-Header 'Packages'
        if (-not (Test-Winget)) { Write-Summary; return }
        Install-WingetPackage -Id 'Microsoft.PowerShell' -Command 'pwsh'
        Install-WingetPackage -Id 'Microsoft.WindowsTerminal' -AppxName 'Microsoft.WindowsTerminal*'
        Install-WingetPackage -Id 'JanDeDobbeleer.OhMyPosh' -Command 'oh-my-posh'
        Install-WingetPackage -Id 'Git.Git' -Command 'git'
        Update-SessionPath

        Write-Header 'Repository'
        $null = Sync-Repo

        Write-Header 'Font'
        Install-NerdFont
    }
    catch {
        Write-Step FAIL 'Unexpected error' $_.Exception.Message
    }

    Write-Summary
}

Invoke-TerminalSetup -ScriptPath $TerminalSetupScriptPath -SkipVSCode:$SkipVSCode -SkipFonts:$SkipFonts -NoBackup:$NoBackup -DryRun:$DryRun
Remove-Item Function:\Invoke-TerminalSetup -ErrorAction SilentlyContinue
Remove-Variable TerminalSetupScriptPath -ErrorAction SilentlyContinue
