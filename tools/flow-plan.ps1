<#
  flow-plan.ps1 — dépose un plan de tâches dans la fenêtre Équipe de FLOW.

  Un Claude (skill « taches-repartir ») ou toi écrivez le découpage dans un fichier JSON ; ce script le
  vérifie, crée l'équipe « en attente » dans <dépôt>\.flow\runs\<id>\ et ouvre la fenêtre Équipe : il ne
  reste qu'à relire le plan (comptes, modèles) et à lancer. Rien n'est lancé sans cette validation.

    pwsh -File flow-plan.ps1 -Plan plan.json                 # dépôt = dossier courant
    pwsh -File flow-plan.ps1 -Repo C:\projet -Plan plan.json -NoOpen

  Forme du plan :
    { "request": "la demande d'origine", "summary": "…", "commitTitle": "…", "brief": "contexte commun (Markdown)",
      "tasks": [ { "id": "A", "title": "…", "goal": "…", "files": ["…"], "depends": [], "done": "…",
                   "model": "haiku | sonnet | opus", "why": "…" } ] }
#>
param(
    [string]$Repo = (Get-Location).Path,
    [Parameter(Mandatory)][string]$Plan,
    [string]$Sock = 'flow',
    [switch]$NoOpen
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'flow-common.ps1')
. (Join-Path $PSScriptRoot 'flow-deps.ps1')
function Fail([string]$m) { Write-Host "ERREUR : $m"; exit 1 }

$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { $git = @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1 }
if (-not $git) { Fail (Get-DepMissingText 'git') }
$top = (& $git -C $Repo rev-parse --show-toplevel 2>$null | Select-Object -First 1)
if (-not $top) { Fail "ce dossier n'est pas un dépôt Git : $Repo (git init, puis un premier commit)." }
$root = [IO.Path]::GetFullPath($top.Trim())
$head = (& $git -C $root rev-parse --verify -q HEAD 2>$null | Select-Object -First 1)
if (-not $head) { Fail "le dépôt n'a encore aucun commit : les ouvriers partent du dernier commit." }

try { $p = Get-Content -LiteralPath $Plan -Raw -Encoding utf8 | ConvertFrom-Json } catch { Fail "plan illisible ($Plan) : $($_.Exception.Message)" }
$in = @($p.tasks)
if (-not $in.Count) { Fail 'le plan ne contient aucune tâche ("tasks").' }
if ($in.Count -gt 8) { Fail "trop de tâches ($($in.Count)) : 8 au plus — regroupe les plus petites." }

# profil du projet (s'il existe) : préfixe des branches, mode de livraison, branche cible
$cfg = $null
try { $cfg = Get-Content -LiteralPath (Join-Path $root '.flow\config.json') -Raw -Encoding utf8 | ConvertFrom-Json } catch {}
$baseRef = if ($cfg.targetBranch) { [string]$cfg.targetBranch } else { 'HEAD' }
$base = (& $git -C $root rev-parse --verify -q $baseRef 2>$null | Select-Object -First 1)
if (-not $base) { Fail "branche cible introuvable : $baseRef (.flow\config.json)." }
$baseBranch = if ($cfg.targetBranch) { [string]$cfg.targetBranch } else { (& $git -C $root rev-parse --abbrev-ref HEAD | Select-Object -First 1).Trim() }

