# terminal-setup

One-command setup for Windows Terminal + PowerShell 7 + oh-my-posh + Nerd Font on a clean Windows 10/11.

## Quick start

In Windows PowerShell or PowerShell 7 (no admin needed):

```powershell
irm https://raw.githubusercontent.com/iliakh02/terminal-setup/main/install.ps1 | iex
```

Restart Windows Terminal when it finishes.

## What it does

| Step | Details |
|---|---|
| Packages | Installs via winget (skipped if already present): PowerShell 7, Windows Terminal, oh-my-posh, Git |
| Repository | Clones this repo to `~\terminal-setup` (or downloads the zip if Git is missing), pulls on later runs |
| Font | `oh-my-posh font install CascadiaCode`, per user; if that fails, downloads `CascadiaCode.zip` from the [Nerd Fonts release](https://github.com/ryanoasis/nerd-fonts/releases/latest) and installs it per user (family names: `CaskaydiaCove NF` / `CaskaydiaCove NFM`) |
| Terminal-Icons | Installs the module for PowerShell 7, current user |
| Profile | Turns the pwsh profile into a small loader that dot-sources [`powershell/Microsoft.PowerShell_profile.ps1`](powershell/Microsoft.PowerShell_profile.ps1) from the repo |
| Windows Terminal | Merges [`windows-terminal/settings.overlay.json`](windows-terminal/settings.overlay.json) into the existing `settings.json` |
| VS Code | Merges [`vscode/settings.snippet.json`](vscode/settings.snippet.json) into the user `settings.json`, if VS Code is installed |

Every run is safe to repeat: steps that are already done are reported as `[SKIP]`, nothing is duplicated.

## Run locally

```powershell
git clone https://github.com/iliakh02/terminal-setup.git
cd terminal-setup
.\install.ps1 -DryRun   # preview
.\install.ps1
```

| Parameter | Effect |
|---|---|
| `-DryRun` | Show what would change, change nothing |
| `-SkipFonts` | Do not install the Nerd Font |
| `-SkipVSCode` | Do not touch VS Code settings |
| `-NoBackup` | Do not create `.bak-*` files before overwriting |

## Update

The profile, theme and settings are read from the repo, so:

```powershell
git -C ~\terminal-setup pull
```

Run `install.ps1` again after changing `windows-terminal/` or `vscode/` files, since those are merged copies.

## Roll back

Before changing a file the installer saves a copy next to it as `<file>.bak-<yyyyMMdd-HHmmss>`:

| File | Location |
|---|---|
| pwsh profile | `(Split-Path $PROFILE)\Microsoft.PowerShell_profile.ps1.bak-*` |
| Windows Terminal | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json.bak-*` |
| VS Code | `%APPDATA%\Code\User\settings.json.bak-*` |

Copy the backup over the original to restore it.

## How the merges work

**Profile.** Your `$PROFILE` gets a block between `# >>> terminal-setup >>>` and `# <<< terminal-setup <<<`. A profile without this block is replaced (and backed up); lines you add outside the block later are kept.

**Windows Terminal.** The overlay only holds my settings, not machine-specific profiles:

- top-level settings and `profiles.defaults` from the overlay win;
- `schemes` are matched by `name`, `actions` and `keybindings` by `id`; other bindings on the same keys are removed;
- profiles are matched by `guid` and only the overlay's fields are updated. Profiles that exist only on this machine (WSL, Visual Studio, SSH, ...) are left alone.

**VS Code.** Keys from the snippet are added or updated, language blocks like `[javascript]` are merged key by key. If `settings.json` has comments, it is not rewritten (comments would be lost); the installer prints what to add by hand.

No symlinks are used: the profile loader reads the repo directly, and the two settings files have to be merged anyway.

## Troubleshooting

**Running scripts is disabled.** `irm | iex` is not affected by the execution policy, but `.\install.ps1` may be. Allow it for the current window only:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

**winget not found.** Install or update [App Installer](https://apps.microsoft.com/detail/9NBLGGH4NNS1) from the Microsoft Store, then run the installer again.

**Admin prompts.** The script itself needs no admin rights, but the PowerShell 7 and Git installers are machine-wide and may show a UAC prompt.

**Icons show as squares.** The Nerd Font is missing or the app uses another font. Check that `CaskaydiaCove NF` is installed and restart Windows Terminal / VS Code.
