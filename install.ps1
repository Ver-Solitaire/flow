<#
  install.ps1 - installe tout ce qu'il faut pour FLOW sur une nouvelle machine Windows, puis VERIFIE le resultat.
  Fonctionne avec Windows PowerShell 5.1 (deja present sur Windows) : double-clique sur install.cmd.

    install.cmd                         verifie, propose d'installer ce qui manque, prepare FLOW
    install.cmd -Check                  verifie seulement (ne modifie RIEN) ; code de sortie 0 = tout est la
    install.cmd -Yes                    sans questions (installe tout ce qui manque)
    install.cmd -WithGitHubCli          ajoute GitHub CLI (livraison par pull request)

  La liste des dependances, leurs versions minimales et leurs identifiants winget sont dans dependances.json
  (lu par tools\flow-deps.ps1) : rien n'est recopie ici. Code de sortie : 0 = FLOW est pret, 1 = il manque quelque chose.
#>
param([switch]$Yes, [switch]$WithGitHubCli, [switch]$Check, [string]$DepsFile, [switch]$SansPreparation)   # -SansPreparation : pour les tests (ni raccourci, ni configuration)
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
if ($DepsFile) { $env:FLOW_DEPS_FILE = $DepsFile }
. (Join-Path $Root 'tools\flow-deps.ps1')

function Title($t) { Write-Host ''; Write-Host "  $t" -ForegroundColor Cyan }
function Ok($t) { Write-Host "  [ok] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  [!]  $t" -ForegroundColor Yellow }
function Bad($t) { Write-Host "  [x]  $t" -ForegroundColor Red }
function Ask($q) {
    if ($Yes) { return $true }
    $a = Read-Host "  $q (O/n)"
    return ($a -eq '' -or $a -match '^[oOyY]')
}
function Pause-End { if (-not $Yes -and -not $Check) { Read-Host '  Entrée pour fermer' | Out-Null } }

# les dependances qui comptent pour cette installation : celles de l'utilisateur (pas Pester ni le compilateur, ni winget lui-meme)
function Wanted-Deps {
    @(Get-FlowDeps | Where-Object {
            $_.quand -ne 'développement' -and $_.id -ne 'winget' -and ($_.id -ne 'gh' -or $WithGitHubCli)
        })
}
function Show-State($st, $d) {
    if ($st.Statut -eq 'ok') { Ok (Get-DepMessage $st $d) }
    elseif ($st.Statut -eq 'inconnue') { Warn (Get-DepMessage $st $d) }
    elseif ($st.Obligatoire) { Bad (Get-DepMessage $st $d) }
    else { Warn ("$($d.nom) : " + $(if ($st.Statut -eq 'absent') { "absent ($($d.quand)) - $(Get-DepInstallCommand $d)" } else { Get-DepMessage $st $d })) }
}
function Get-States { $o = @(); foreach ($d in (Wanted-Deps)) { $o += (Get-DepState $d) }; $o }

Write-Host ''
Write-Host "  ===  FLOW - $(if ($Check) { 'verification des dependances' } else { 'installation' })  ===" -ForegroundColor Magenta
Write-Host "  dossier : $Root"

# ───────── etat actuel ─────────
Title 'Dépendances'
$deps = Wanted-Deps
$states = Get-States
foreach ($st in $states) { Show-State $st ($deps | Where-Object { $_.id -eq $st.Id } | Select-Object -First 1) }
$verdict = Get-DepsVerdict $states

if ($Check) {
    Write-Host ''
    if ($verdict.Ready) { Ok 'Tout ce qu''il faut pour FLOW est là.'; exit 0 }
    Bad 'Il manque quelque chose : double-clique sur install.cmd (ou lance « install.cmd » sans -Check) pour l''installer.'
    exit 1
}

