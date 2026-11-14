<#
  flow-share-demo.ps1 — démonstration des bibliothèques de profils partagés (FLOW.ps1 -ShareDemo)
  Prépare dans %TEMP%\flow-share-demo une copie de FLOW (serveur psmux « flowshare », tes sessions ne sont pas touchées) :
    · bibliothèque « Équipe (OneDrive) » : un dossier avec les profils de Léa et Marc
    · bibliothèque « Dépôt équipe »      : un dépôt Git (distant local) avec un profil de Léa
    · un dossier projet « boutique » (proposé automatiquement au premier lancement)
  Au bout de ~45 s, « Marc » publie un nouveau profil dans le dépôt : appuie sur R pour le voir arriver.
#>
param([switch]$Inside)
$ErrorActionPreference = 'Stop'
$Src  = Split-Path -Parent $PSScriptRoot
$Demo = Join-Path $env:TEMP 'flow-share-demo'
$F    = Join-Path $Demo 'FLOW'
$Remote = Join-Path $Demo 'remote-profils.git'
$Marc = Join-Path $Demo 'marc'

function Git { & $script:G @args 2>$null }
$G = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $G -and (Test-Path "$env:ProgramFiles\Git\cmd\git.exe")) { $G = "$env:ProgramFiles\Git\cmd\git.exe" }

if ($Inside) {
    # fenêtre de démo : collègue simulé en arrière-plan, puis le sélecteur
    $null = Start-Job -ScriptBlock {
        param($G, $Marc)
        Start-Sleep 45
        $p = [ordered]@{ name = 'Revue de code — Marc'; description = 'Claude en revue + terminal git, publié pendant ta démo'
            author = 'Marc'; published = (Get-Date -Format 'yyyy-MM-dd HH:mm'); cwdHint = 'boutique'
            rows = @(@{ height = 70; panes = @(@{ role = 'claude'; width = 60; focus = $true; args = '--model opus' }, @{ role = 'monitor'; width = 40 }) },
                     @{ height = 30; panes = @(@{ role = 'command'; width = 100; command = 'git log --oneline -15'; title = '⎇ historique' }) }) }
        ($p | ConvertTo-Json -Depth 10) | Set-Content (Join-Path $Marc 'profiles\revue-marc.json') -Encoding utf8
        & $G -C $Marc add -A *> $null
        & $G -C $Marc -c user.name=Marc -c user.email=marc@demo commit -q -m 'profil de revue' *> $null
        & $G -C $Marc push -q *> $null
    } -ArgumentList $G, $Marc
    & pwsh -NoProfile -File (Join-Path $F 'FLOW.ps1')
    Get-Job | Remove-Job -Force
    return
}

. (Join-Path $PSScriptRoot 'flow-deps.ps1')
if (-not $G) { Write-Host (Get-DepMissingText 'git') -ForegroundColor Red; return }
Write-Host "`n  Préparation de la démo de partage dans $Demo …" -ForegroundColor Cyan
& psmux -L flowshare kill-server *> $null
if (Test-Path $Demo) { Remove-Item $Demo -Recurse -Force }
New-Item -ItemType Directory -Force $Demo | Out-Null

# copie de FLOW, sur son propre serveur psmux
robocopy $Src $F /E /XD .git sources-cache .corbeille /XF state.json sources.json shared-local.json team-projects.json /NFL /NDL /NJH /NJS | Out-Null
$fp = Join-Path $F 'FLOW.ps1'
(Get-Content $fp -Raw -Encoding utf8).Replace("`$Sock      = 'flow'", "`$Sock      = 'flowshare'") | Set-Content $fp -Encoding utf8 -NoNewline
if (-not (Test-Path (Join-Path $F 'config\accounts.json'))) { Copy-Item (Join-Path $F 'config\accounts.example.json') (Join-Path $F 'config\accounts.json') }

# projet « boutique » à côté de FLOW (proposé automatiquement grâce à l'indice du profil)
$proj = Join-Path $Demo 'boutique'
New-Item -ItemType Directory -Force (Join-Path $proj 'src') | Out-Null
'# Boutique (projet de démo)' | Set-Content (Join-Path $proj 'README.md') -Encoding utf8
Git -C $proj init -q; Git -C $proj add -A; Git -C $proj -c user.name=Demo -c user.email=d@demo commit -q -m 'début'

function Profile-Json($o) { ($o | ConvertTo-Json -Depth 10) }

