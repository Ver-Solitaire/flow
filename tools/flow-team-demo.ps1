<#
  flow-team-demo.ps1 — simulation de la fenêtre Équipe (aucun vrai Claude, aucun vrai compte).

    pwsh -File flow-team-demo.ps1          prépare la simulation et l'ouvre dans une nouvelle fenêtre
    psmux -L flowteamdemo kill-server      l'arrête

  Tout se passe dans %TEMP%\flow-equipe-demo : un petit dépôt Git (« boutique »), deux comptes factices,
  et un faux « claude » qui joue le planificateur, les ouvriers (qui codent, commitent, et dont l'un
  appelle son conseiller) et le conseiller. La fenêtre Équipe, le moniteur et le Bureau sont les vrais.
#>
param([string]$Root = (Join-Path $env:TEMP 'flow-equipe-demo'), [switch]$NoWindow)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Sock = 'flowteamdemo'; $Sess = 'equipe'
$Tools = $PSScriptRoot
$Flow = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Q([string]$s) { "'" + ($s -replace "'", "''") + "'" }
function Key([string]$p) { ([IO.Path]::GetFullPath($p).TrimEnd('\', '/')) -replace '[^a-zA-Z0-9]', '-' }

. (Join-Path $PSScriptRoot 'flow-deps.ps1')
$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { foreach ($c in "$env:ProgramFiles\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe") { if (Test-Path $c) { $git = $c; break } } }
if (-not $git) { Write-Host (Get-DepMissingText 'git') -ForegroundColor Red; return }
if (-not (Get-Command psmux -ErrorAction SilentlyContinue)) { Write-Host (Get-DepMissingText 'psmux') -ForegroundColor Red; return }

# ───────────────────────── préparation ─────────────────────────
& psmux -L $Sock kill-server *> $null
if ((Test-Path -LiteralPath $Root) -and ($Root -like "$env:TEMP*")) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
$Proj = Join-Path $Root 'boutique'
$AccA = Join-Path $Root 'compte1'; $AccB = Join-Path $Root 'compte2'
$Fake = Join-Path $Root 'fakebin'
New-Item -ItemType Directory -Force $Proj, (Join-Path $Proj 'src'), $AccA, $AccB, $Fake | Out-Null

# petit projet de démonstration
Set-Content (Join-Path $Proj 'README.md') "# Boutique (projet de démonstration FLOW)`n`nUne petite boutique en ligne : catalogue, panier, commandes." -Encoding utf8
Set-Content (Join-Path $Proj 'src\catalogue.js') "// catalogue des produits`nexport const produits = [{ id: 1, nom: 'Tasse', prix: 12 }, { id: 2, nom: 'Carnet', prix: 8 }];" -Encoding utf8
Set-Content (Join-Path $Proj 'src\panier.js') "// panier`nexport function total(lignes) { return lignes.reduce((s, l) => s + l.prix * l.qte, 0); }" -Encoding utf8
Set-Content (Join-Path $Proj 'CLAUDE.md') "# Règles du projet`n- JavaScript moderne (modules ES).`n- Un test pour chaque fonction publique." -Encoding utf8
$gid = @('-c', 'user.name=Demo', '-c', 'user.email=demo@flow')
& $git -C $Proj init -q -b main; & $git @gid -C $Proj add -A; & $git @gid -C $Proj commit -q -m 'feat: boutique de départ'
& $git @gid -C $Proj commit -q --allow-empty -m 'docs: règles du projet'
# profil du projet déjà prêt (sinon il est détecté au premier passage)
New-Item -ItemType Directory -Force (Join-Path $Proj '.flow') | Out-Null
@'
{ "version": 1, "setup": null, "copyFiles": [],
  "checks": [ { "name": "tests", "cmd": "Write-Output 'node --test : 7 tests OK'" }, { "name": "lint", "cmd": "Write-Output 'eslint : 0 erreur'" } ],
  "branchPrefix": "flow/", "commitStyle": "conventional", "deliver": "merge", "targetBranch": null,
  "commitExamples": ["docs: règles du projet", "feat: boutique de départ"],
  "instructions": "- JavaScript moderne (modules ES).\n- Un test pour chaque fonction publique.", "detected": ["démo"] }
'@ | Set-Content (Join-Path $Proj '.flow\config.json') -Encoding utf8

# comptes factices (connectés, avec des limites)
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
foreach ($x in @(@($AccA, 34, 12), @($AccB, 18, 6))) {
    '{}' | Set-Content (Join-Path $x[0] '.credentials.json')
    @{ updated = $now; rate_limits = @{ seven_day = @{ used_percentage = $x[1]; resets_at = $now + 300000 }; five_hour = @{ used_percentage = $x[2]; resets_at = $now + 12000 } } } |
        ConvertTo-Json -Depth 5 -Compress | Set-Content (Join-Path $x[0] 'monitor-status.json')
}

# ───────────────────────── faux « claude » ─────────────────────────
'@pwsh -NoProfile -File "%~dp0fakeclaude.ps1" %*' | Set-Content (Join-Path $Fake 'claude.cmd') -Encoding ascii
@'
# Faux Claude de la simulation Équipe : planificateur / conseiller (-p) ou ouvrier (interactif)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$isP = $args -contains '-p'
$msg = if ($isP) { $args[[array]::IndexOf($args, '-p') + 1] } else { $args[-1] }
$model = if ($args -contains '--model') { $args[[array]::IndexOf($args, '--model') + 1] } else { 'sonnet' }
$pf = [regex]::Match([string]$msg, 'Lis le fichier (.+?) et suis').Groups[1].Value
$p = if ($pf -and (Test-Path -LiteralPath $pf)) { Get-Content -LiteralPath $pf -Raw } else { '' }

if ($isP) {
    if ($p -match 'PLANIFICATEUR') {
        # historique du planificateur (visible dans le moniteur et le Bureau pendant qu'il travaille)
        $home_ = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
        $tf = Join-Path $home_ ("projects\" + (([IO.Path]::GetFullPath((Get-Location).Path).TrimEnd('\')) -replace '[^a-zA-Z0-9]', '-') + "\$([guid]::NewGuid()).jsonl")
        New-Item -ItemType Directory -Force (Split-Path $tf) | Out-Null
        $ts = { (Get-Date).ToUniversalTime().ToString('o') }
        $put = { param($o) Add-Content -LiteralPath $tf ($o | ConvertTo-Json -Depth 10 -Compress) -Encoding utf8 }
        $usage = @{ input_tokens = 10; cache_read_input_tokens = 22000; cache_creation_input_tokens = 800; output_tokens = 300 }
        & $put @{ type = 'user'; timestamp = (& $ts); message = @{ role = 'user'; content = 'Découpe la demande de l''utilisateur en tâches pour l''équipe.' } }
        foreach ($stp in @(
                @{ say = 'Je repère les fichiers du projet pour savoir où intervenir.'; name = 'Glob'; inp = @{ pattern = 'src/**/*.js' } }
                @{ say = 'Je lis le panier : les prix y sont des nombres simples.'; name = 'Read'; inp = @{ file_path = 'src/panier.js' } }
                @{ say = 'Trois tâches : modèle, logique (délicate → opus), doc (simple → haiku).'; name = 'Read'; inp = @{ file_path = 'CLAUDE.md' } })) {
            & $put @{ type = 'assistant'; timestamp = (& $ts); message = @{ id = "m$(Get-Random)"; model = 'claude-opus-5-5'; usage = $usage; content = @(@{ type = 'text'; text = $stp.say }, @{ type = 'tool_use'; id = "t$(Get-Random)"; name = $stp.name; input = $stp.inp }); stop_reason = 'tool_use' } }
            Start-Sleep -Milliseconds 1700
        }
        & $put @{ type = 'assistant'; timestamp = (& $ts); message = @{ id = "m$(Get-Random)"; model = 'claude-opus-5-5'; usage = $usage; content = @(@{ type = 'text'; text = 'Plan prêt : 3 tâches, deux en parallèle.' }); stop_reason = 'end_turn' } }
        $req = ([regex]::Match($p, '(?s)<<<\s*(.*?)\s*>>>').Groups[1].Value -replace '\s+', ' ').Trim()
        if (-not $req) { $req = 'améliorer la boutique' }
        $short = if ($req.Length -gt 60) { $req.Substring(0, 60) + '…' } else { $req }
        $plan = [ordered]@{
            summary = $short
            commitTitle = "feat: $($short.ToLower())"
            brief = "## Objectif`n$req`n`n## Contexte`nBoutique en JavaScript (modules ES) : src/catalogue.js, src/panier.js.`n`n## Décisions communes`n- Les prix sont en centimes (entiers).`n- Chaque module exporte des fonctions pures, testées."
            tasks = @(
                [ordered]@{ id = 'A'; title = 'modèle de données'; goal = "Définir les structures nécessaires pour : $req"; files = @('src/modele.js'); depends = @(); done = 'modele.js exporte les structures, testées'; model = 'sonnet'; why = 'tâche standard, bien délimitée' }
                [ordered]@{ id = 'B'; title = 'logique métier'; goal = "Écrire la logique principale pour : $req (calculs, règles, cas limites)"; files = @('src/logique.js'); depends = @(); done = 'logique.js couvre les cas limites, testé'; model = 'opus'; why = 'règles délicates et cas limites' }
                [ordered]@{ id = 'C'; title = 'documentation'; goal = 'Documenter la nouvelle fonctionnalité dans le README'; files = @('README.md'); depends = @('A'); done = 'README à jour'; model = 'haiku'; why = 'simple et mécanique' }
            )
        }
        @{ type = 'result'; is_error = $false; result = ($plan | ConvertTo-Json -Depth 6 -Compress) } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
    } elseif ($p -match 'CONSEILLER') {
        Start-Sleep -Seconds 7
        $advice = "## Diagnostic`nTu mélanges le calcul des remises et celui des taxes : les arrondis s'accumulent.`n`n## Plan`n1. Travaille en centimes (entiers) partout, comme le dit le brief.`n2. Applique d'abord les remises, puis les taxes, puis arrondis une seule fois.`n3. Ajoute un test pour une remise de 100 % et un panier vide.`n`n## Pièges`n- Ne modifie pas src/panier.js : il appartient à une autre tâche."
        @{ type = 'result'; is_error = $false; result = $advice } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
    } else {
        @{ type = 'result'; is_error = $false; result = '{ "instructions": "- JavaScript moderne (modules ES).\n- Un test pour chaque fonction publique." }' } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
    }
    exit 0
}

# ───────── ouvrier (session interactive simulée) ─────────
$e = [char]27; $R = "$e[0m"
function Col($c) { "$e[38;2;$($c[0]);$($c[1]);$($c[2])m" }
$home_ = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$cwd = (Get-Location).Path
$tf = Join-Path $home_ ("projects\" + (([IO.Path]::GetFullPath($cwd).TrimEnd('\')) -replace '[^a-zA-Z0-9]', '-') + "\$([guid]::NewGuid()).jsonl")
New-Item -ItemType Directory -Force (Split-Path $tf) | Out-Null
$ctx = 15000
function Now { (Get-Date).ToUniversalTime().ToString('o') }
function Put($o) { Add-Content -LiteralPath $tf ($o | ConvertTo-Json -Depth 10 -Compress) -Encoding utf8 }
function U($text) { Put @{ type = 'user'; timestamp = (Now); message = @{ role = 'user'; content = $text } }; Write-Host "`n$(Col @(255,210,110))❯ $text$R" }
function A($content, $stop) { $script:ctx += Get-Random -Min 2000 -Max 6000; Put @{ type = 'assistant'; timestamp = (Now); message = @{ id = "m$(Get-Random)"; model = "claude-$model-5-5"; usage = @{ input_tokens = 10; cache_read_input_tokens = $ctx; cache_creation_input_tokens = 500; output_tokens = 200 }; content = @($content); stop_reason = $stop } } }
function Think($t) { A @{ type = 'thinking'; thinking = $t } $null; Write-Host "$(Col @(190,160,255))✻ $t$R" }
function Tool($name, $inp, $say) {
    $id = "t$(Get-Random)"
    $c = @(); if ($say) { $c += @{ type = 'text'; text = $say }; Write-Host "$(Col @(225,225,240))● $say$R" }
    $c += @{ type = 'tool_use'; id = $id; name = $name; input = $inp }
    A $c 'tool_use'
    $arg = foreach ($k in 'file_path', 'pattern', 'command', 'query') { if ($inp.$k) { $inp.$k; break } }
    Write-Host "$(Col @(120,230,140))●$R $name($arg)"
    Start-Sleep -Milliseconds 2600
    Put @{ type = 'user'; timestamp = (Now); message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = $id; content = 'ok' }) } }
    Write-Host "$e[2m  ⎿ ok$R"
}
function Say($t) { A @{ type = 'text'; text = $t } 'end_turn'; Write-Host "$(Col @(255,138,92))●$R $t" }

Clear-Host
Write-Host "$(Col @(255,138,92))✻ Claude ($model) — ouvrier simulé$R"
Write-Host "$e[2m  simulation FLOW : aucune vraie IA, mais de vrais fichiers et de vrais commits dans la copie$R"
if ($args -contains '--continue') { Write-Host "`n(conversation reprise)"; while ($true) { $l = Read-Host; if ($l) { U $l; Say "Bien reçu (simulation)." } } }

if (-not $p) {
    # Claude général (le panneau « ✦ claude » du profil Équipe) : on lui parle directement
    Write-Host "`n$e[2m  Écris-lui ce que tu veux (Entrée pour envoyer). Pour une demande à découper en tâches,$R"
    Write-Host "$e[2m  utilise plutôt la fenêtre Équipe à gauche.$R`n"
    while ($true) {
        $l = Read-Host '❯'
        if (-not $l) { continue }
        Put @{ type = 'user'; timestamp = (Now); message = @{ role = 'user'; content = $l } }
        Think "L'utilisateur demande : « $l ». Je regarde d'abord le projet."
        Tool 'Grep' @{ pattern = (($l -split '\s+') | Sort-Object Length -Descending | Select-Object -First 1) } 'Je cherche ce qui s''y rapporte dans le code.'
        Tool 'Read' @{ file_path = 'src/panier.js' } 'Je lis le panier pour répondre précisément.'
        Say "(simulation) Voici ce que je ferais : modifier src/panier.js et ajouter un test. Pour un travail en plusieurs parties, la fenêtre Équipe le découpera et le répartira sur les comptes."
    }
}

$id = [regex]::Match($p, 'tâche (\w+) —').Groups[1].Value
$title = [regex]::Match($p, 'tâche \w+ — ([^\r\n]+)').Groups[1].Value.Trim()
$res = [regex]::Match($p, 'compte-rendu dans (\S+\.md)').Groups[1].Value
$help = [regex]::Match($p, 'question dans (\S+\.md)').Groups[1].Value
$adv = [regex]::Match($p, 'répond dans (\S+\.md)').Groups[1].Value
$fiche = [regex]::Match($p, 'Lis ta fiche : (\S+\.md)').Groups[1].Value
$brief = [regex]::Match($p, 'Lis le brief commun : (\S+\.md)').Groups[1].Value
$file = if (Test-Path -LiteralPath $fiche) { ([regex]::Match((Get-Content -LiteralPath $fiche -Raw), '(?m)^- ([^\s(]+\.\w+)')).Groups[1].Value } else { '' }
if (-not $file) { $file = "src/tache-$($id.ToLower()).js" }

U "Lis ta fiche et réalise la tâche $id — $title."
Think 'Je commence par le brief commun et ma fiche, pour savoir exactement ce qui m''est attribué.'
Tool 'Read' @{ file_path = $brief } 'Je lis le brief : objectif, décisions communes (prix en centimes).'
Tool 'Read' @{ file_path = $fiche } "Ma fiche : je ne touche qu'à $file."
Tool 'Grep' @{ pattern = 'export function' } 'Je regarde comment le code existant est organisé.'
Tool 'Read' @{ file_path = 'src/panier.js' } 'panier.js calcule le total : je dois rester compatible avec lui.'

if ($id -eq 'B') {
    # cette tâche se complique : l'ouvrier écrit sa question et attend son conseiller
    Think 'Les remises et les taxes donnent des arrondis différents selon l''ordre… je tourne en rond.'
    Set-Content -LiteralPath $help "Je bloque sur l'ordre remises / taxes : les arrondis ne tombent jamais juste. Quel ordre et quelle précision utiliser ?" -Encoding utf8
    Say 'Cette partie est plus complexe que prévu : j''ai écrit ma question, j''attends mon conseiller.'
    Write-Host "$e[2m  (en attente du conseiller… il répond dans $adv)$R"
    for ($w = 0; $w -lt 90 -and -not (Test-Path -LiteralPath $adv); $w++) { Start-Sleep -Seconds 1 }
    U '[FLOW] Ton conseiller a répondu : lis son conseil et applique son plan.'
    Tool 'Read' @{ file_path = $adv } 'Le conseiller dit : tout en centimes, remises puis taxes, un seul arrondi.'
}

$target = Join-Path $cwd $file
New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
if ($file -like '*.md') {
    Tool 'Edit' @{ file_path = $file } 'J''ajoute une section qui explique la nouvelle fonctionnalité.'
    Add-Content -LiteralPath $target "`n## Nouveauté`n$title : voir src/. (écrit par l'ouvrier $id)" -Encoding utf8
} else {
    Tool 'Write' @{ file_path = $file } "J'écris $file, en fonctions pures exportées."
    Set-Content -LiteralPath $target "// $title (ouvrier $id, modèle $model)`nexport function $($id.ToLower())Principal(entree) {`n  // prix en centimes, un seul arrondi`n  return entree;`n}" -Encoding utf8
    Tool 'Write' @{ file_path = ($file -replace '^src/', 'tests/' -replace '\.js$', '.test.js') } 'J''ajoute les tests, dont les cas limites.'
    $tt = Join-Path $cwd ($file -replace '^src/', 'tests/' -replace '\.js$', '.test.js')
    New-Item -ItemType Directory -Force (Split-Path $tt) | Out-Null
    Set-Content -LiteralPath $tt "// tests de $file`nimport { $($id.ToLower())Principal } from '../$file';" -Encoding utf8
}
Tool 'PowerShell' @{ command = 'node --test' } 'Je lance les tests du projet.'
Tool 'PowerShell' @{ command = "git commit -m `"feat: $title`"" } 'Tout passe : je commite sur ma branche.'
git add -A 2>$null | Out-Null
git commit -q -m "feat: $title" 2>$null | Out-Null
Set-Content -LiteralPath $res "Tâche $id ($model) : $title — $file créé$(if ($id -ne 'C') { ' avec ses tests' }). Prix en centimes, un seul arrondi.$(if ($id -eq 'B') { ' Débloquée grâce au conseiller.' })" -Encoding utf8
Say "Fini : $title. Compte-rendu écrit, commit fait."

# ensuite : comme un vrai Claude, on peut lui écrire (touche M dans le Bureau ou le tableau de bord)
while ($true) { $l = Read-Host; if ($l) { U $l; Say 'Bien reçu (simulation) : dans une vraie session, j''en tiendrais compte.' } }
'@ | Set-Content (Join-Path $Fake 'fakeclaude.ps1') -Encoding utf8

# ───────────────────────── session psmux ─────────────────────────
# le serveur et ses panneaux héritent de ce PATH : « claude » = le faux claude, « git » disponible
$env:PATH = "$Fake;$(Split-Path $git);$env:PATH"
Get-ChildItem Env: | Where-Object Name -match '^(TMUX|PSMUX|NO_COLOR$)' | Remove-Item -ErrorAction SilentlyContinue
$Watch = "Compte 1|ff8a5c|$AccA|$Proj|principal|C1;Compte 2|54baff|$AccB|$Proj|second|C2"
$Accs = "principal|Compte 1|ff8a5c|$AccA|C1;second|Compte 2|54baff|$AccB|C2"
$cmds = @(
    "pwsh -NoProfile -File $(Q (Join-Path $Tools 'flow-team.ps1')) -Repo $(Q $Proj) -Sock $Sock -Session $Sess -Accounts $(Q $Accs) -MaxTasks 3"
    "`$env:CLAUDE_CONFIG_DIR = $(Q $AccA); claude"
    "pwsh -NoProfile -File $(Q (Join-Path $Tools 'claude-monitor.ps1')) -Latest -Watch $(Q $Watch) -Sock $Sock -Session $Sess -NotifyAfter -1"
    "pwsh -NoProfile -File $(Q (Join-Path $Tools 'flow-office.ps1')) -Watch $(Q $Watch) -Sock $Sock -Session $Sess"
)
# disposition du profil Équipe : équipe | claude général | moniteur  /  Bureau
& psmux -L $Sock -f (Join-Path $Flow 'config\psmux.conf') new-session -d -s $Sess -n dispatch -x 220 -y 56 -c $Proj *> $null
Start-Sleep -Milliseconds 600
& psmux -L $Sock split-window -v -p 34 -t "${Sess}:.0" -c $Proj *> $null; Start-Sleep -Milliseconds 300
& psmux -L $Sock split-window -h -p 62 -t "${Sess}:.0" -c $Proj *> $null; Start-Sleep -Milliseconds 300
& psmux -L $Sock split-window -h -p 40 -t "${Sess}:.1" -c $Proj *> $null; Start-Sleep -Milliseconds 300
$titles = @('⚑ équipe — prompt à découper en tâches', '✦ claude · Compte 1 — prompt général', '◉ moniteur · tous les comptes', '⌂ bureau')
for ($i = 0; $i -lt 4; $i++) {
    & psmux -L $Sock set -p -t "${Sess}:.$i" '@flow_role' $titles[$i] *> $null
    & psmux -L $Sock set -p -t "${Sess}:.$i" '@flow_base' $titles[$i] *> $null
}
& psmux -L $Sock set -p -t "${Sess}:.1" '@flow_acct' 'principal' *> $null   # le moniteur y affiche l'état de Claude
Start-Sleep -Milliseconds 1500
for ($i = 0; $i -lt 4; $i++) {
    & psmux -L $Sock send-keys -t "${Sess}:.$i" -l "Clear-Host; $($cmds[$i])" *> $null
    & psmux -L $Sock send-keys -t "${Sess}:.$i" Enter *> $null
}
& psmux -L $Sock select-pane -t "${Sess}:.0" *> $null

if (-not $NoWindow) {
    $att = "Get-ChildItem Env: | Where-Object Name -match '^(TMUX|PSMUX|NO_COLOR$)' | Remove-Item; `$env:COLORTERM = 'truecolor'; psmux -L $Sock attach -t $Sess"
    Start-Process pwsh -ArgumentList @('-NoProfile', '-Command', $att) -WindowStyle Maximized
}
"simulation prête : projet $Proj — $(if ($NoWindow) { "psmux -L $Sock attach -t $Sess" } else { 'fenêtre « Équipe (simulation) » ouverte' }) — arrêt : psmux -L $Sock kill-server"