# ───────── installation de ce qui manque ou est trop ancien ─────────
$todo = @($states | Where-Object { $_.Statut -in 'absent', 'ancienne' -and ($_.Obligatoire -or $_.Statut -eq 'absent') })
$tried = @{}
if ($todo.Count) {
    Title 'Gestionnaire de paquets'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $w = Get-FlowDep -Id 'winget'
        Bad "winget est introuvable : $($w.installation), puis relance install.cmd."
        Pause-End; exit 1
    }
    Ok 'winget'
    Write-Host ''
    if (Ask "Installer ou mettre à jour maintenant : $(($todo | ForEach-Object { $_.Nom }) -join ', ') ?") {
        foreach ($st in $todo) {
            $d = $deps | Where-Object { $_.id -eq $st.Id } | Select-Object -First 1
            if (-not $d.winget) { Warn "$($d.nom) : $(Get-DepInstallCommand $d)"; continue }
            $verb = 'install'
            if ($st.Statut -eq 'ancienne') { $verb = 'upgrade' }
            Write-Host "  -> $(if ($verb -eq 'upgrade') { 'mise à jour' } else { 'installation' }) de $($d.nom)…"
            winget $verb --id $d.winget -e --accept-source-agreements --accept-package-agreements --silent
            $tried[$st.Id] = $LASTEXITCODE
            if ($LASTEXITCODE -ne 0) { Bad "$($d.nom) : winget a échoué (code $LASTEXITCODE). Réessaie à la main : $(if ($verb -eq 'upgrade') { Get-DepUpgradeCommand $d } else { Get-DepInstallCommand $d })" }
        }
        Update-SessionPath
    } else { Warn 'installation des dépendances sautée' }
}

function Write-Summary {
    # ce qui est prêt, ce qui manque : le seul endroit où l'on dit si FLOW est prêt
    $okNames = @($states | Where-Object { $_.Statut -eq 'ok' } | ForEach-Object { $_.Nom })
    Write-Host ''; Write-Host '  ===  Résumé  ===' -ForegroundColor Magenta
    if ($okNames.Count) { Ok "prêt : $($okNames -join ', ')" }
    foreach ($st in @($verdict.Missing)) { Bad "manque : $($st.Nom) - $(Get-DepInstallCommand ($deps | Where-Object { $_.id -eq $st.Id } | Select-Object -First 1))" }
    foreach ($st in @($verdict.Old)) { Bad "à mettre à jour : $($st.Nom) $($st.Version) (minimum $($st.Min))" }
    foreach ($st in @($verdict.Unknown)) { Warn "version non vérifiée : $($st.Nom)" }
    foreach ($st in @($verdict.Optional)) { Warn "facultatif, absent : $($st.Nom) ($($st.Quand))" }
    foreach ($d in $reopen) { Warn "$($d.nom) : winget dit l'avoir installé, mais cette fenêtre ne le voit pas encore : ferme-la, rouvre-la et relance install.cmd (le PATH a changé)." }
}

# ───────── contre-verification : on regarde les outils eux-memes, pas le code de sortie de winget ─────────
$reopen = @()
if ($todo.Count) {
    Title 'Vérification après installation'
    $states = Get-States
    foreach ($st in $states) {
        $d = $deps | Where-Object { $_.id -eq $st.Id } | Select-Object -First 1
        Show-State $st $d
        if ($st.Statut -in 'absent', 'ancienne' -and $tried.ContainsKey($st.Id) -and $tried[$st.Id] -eq 0) { $reopen += $d }
    }
    $verdict = Get-DepsVerdict $states
}

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $pwsh -and (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe")) { $pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
if (-not $pwsh -and -not $SansPreparation) {
    Write-Summary
    Write-Host ''
    Bad 'PowerShell 7 est nécessaire pour FLOW : FLOW n''est PAS prêt.'
    Pause-End; exit 1
}

# ───────── préparation de FLOW ─────────
if (-not $SansPreparation) {
Title 'Préparation de FLOW'
$acc = Join-Path $Root 'config\accounts.json'
if (-not (Test-Path $acc)) {
    Copy-Item (Join-Path $Root 'config\accounts.example.json') $acc
    Ok 'config\accounts.json créé (Compte 1 = ~\.claude ; Compte 2 à connecter plus tard avec la touche C)'
} else { Ok 'config\accounts.json présent' }

# identité Git (pour les commits des ouvriers de l'équipe)
$git = (Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1).Source
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
}

Write-Summary
Write-Host ''
if ($verdict.Ready) {
    Write-Host '  ===  FLOW est prêt  ===' -ForegroundColor Magenta
    Write-Host '  Lance FLOW avec le raccourci « FLOW » du bureau, ou : pwsh -File FLOW.ps1'
    Write-Host '  Démos : pwsh -File FLOW.ps1 -Demo   ·   pwsh -File FLOW.ps1 -TeamDemo'
    Write-Host '  Pour revérifier à tout moment, sans rien modifier : install.cmd -Check'
    Pause-End; exit 0
}
Write-Host '  ===  FLOW n''est PAS prêt  ===' -ForegroundColor Red
if ($reopen.Count) { Write-Host '  Ferme cette fenêtre, rouvre-en une et relance install.cmd : certains outils ne sont visibles qu''après.' }
else { Write-Host '  Règle les points marqués [x] ci-dessus, puis relance install.cmd.' }
Pause-End; exit 1