# bibliothèque 1 : dossier partagé (comme un OneDrive d'équipe)
$od = Join-Path $Demo 'OneDrive - Equipe\FLOW-profils'
New-Item -ItemType Directory -Force $od | Out-Null
Profile-Json ([ordered]@{ name = 'Front — Léa'; description = 'Claude + serveur de dev + terminal'; author = 'Léa'; published = '2026-11-12 09:30'; cwdHint = 'boutique'
    rows = @(@{ height = 70; panes = @(@{ role = 'claude'; width = 60; focus = $true }, @{ role = 'monitor'; width = 40 }) },
             @{ height = 30; panes = @(@{ role = 'command'; width = 50; command = 'Write-Host serveur de dev (démo)'; title = '▶ dev' }, @{ role = 'shell'; width = 50 }) }) }) |
    Set-Content (Join-Path $od 'front-lea.json') -Encoding utf8
Profile-Json ([ordered]@{ name = 'Duo comptes — Marc'; description = 'un Claude par compte (ses comptes « marc-pro » et « marc-perso » → ton compte par défaut)'; author = 'Marc'; published = '2026-11-10 17:05'; cwdHint = 'boutique'
    rows = @(@{ height = 75; panes = @(@{ role = 'monitor'; width = 30 }, @{ role = 'claude'; width = 35; account = 'marc-pro'; focus = $true }, @{ role = 'claude'; width = 35; account = 'marc-perso' }) },
             @{ height = 25; panes = @(@{ role = 'office'; width = 50 }, @{ role = 'shell'; width = 50 }) }) }) |
    Set-Content (Join-Path $od 'duo-marc.json') -Encoding utf8

# bibliothèque 2 : dépôt Git (le « distant » est un dépôt local nu, comme un GitHub privé)
Git init -q --bare -b main $Remote
$seed = Join-Path $Demo 'lea-depot'
Git clone -q $Remote $seed
New-Item -ItemType Directory -Force (Join-Path $seed 'profiles') | Out-Null
Profile-Json ([ordered]@{ name = 'Équipe — Léa'; description = 'prompt découpé en tâches + Claude général'; author = 'Léa'; published = '2026-11-11 14:20'; cwdHint = 'boutique'
    rows = @(@{ height = 66; panes = @(@{ role = 'team'; width = 38; focus = $true; maxTasks = 3 }, @{ role = 'claude'; width = 37 }, @{ role = 'monitor'; width = 25 }) },
             @{ height = 34; panes = @(@{ role = 'office'; width = 100 }) }) }) |
    Set-Content (Join-Path $seed 'profiles\equipe-lea.json') -Encoding utf8
Git -C $seed add -A; Git -C $seed -c user.name=Léa -c user.email=lea@demo commit -q -m 'profils'; Git -C $seed push -q origin main
Git clone -q $Remote $Marc   # copie de Marc : il publiera pendant la démo

# déclaration des bibliothèques (ce que fait la touche B) + copie locale du dépôt
$cache = Join-Path $F 'config\sources-cache'
New-Item -ItemType Directory -Force $cache | Out-Null
Git clone -q $Remote (Join-Path $cache 'depot-equipe')
([ordered]@{ sources = @(
    [ordered]@{ id = 'equipe-onedrive'; name = 'Équipe (OneDrive)'; type = 'folder'; path = $od },
    [ordered]@{ id = 'depot-equipe'; name = 'Dépôt équipe'; type = 'git'; url = $Remote; subdir = 'profiles' }) } | ConvertTo-Json -Depth 5) |
    Set-Content (Join-Path $F 'config\sources.json') -Encoding utf8

Write-Host '  prêt : ouverture de la fenêtre de démo' -ForegroundColor Green
# fenêtre propre (pas de session psmux héritée, couleurs actives)
$cmd = "Remove-Item Env:TMUX*, Env:PSMUX*, Env:NO_COLOR -ErrorAction SilentlyContinue; `$env:COLORTERM='truecolor'; & '$($PSCommandPath -replace "'", "''")' -Inside"
Start-Process pwsh -WindowStyle Maximized -ArgumentList @('-NoExit', '-NoProfile', '-Command', $cmd)
Write-Host @"

  Dans la fenêtre de démo :
    · en bas de la liste, « ⇄ partagés » : 3 profils de Léa et Marc
    · Entrée sur « Front — Léa » : le dossier « boutique » est proposé tout seul, Entrée pour valider
    · « Duo comptes — Marc » : ses comptes inconnus chez toi passent sur ton compte par défaut
    · D sur un partagé : ta copie modifiable · P sur un de tes profils : publication (choix de la bibliothèque)
    · dans ~45 s Marc publie « Revue de code — Marc » dans le dépôt : appuie sur R pour le voir arriver
    · B : gérer les bibliothèques · Q pour quitter
  Nettoyage : psmux -L flowshare kill-server
"@