$letters = 'ABCDEFGH'; $tasks = @(); $i = 0; $warn = @()
foreach ($t in $in) {
    $id = ([string]$t.id -replace '[^A-Za-z0-9_-]', '')
    if (-not $id -or ($tasks | Where-Object { $_.id -eq $id })) { $id = [string]$letters[$i] }
    if (-not "$($t.title)".Trim() -or -not "$($t.goal)".Trim()) { Fail "tâche $id : « title » et « goal » sont obligatoires." }
    $model = "$($t.model)".ToLower().Trim()
    if ($model -notin 'haiku', 'sonnet', 'opus') { $model = 'sonnet' }
    $tasks += [pscustomobject]@{
        id = $id; title = [string]$t.title; goal = [string]$t.goal; done = [string]$t.done
        files = @(@($t.files) | Where-Object { $_ } | ForEach-Object { ([string]$_) -replace '\\', '/' })
        depends = @(@($t.depends) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        model = $model; why = [string]$t.why
        account = ''; status = 'pending'; worktree = ''; error = ''; live = ''; startedAt = ''; doneAt = ''
        advisor = ''; advice = 0; helpSeen = ''
    }
    $i++
}
$ids = @($tasks.id)
foreach ($t in $tasks) {
    $unknown = @($t.depends | Where-Object { $_ -notin $ids -or $_ -eq $t.id })
    if ($unknown.Count) { Fail "tâche $($t.id) : dépendance inconnue ($($unknown -join ', '))." }
}
# dépendances en boucle : aucune tâche ne pourrait démarrer
$left = @($tasks); $doneIds = @()
while ($left.Count) {
    $ready = @($left | Where-Object { -not @($_.depends | Where-Object { $_ -notin $doneIds }).Count })
    if (-not $ready.Count) { Fail "dépendances en boucle entre : $(($left.id) -join ', ')." }
    $doneIds += $ready.id; $left = @($left | Where-Object { $_.id -notin $ready.id })
}
# un même fichier dans deux tâches indépendantes : conflit probable à la fusion
function All-Deps($t) { $acc = @(); $todo = @($t.depends); while ($todo.Count) { $d = $todo[0]; $todo = @($todo | Select-Object -Skip 1); if ($d -notin $acc) { $acc += $d; $todo += @(($tasks | Where-Object { $_.id -eq $d }).depends) } }; $acc }
for ($a = 0; $a -lt $tasks.Count; $a++) {
    for ($b = $a + 1; $b -lt $tasks.Count; $b++) {
        $x = $tasks[$a]; $y = $tasks[$b]
        if ($x.id -in (All-Deps $y) -or $y.id -in (All-Deps $x)) { continue }
        $shared = @($x.files | Where-Object { $f = $_; @($y.files | Where-Object { $_ -ieq $f }).Count })
        if ($shared.Count) { $warn += "tâches $($x.id) et $($y.id) : même fichier ($($shared -join ', ')) sans dépendance entre elles — risque de conflit" }
    }
}

$id = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $root ".flow\runs\$id"
New-Item -ItemType Directory -Force $runDir | Out-Null
$request = if ("$($p.request)".Trim()) { [string]$p.request } else { [string]$p.summary }
$state = [pscustomobject]@{
    id = $id; created = (Get-Date).ToString('o'); updated = (Get-Date).ToString('o'); status = 'planned'; prompt = $request
    base = $base.Trim(); baseBranch = $baseBranch
    prefix = $(if ($cfg.branchPrefix) { [string]$cfg.branchPrefix } else { 'flow/' }); deliver = [string]$cfg.deliver
    commitTitle = [string]$p.commitTitle
    summary = $(if ("$($p.summary)".Trim()) { [string]$p.summary } else { ($request -split "`n")[0] })
    brief = [string]$p.brief; planner = 'skill'; tasks = @($tasks)
    integration = [pscustomobject]@{ merged = @(); skipped = @(); conflict = ''; tests = $null; checks = @(); delivered = '' }
}
Set-Content -LiteralPath (Join-Path $runDir 'demande.md') $request -Encoding utf8
Write-JsonAtomic $state (Join-Path $runDir 'state.json') -Depth 12

Write-Host "Plan déposé : $($tasks.Count) tâche(s) — équipe $id"
foreach ($t in $tasks) { Write-Host ("  {0}  [{1}]  {2}{3}" -f $t.id, $t.model, $t.title, $(if ($t.depends.Count) { "  (après $($t.depends -join ', '))" } else { '' })) }
foreach ($w in $warn) { Write-Host "ATTENTION : $w" }
$dirty = @(& $git -C $root status --porcelain | Where-Object { $_ -and $_ -notmatch '^\S*\s+"?\.flow/' })
if ($dirty.Count -and $baseRef -eq 'HEAD') { Write-Host "ATTENTION : $($dirty.Count) fichier(s) modifié(s) non commité(s) : les ouvriers partent du dernier commit et ne les verront pas." }

$inMux = @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(TMUX|PSMUX)' }).Count -gt 0
if (-not $NoOpen -and $inMux -and (Get-Command psmux -ErrorAction SilentlyContinue)) {
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'flow-pane.ps1') -Sock $Sock -Team
    Write-Host "Fenêtre Équipe ouverte (fenêtre « dispatch » de la session). L'utilisateur y choisit le plan (F6 si l'écran de demande est affiché), vérifie comptes et modèles, puis Entrée pour lancer."
} else {
    Write-Host "Pour le lancer : dans une session FLOW, Ctrl+B puis T (fenêtre Équipe) ; ou  pwsh -File `"$(Join-Path (Split-Path $PSScriptRoot -Parent) 'FLOW.ps1')`" -Team `"$root`""
}
