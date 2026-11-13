<#
  install.ps1 - installe tout ce qu'il faut pour FLOW sur une nouvelle machine Windows.
  Fonctionne avec Windows PowerShell 5.1 (déjà présent sur Windows) : double-clique sur install.cmd.

    install.cmd                         vérifie, propose d'installer ce qui manque, prépare FLOW
    powershell -File install.ps1 -Yes   sans questions (installe tout ce qui manque)
    powershell -File install.ps1 -WithGitHubCli   ajoute GitHub CLI (livraison par pull request)

  Dépendances (installées avec winget) :
    PowerShell 7      Microsoft.PowerShell        FLOW et ses écrans tournent sous pwsh
    psmux             marlocarlo.psmux            les sessions et les panneaux
    Git               Git.Git                     la fenêtre Équipe (copies de travail, fusions)
    Claude Code       Anthropic.ClaudeCode        claude
    Windows Terminal  Microsoft.WindowsTerminal   recommandé (couleurs, souris) ; déjà présent sur Windows 11
    GitHub CLI        GitHub.cli                  facultatif (-WithGitHubCli)
#>
param([switch]$Yes, [switch]$WithGitHubCli)
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Title($t) { Write-Host ''; Write-Host "  $t" -ForegroundColor Cyan }
function Ok($t) { Write-Host "  [ok] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  [!]  $t" -ForegroundColor Yellow }
function Bad($t) { Write-Host "  [x]  $t" -ForegroundColor Red }
function Ask($q) {
    if ($Yes) { return $true }
    $a = Read-Host "  $q (O/n)"
    return ($a -eq '' -or $a -match '^[oOyY]')
}
function Refresh-Path {
    # après une installation : relire le PATH (machine + utilisateur) sans rouvrir de fenêtre
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine'); $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$m;$u"
}
function Has($cmd, $paths) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) { return $true }
    foreach ($p in $paths) { if ($p -and (Test-Path $p)) { return $true } }
    return $false
}

Write-Host ''
Write-Host '  ===  FLOW - installation  ===' -ForegroundColor Magenta
Write-Host "  dossier : $Root"

# ───────── winget ─────────
Title 'Gestionnaire de paquets'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Bad 'winget est introuvable. Installe « App Installer » depuis le Microsoft Store, puis relance install.cmd.'
    Read-Host '  Entrée pour quitter' | Out-Null; exit 1
}
Ok 'winget'

# ───────── dépendances ─────────
$deps = @(
    @{ Name = 'PowerShell 7'; Id = 'Microsoft.PowerShell'; Cmd = 'pwsh'; Paths = @("$env:ProgramFiles\PowerShell\7\pwsh.exe"); Need = $true }
    @{ Name = 'psmux'; Id = 'marlocarlo.psmux'; Cmd = 'psmux'; Paths = @(); Need = $true }
    @{ Name = 'Git'; Id = 'Git.Git'; Cmd = 'git'; Paths = @("$env:ProgramFiles\Git\cmd\git.exe"); Need = $true }
    @{ Name = 'Claude Code'; Id = 'Anthropic.ClaudeCode'; Cmd = 'claude'; Paths = @(); Need = $true }
    @{ Name = 'Windows Terminal'; Id = 'Microsoft.WindowsTerminal'; Cmd = 'wt'; Paths = @("$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"); Need = $false }
)
if ($WithGitHubCli) { $deps += @{ Name = 'GitHub CLI'; Id = 'GitHub.cli'; Cmd = 'gh'; Paths = @("$env:ProgramFiles\GitHub CLI\gh.exe"); Need = $false } }

Title 'Dépendances'
$missing = @()
foreach ($d in $deps) {
    if (Has $d.Cmd $d.Paths) { Ok $d.Name } else { Warn "$($d.Name) manquant$(if (-not $d.Need) { ' (recommandé)' })"; $missing += $d }
}
if ($missing.Count) {
    Write-Host ''
    if (Ask "Installer maintenant : $(($missing | ForEach-Object { $_.Name }) -join ', ') ?") {
        foreach ($d in $missing) {
            Write-Host "  -> installation de $($d.Name)…"
            winget install --id $d.Id -e --accept-source-agreements --accept-package-agreements --silent
            if ($LASTEXITCODE -eq 0) { Ok "$($d.Name) installé" } else { Bad "$($d.Name) : échec (code $LASTEXITCODE) - réessaie : winget install --id $($d.Id) -e" }
        }
        Refresh-Path
    } else { Warn 'installation des dépendances sautée' }
}
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh -and (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe")) { $pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
if (-not $pwsh) { Bad 'PowerShell 7 est nécessaire pour FLOW : winget install --id Microsoft.PowerShell -e'; Read-Host '  Entrée pour quitter' | Out-Null; exit 1 }

# ───────── préparation de FLOW ─────────
Title 'Préparation de FLOW'
$acc = Join-Path $Root 'config\accounts.json'
if (-not (Test-Path $acc)) {
    Copy-Item (Join-Path $Root 'config\accounts.example.json') $acc
    Ok 'config\accounts.json créé (Compte 1 = ~\.claude ; Compte 2 à connecter plus tard avec la touche C)'
} else { Ok 'config\accounts.json présent' }

# identité Git (pour les commits des ouvriers de l'équipe)
$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git -and (Test-Path "$env:ProgramFiles\Git\cmd\git.exe")) { $git = "$env:ProgramFiles\Git\cmd\git.exe" }
if ($git) {
    $mail = & $git config --global user.email 2>$null
    if (-not $mail) {
        Warn 'Git n''a pas d''identité (nom / e-mail des commits)'
        if (-not $Yes -and (Ask 'La configurer maintenant ?')) {
            $n = Read-Host '  Nom'; $m = Read-Host '  E-mail'
            if ($n) { & $git config --global user.name $n }
            if ($m) { & $git config --global user.email $m }
            Ok 'identité Git enregistrée'
        } else { Warn 'sans identité, les commits de l''équipe seront signés « FLOW »' }
    } else { Ok "identité Git : $mail" }
}

# raccourci sur le bureau
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'FLOW.ps1') -InstallShortcut | ForEach-Object { Ok $_ }

# ───────── Claude ─────────
Title 'Claude'
$cred = Join-Path $HOME '.claude\.credentials.json'
if (Test-Path $cred) { Ok 'compte Claude principal connecté' }
elseif (Get-Command claude -ErrorAction SilentlyContinue) {
    Warn 'compte Claude principal pas encore connecté'
    if (-not $Yes -and (Ask 'Lancer Claude maintenant pour te connecter ? (/exit pour revenir)')) { & claude }
} else { Warn 'Claude Code introuvable : rouvre une fenêtre après l''installation, puis lance « claude »' }

Write-Host ''
Write-Host '  ===  FLOW est prêt  ===' -ForegroundColor Magenta
Write-Host '  Lance FLOW avec le raccourci « FLOW » du bureau, ou : pwsh -File FLOW.ps1'
Write-Host '  Démos : pwsh -File FLOW.ps1 -Demo   ·   pwsh -File FLOW.ps1 -TeamDemo'
Write-Host '  Si une commande reste introuvable, ferme et rouvre ta fenêtre (le PATH a changé).'
if (-not $Yes) { Read-Host '  Entrée pour fermer' | Out-Null }
