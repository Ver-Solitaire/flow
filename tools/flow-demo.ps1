<#
  flow-demo.ps1 — démonstration de FLOW avec une activité simulée (aucun vrai Claude, aucun vrai compte).

    pwsh -File flow-demo.ps1            prépare la démo et l'ouvre dans une nouvelle fenêtre
    pwsh -File flow-demo.ps1 -NoWindow  prépare la démo sans ouvrir de fenêtre (psmux -L flowdemo attach -t demo)
    psmux -L flowdemo kill-server       arrête la démo

  Un simulateur écrit en continu de faux historiques Claude (dans %TEMP%\flow-demo) ; le vrai moniteur et
  le vrai Bureau de FLOW les lisent comme s'il s'agissait de vraies sessions :
    Compte 1 : lit, cherche, lance 3 sous-agents (explorateur, testeur, relecteur), modifie, teste
    Compte 2 : recherche web, lance un workflow d'audit (4 agents), écrit un rapport
    Équipe   : 3 tâches (A et B en parallèle, C attend A), puis intégration
#>
param(
    [switch]$Simulate,
    [string]$Show,
    [switch]$NoWindow,
    [string]$Root = (Join-Path $env:TEMP 'flow-demo'),
    [double]$Step = 2.0
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Sock = 'flowdemo'; $Sess = 'demo'
$Flow = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$esc = [char]27; $Rst = "$esc[0m"
function Col($c) { "$esc[38;2;$($c[0]);$($c[1]);$($c[2])m" }

function Key([string]$p) { ([IO.Path]::GetFullPath($p).TrimEnd('\', '/')) -replace '[^a-zA-Z0-9]', '-' }
$AccA = Join-Path $Root 'compte1'; $AccB = Join-Path $Root 'compte2'
$Proj = Join-Path $Root 'projet'
$SidA = 'aaaaaaaa-0000-4000-8000-00000000000a'; $SidB = 'bbbbbbbb-0000-4000-8000-00000000000b'
$FA = Join-Path $AccA "projects\$(Key $Proj)\$SidA.jsonl"
$FB = Join-Path $AccB "projects\$(Key $Proj)\$SidB.jsonl"
$SubDir = Join-Path $AccA "projects\$(Key $Proj)\$SidA\subagents"
$SubDirB = Join-Path $AccB "projects\$(Key $Proj)\$SidB\subagents"   # agents du workflow lancé par Compte 2
$RunDir = Join-Path $Proj '.flow\runs\demo'
$WtRoot = Join-Path $Root 'projet-flow\demo'
$Watch = "Compte 1|ff8a5c|$AccA|$Proj|principal|C1;Compte 2|54baff|$AccB|$Proj|second|C2"

# ───────────────────────── écriture des faux historiques ─────────────────────────
$Ctx = @{}
function Now { (Get-Date).ToUniversalTime().ToString('o') }
function Put([string]$file, $obj) {
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    Add-Content -LiteralPath $file ($obj | ConvertTo-Json -Depth 12 -Compress) -Encoding utf8
}
function Usage([string]$file) {
    if (-not $Ctx.ContainsKey($file)) { $Ctx[$file] = 18000 }
    $Ctx[$file] += Get-Random -Minimum 1500 -Maximum 6000
    @{ input_tokens = 12; cache_read_input_tokens = $Ctx[$file]; cache_creation_input_tokens = 900; output_tokens = 240 }
}
function Ask([string]$file, [string]$text, [switch]$Side) { Put $file @{ type = 'user'; isSidechain = [bool]$Side; timestamp = (Now); message = @{ role = 'user'; content = $text } } }
function Think([string]$file, [string]$text = 'Je réfléchis à la meilleure approche.', [switch]$Side) {
    Put $file @{ type = 'assistant'; isSidechain = [bool]$Side; timestamp = (Now); message = @{ id = "m$(Get-Random)"; model = 'claude-opus-5-5'; usage = (Usage $file); content = @(@{ type = 'thinking'; thinking = $text }); stop_reason = $null } }
}
function Tool([string]$file, [string]$name, $inp, [string]$Say, [switch]$Side) {
    # $Say : ce que Claude explique juste avant d'utiliser l'outil (affiché dans la bulle)
    $id = "t$(Get-Random)"
    $content = @()
    if ($Say) { $content += @{ type = 'text'; text = $Say } }
    $content += @{ type = 'tool_use'; id = $id; name = $name; input = $inp }
    Put $file @{ type = 'assistant'; isSidechain = [bool]$Side; timestamp = (Now); message = @{ id = "m$(Get-Random)"; model = 'claude-opus-5-5'; usage = (Usage $file); content = $content; stop_reason = 'tool_use' } }
    $id
}
function Tools([string]$file, $list) {
    # plusieurs appels dans le même message (ex. 3 agents lancés ensemble)
    $content = @(foreach ($x in $list) { @{ type = 'tool_use'; id = $x.id; name = $x.name; input = $x.input } })
    Put $file @{ type = 'assistant'; timestamp = (Now); message = @{ id = "m$(Get-Random)"; model = 'claude-opus-5-5'; usage = (Usage $file); content = $content; stop_reason = 'tool_use' } }
}
function Result([string]$file, $ids, [string]$text = 'ok', [switch]$Side) {
    $content = @(foreach ($i in @($ids)) { @{ type = 'tool_result'; tool_use_id = $i; content = $text } })
    Put $file @{ type = 'user'; isSidechain = [bool]$Side; timestamp = (Now); message = @{ role = 'user'; content = $content } }
}
function Say([string]$file, [string]$text) {
    Put $file @{ type = 'assistant'; timestamp = (Now); message = @{ id = "m$(Get-Random)"; model = 'claude-opus-5-5'; usage = (Usage $file); content = @(@{ type = 'text'; text = $text }); stop_reason = 'end_turn' } }
}

# ───────────────────────── préparation ─────────────────────────
function Setup {
    foreach ($a in $AccA, $AccB) {
        New-Item -ItemType Directory -Force (Join-Path $a "projects\$(Key $Proj)") | Out-Null
        '{}' | Set-Content -LiteralPath (Join-Path $a '.credentials.json')
    }
    New-Item -ItemType Directory -Force $Proj, $RunDir, $SubDir | Out-Null
    Set-Limits 86 41 12 5
}
function Set-Limits([double]$wa, [double]$ha, [double]$wb, [double]$hb) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($x in @(@($AccA, $wa, $ha, $SidA), @($AccB, $wb, $hb, $SidB))) {
        @{ updated = $now; session_id = $x[3]; ctx_sizes = @{ $x[3] = 200000 }
            rate_limits = @{ seven_day = @{ used_percentage = $x[1]; resets_at = $now + 160000 }; five_hour = @{ used_percentage = $x[2]; resets_at = $now + 9000 } } } |
            ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath (Join-Path $x[0] 'monitor-status.json') -Encoding utf8
    }
}

# ───────────────────────── équipe FLOW simulée ─────────────────────────
function Say-Help([string]$file) {
    Put $file @{ type = 'assistant'; timestamp = (Now); message = @{ id = "m$(Get-Random)"; model = 'claude-sonnet-5-5'; usage = (Usage $file)
        content = @(@{ type = 'text'; text = 'La migration casse 3 relations entre Client et Facture, je bloque : je demande l''aide de mon conseiller.' }); stop_reason = 'end_turn' } }
}
function Team-State([string]$status, $tasks) {
    @{ id = 'demo'; status = $status; summary = 'Espace client'; tasks = $tasks } | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $RunDir 'state.json') -Encoding utf8
}
function Task-File([string]$id, [string]$acc) {
    $wt = Join-Path $WtRoot $id
    New-Item -ItemType Directory -Force $wt | Out-Null
    $home_ = if ($acc -eq 'principal') { $AccA } else { $AccB }
    Join-Path $home_ "projects\$(Key $wt)\cccccccc-0000-4000-8000-00000000000$($id.ToLower()).jsonl"
}

# ───────────────────────── simulation ─────────────────────────
function Simulate {
    Setup
    # chaque outil : @(nom, paramètres, ce que l'agent explique juste avant — affiché dans sa bulle)
    $agents = @(
        @{ name = 'explorateur'; type = 'Explore'; prompt = 'Explore le module de facturation : liste les fonctions publiques et leurs appelants'
            tools = @(@('Glob', @{ pattern = 'src/**/*.ts' }, 'Je repère d''abord tous les fichiers TypeScript du projet.'),
                @('Grep', @{ pattern = 'export function' }, 'Je liste les fonctions exportées pour trouver l''API publique.'),
                @('Read', @{ file_path = 'src/facture.ts' }, 'calculerTotal est appelée à 4 endroits, je vérifie lesquels.'),
                @('Read', @{ file_path = 'src/client.ts' }, 'client.ts dépend aussi de la facturation, je regarde comment.')) }
        @{ name = 'testeur'; type = 'general-purpose'; prompt = 'Écris des tests unitaires pour calculerTotal et appliquerRemise'
            tools = @(@('Read', @{ file_path = 'src/facture.ts' }, 'Je lis calculerTotal pour couvrir tous ses cas limites.'),
                @('Write', @{ file_path = 'tests/facture.test.ts' }, 'J''écris un test pour une remise de 100 % : le total doit valoir 0.'),
                @('PowerShell', @{ command = 'npm test' }, 'Je lance les tests pour voir si les nouveaux cas passent.'),
                @('Edit', @{ file_path = 'tests/facture.test.ts' }, 'Un test échoue sur les arrondis, je compare en centimes.')) }
        @{ name = 'relecteur'; type = 'general-purpose'; prompt = 'Relis les changements et signale les risques'
            tools = @(@('Grep', @{ pattern = 'TODO' }, 'Je cherche les TODO laissés dans le code modifié.'),
                @('WebFetch', @{ url = 'https://docs.exemple.dev/arrondis' }, 'Je vérifie la règle d''arrondi recommandée pour les montants.'),
                @('Read', @{ file_path = 'src/remise.ts' }, 'appliquerRemise peut renvoyer un total négatif : à signaler.')) }
    )
    $teamTools = @{
        A = @(@('Read', @{ file_path = 'src/modeles/client.ts' }, 'Je regarde le modèle Client actuel avant de l''étendre.'),
            @('Grep', @{ pattern = 'interface Client' }, 'Je cherche qui utilise l''interface Client.'),
            @('Edit', @{ file_path = 'src/modeles/client.ts' }, 'J''ajoute les champs adresse et préférences au modèle.'),
            @('PowerShell', @{ command = 'npm run typecheck' }, 'Je vérifie que le typage passe partout.'))
        B = @(@('Write', @{ file_path = 'src/api/clients.ts' }, 'Je crée les routes GET et PUT /clients/:id.'),
            @('Read', @{ file_path = 'src/api/routes.ts' }, 'Je branche les nouvelles routes dans le routeur.'),
            @('PowerShell', @{ command = 'npm test -- api' }, 'Je teste l''API avant de rendre la main.'))
        C = @(@('Read', @{ file_path = 'src/ui/Profil.tsx' }, 'Le modèle de A est prêt, je lis la page Profil.'),
            @('Write', @{ file_path = 'src/ui/Profil.tsx' }, 'J''ajoute le formulaire d''adresse avec validation.'),
            @('WebSearch', @{ query = 'accessibilité formulaires' }, 'Je vérifie les bonnes pratiques d''accessibilité des formulaires.'),
            @('PowerShell', @{ command = 'npm run build' }, 'Je compile l''interface pour vérifier.'))
    }
    # workflow d'audit : 4 agents, chacun avec sa consigne (visible dans le script du workflow)
    $wfAgents = @(
        @{ label = 'audit:dépendances'; prompt = 'Vérifie les dépendances vulnérables du package.json'
            tools = @(@('Read', @{ file_path = 'package.json' }, 'Je relève les versions de chaque dépendance.'), @('WebSearch', @{ query = 'CVE express 4.18' }, 'express 4.18 a-t-il une faille connue ? Je vérifie.'), @('PowerShell', @{ command = 'npm audit --json' }, 'Je lance npm audit pour confirmer.')) }
        @{ label = 'audit:secrets'; prompt = 'Cherche des secrets ou clés d''API commités par erreur'
            tools = @(@('Grep', @{ pattern = 'API_KEY|SECRET|password' }, 'Je cherche des clés écrites en dur dans le code.'), @('Read', @{ file_path = 'src/config.ts' }, 'config.ts contient une URL avec mot de passe : suspect.'), @('Grep', @{ pattern = 'BEGIN PRIVATE KEY' }, 'Je vérifie qu''aucune clé privée n''a été commitée.')) }
        @{ label = 'audit:injections'; prompt = 'Cherche les risques d''injection SQL et XSS dans les routes'
            tools = @(@('Grep', @{ pattern = 'query\(' }, 'Je repère toutes les requêtes SQL construites à la main.'), @('Read', @{ file_path = 'src/api/recherche.ts' }, 'La recherche concatène l''entrée utilisateur : risque d''injection.'), @('Read', @{ file_path = 'src/ui/Commentaire.tsx' }, 'Je vérifie que les commentaires sont bien échappés.')) }
        @{ label = 'synthèse'; prompt = 'Rassemble les résultats des audits et classe les risques par gravité'
            tools = @(@('Read', @{ file_path = 'audit/dependances.md' }, 'J''attends les autres résultats, je prépare le plan du rapport.'), @('Write', @{ file_path = 'audit/synthese.md' }, 'Deux risques élevés : injection dans la recherche et secret dans config.ts.')) }
    )
    $cycle = 0
    $wfLabels = "export const meta = { name: 'audit-securite', description: 'audit' }`n" +
        (($wfAgents | ForEach-Object { 'agent(' + [char]96 + $_.prompt + [char]96 + ", {label: '$($_.label)'})" }) -join "`n")
    while ($true) {
        $cycle++
        $agentIds = @(); $subFiles = @(); $wfId = "wf_demo$($cycle)x7"; $script:wfFiles = @()
        $tf = @{ A = (Task-File 'A' 'principal'); B = (Task-File 'B' 'second'); C = (Task-File 'C' 'principal') }
        $ts = @{ A = 'running'; B = 'running'; C = 'pending' }
        for ($s = 0; $s -lt 30; $s++) {
            $log = @()
            # ── Compte 1 ──
            switch ($s) {
                0 { Ask $FA "Refactorise le module de facturation et ajoute des tests (tour $cycle)"; $log += 'C1 : nouvelle demande' }
                1 { Think $FA 'Avant de refactoriser, je dois comprendre comment le total est calculé et qui l''utilise.'; $log += 'C1 : réfléchit' }
                2 { $script:lastA = Tool $FA 'Read' @{ file_path = 'C:\projet\src\facture.ts' } -Say 'Je commence par lire facture.ts, le cœur du module.'; $log += 'C1 : lit facture.ts' }
                3 { Result $FA $lastA }
                4 { $script:lastA = Tool $FA 'Grep' @{ pattern = 'calculerTotal' } -Say 'calculerTotal mélange remises et taxes, je cherche ses appelants.'; $log += 'C1 : cherche' }
                5 { Result $FA $lastA }
                6 {
                    $list = @(); $k = 0
                    foreach ($ag in $agents) {
                        $id = "ag$cycle$k"; $agentIds += $id
                        $p = "$($ag.prompt) (tour $cycle)."
                        $list += @{ id = $id; name = 'Agent'; input = @{ name = $ag.name; description = $ag.name; subagent_type = $ag.type; prompt = $p } }
                        $sf = Join-Path $SubDir "agent-$cycle-$k.jsonl"; $subFiles += $sf
                        Ask $sf $p -Side
                        $k++
                    }
                    Tools $FA $list; $log += 'C1 : lance 3 sous-agents'
                }
                { $_ -ge 7 -and $_ -le 16 } {
                    for ($k = 0; $k -lt 3; $k++) {
                        $ag = $agents[$k]; $sf = $subFiles[$k]
                        if ((($s + $k) % 2) -eq 1) {
                            $tl = $ag.tools[[int][Math]::Floor(($s + $k) / 2) % $ag.tools.Count]
                            $script:subLast = Tool $sf $tl[0] $tl[1] -Say $tl[2] -Side
                            $log += "  $($ag.name) : $($tl[0])"
                        } else { Result $sf 'x' -Side }
                    }
                }
                17 { Result $FA $agentIds 'terminé'; $log += 'C1 : agents terminés' }
                18 { $script:lastA = Tool $FA 'Edit' @{ file_path = 'C:\projet\src\facture.ts' } -Say 'Les agents ont tout cartographié : je sépare le calcul des remises de celui des taxes.'; $log += 'C1 : écrit facture.ts' }
                19 { Result $FA $lastA }
                20 { $script:lastA = Tool $FA 'PowerShell' @{ command = 'npm test' } -Say 'Je relance toute la suite de tests pour vérifier que rien n''a cassé.'; $log += 'C1 : lance les tests' }
                21 { Result $FA $lastA '12 tests OK' }
                22 { Say $FA 'C''est fait : module refactorisé et 12 tests ajoutés.'; $log += 'C1 : a fini → à toi' }
            }
            # ── Compte 2 ──
            switch ($s) {
                1 { Ask $FB "Prépare une revue de sécurité complète du projet (tour $cycle)"; $log += 'C2 : nouvelle demande' }
                2 { Think $FB 'Une revue complète couvre dépendances, secrets et injections : ça se parallélise bien.' }
                3 { $script:lastB = Tool $FB 'WebSearch' @{ query = 'checklist sécurité API 2026' } -Say 'Je récupère une checklist à jour pour ne rien oublier.'; $log += 'C2 : web' }
                4 { Result $FB $lastB }
                5 { $script:lastB = Tool $FB 'Workflow' @{ script = $wfLabels } -Say 'Je lance 4 agents en parallèle, un par type de risque.'; $log += 'C2 : lance le workflow audit-securite' }
                6 {
                    Result $FB $lastB "Workflow lancé en arrière-plan : $wfId"
                    $script:wfFiles = @(for ($k = 0; $k -lt $wfAgents.Count; $k++) {
                            $wfile = Join-Path $SubDirB "wf-$cycle-$k.jsonl"
                            Ask $wfile $wfAgents[$k].prompt -Side
                            $wfile
                        })
                }
                7 { Say $FB 'J''ai lancé un workflow d''audit à 4 agents, je te préviens quand il est fini.' }
                20 { Ask $FB "<task-notification>workflow $wfId completed</task-notification>"; $log += 'C2 : workflow terminé' }
                21 { Think $FB 'Le workflow a trouvé 2 risques élevés, je les mets en tête du rapport.' }
                22 { $script:lastB = Tool $FB 'Write' @{ file_path = 'C:\projet\docs\audit.md' } -Say 'J''écris le rapport, avec un correctif proposé pour chaque risque.'; $log += 'C2 : écrit le rapport' }
                23 { Result $FB $lastB }
                24 { Say $FB 'Rapport d''audit écrit dans docs/audit.md.'; $log += 'C2 : a fini → à toi' }
            }
            # ── agents du workflow (pendant que Compte 2 attend) ──
            if ($s -ge 7 -and $s -le 19 -and $wfFiles) {
                for ($k = 0; $k -lt $wfAgents.Count; $k++) {
                    $wa = $wfAgents[$k]
                    if ((($s + $k) % 2) -eq 1) {
                        $tl = $wa.tools[[int][Math]::Floor(($s + $k) / 2) % $wa.tools.Count]
                        [void](Tool $wfFiles[$k] $tl[0] $tl[1] -Say $tl[2] -Side)
                    } else { Result $wfFiles[$k] 'x' -Side }
                }
                if ($s -eq 7) { $log += 'workflow : 4 agents au travail' }
            }
            # ── équipe FLOW ──
            if ($s -eq 7) { Say-Help $tf.A; $log += 'Équipe : A demande de l''aide → conseiller opus' }
            if ($s -eq 13) { Ask $tf.A '[FLOW] Ton conseiller (opus) a répondu : lis conseils/A.md et applique son plan.'; $log += 'Équipe : le conseiller a répondu à A' }
            if ($s -eq 11) { $ts.B = 'done'; $log += 'Équipe : B finie' }
            if ($s -eq 15) { $ts.A = 'done'; $ts.C = 'running'; $log += 'Équipe : A finie, C démarre' }
            if ($s -eq 25) { $ts.C = 'done'; $log += 'Équipe : C finie' }
            foreach ($id in 'A', 'B', 'C') {
                if ($ts[$id] -ne 'running') { continue }
                if ($id -eq 'A' -and $s -ge 7 -and $s -le 12) { continue }   # A attend son conseiller
                $tl = $teamTools[$id][[int][Math]::Floor($s / 2) % $teamTools[$id].Count]
                if ($s % 2 -eq 0) { [void](Tool $tf[$id] $tl[0] $tl[1] -Say $tl[2]) } else { Result $tf[$id] 'x' }
            }
            $status = if ($s -ge 28) { 'review' } elseif ($s -ge 26) { 'integrating' } else { 'running' }
            Team-State $status @(
                @{ id = 'A'; title = 'modèle de données'; goal = 'Étendre le modèle Client (adresse, préférences)'; model = 'sonnet'; status = $ts.A; account = 'principal'; worktree = (Join-Path $WtRoot 'A'); depends = @(); advisor = $(if ($s -ge 8 -and $s -le 12) { 'running' } elseif ($s -gt 12) { 'done' } else { '' }); advisorModel = 'opus'; advice = $(if ($s -gt 12) { 1 } else { 0 }) }
                @{ id = 'B'; title = 'API REST'; goal = 'Créer les routes /clients'; model = 'haiku'; status = $ts.B; account = 'second'; worktree = (Join-Path $WtRoot 'B'); depends = @() }
                @{ id = 'C'; title = 'interface'; goal = 'Formulaire Profil avec adresse'; model = 'sonnet'; status = $ts.C; account = 'principal'; worktree = $(if ($ts.C -ne 'pending') { Join-Path $WtRoot 'C' } else { '' }); depends = @('A') }
            )
            # limites : le compte 1 se rapproche de sa limite de la semaine
            Set-Limits ([Math]::Min(97, 86 + $cycle + $s * 0.2)) (41 + $s) 12 (5 + $s * 0.3)

            Write-Host "$(Col @(96,232,196))tour $cycle · étape $($s + 1)/30$Rst  $($log -join ' · ')"
            Start-Sleep -Milliseconds ([int]($Step * 1000))
        }
    }
}

# ───────────────────────── faux écran Claude ─────────────────────────
function Show-Claude([string]$which) {
    $file = if ($which -eq 'A') { $FA } else { $FB }
    $name = if ($which -eq 'A') { 'Compte 1' } else { 'Compte 2' }
    $c = if ($which -eq 'A') { @(255, 138, 92) } else { @(84, 186, 255) }
    Clear-Host
    Write-Host "$(Col $c)✻ Claude (démo) — $name$Rst"
    Write-Host "$esc[2m  activité simulée : rien n'est vraiment exécuté$Rst`n"
    $pos = 0; $typed = ''
    while ($true) {
        # messages envoyés depuis le Bureau (touche M) : affichés comme dans un vrai Claude
        try {
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Enter') {
                    if ($typed.Trim()) {
                        Write-Host "`n$(Col @(255,210,110))❯ $typed$Rst"
                        Write-Host "$(Col $c)●$Rst (démo) Bien reçu. Dans une vraie session, Claude lirait ce message et en tiendrait compte."
                    }
                    $typed = ''
                } elseif ($k.Key -eq 'Backspace') { if ($typed.Length) { $typed = $typed.Substring(0, $typed.Length - 1) } }
                elseif (-not [char]::IsControl($k.KeyChar)) { $typed += $k.KeyChar }
            }
        } catch {}
        if (Test-Path -LiteralPath $file) {
            $all = [IO.File]::ReadAllLines($file)
            for (; $pos -lt $all.Count; $pos++) {
                $o = $null; try { $o = $all[$pos] | ConvertFrom-Json -Depth 20 } catch { continue }
                if ($o.isSidechain) { continue }
                if ($o.type -eq 'user') {
                    $ct = $o.message.content
                    if ($ct -is [string]) {
                        if ($ct -match 'task-notification') { Write-Host "$(Col @(96,232,196))⚑ le workflow est terminé$Rst" }
                        else { Write-Host "`n$(Col @(255,210,110))❯ $ct$Rst" }
                    } else { Write-Host "$esc[2m  ⎿ $((@($ct)[0]).content)$Rst" }
                } else {
                    foreach ($x in @($o.message.content)) {
                        switch ($x.type) {
                            'thinking' { Write-Host "$(Col @(190,160,255))✻ Réflexion…$Rst" }
                            'text'     { Write-Host "$(Col $c)●$Rst $($x.text)" }
                            'tool_use' {
                                $arg = foreach ($k in 'file_path', 'pattern', 'command', 'query', 'url', 'name') { if ($x.input.$k) { $x.input.$k; break } }
                                if ($x.name -eq 'Workflow') { $arg = 'audit-securite' }
                                Write-Host "$(Col @(120,230,140))●$Rst $($x.name)($arg)"
                            }
                        }
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 400
    }
}

# ───────────────────────── lancement ─────────────────────────
if ($Simulate) { Simulate; return }
if ($Show) { Show-Claude $Show; return }

$psm = (Get-Command psmux -ErrorAction SilentlyContinue).Source
. (Join-Path $PSScriptRoot 'flow-deps.ps1')
if (-not $psm) { Write-Host (Get-DepMissingText 'psmux') -ForegroundColor Red; return }
& psmux -L $Sock kill-server *> $null
if ((Test-Path -LiteralPath $Root) -and ($Root -like "$env:TEMP*")) { Remove-Item -LiteralPath $Root -Recurse -Force }
New-Item -ItemType Directory -Force $Root | Out-Null
Setup

$me = Join-Path $PSScriptRoot 'flow-demo.ps1'
function Q([string]$s) { "'" + ($s -replace "'", "''") + "'" }
$cmds = @{
    monitor = "pwsh -NoProfile -File $(Q (Join-Path $PSScriptRoot 'claude-monitor.ps1')) -Latest -Watch $(Q $Watch) -Sock $Sock -Session $Sess -NotifyAfter -1"
    claudeA = "pwsh -NoProfile -File $(Q $me) -Show A -Root $(Q $Root)"
    claudeB = "pwsh -NoProfile -File $(Q $me) -Show B -Root $(Q $Root)"
    office  = "pwsh -NoProfile -File $(Q (Join-Path $PSScriptRoot 'flow-office.ps1')) -Watch $(Q $Watch) -Sock $Sock -Session $Sess"
    sim     = "pwsh -NoProfile -File $(Q $me) -Simulate -Root $(Q $Root)"
}
& psmux -L $Sock -f (Join-Path $Flow 'config\psmux.conf') new-session -d -s $Sess -n demo -x 220 -y 56 -c $Root *> $null
Start-Sleep -Milliseconds 600
# disposition : moniteur | Claude 1 | Claude 2  /  Bureau | simulateur
& psmux -L $Sock split-window -v -p 38 -t "${Sess}:.0" -c $Root *> $null; Start-Sleep -Milliseconds 300
& psmux -L $Sock split-window -h -p 70 -t "${Sess}:.0" -c $Root *> $null; Start-Sleep -Milliseconds 300
& psmux -L $Sock split-window -h -p 50 -t "${Sess}:.1" -c $Root *> $null; Start-Sleep -Milliseconds 300
& psmux -L $Sock split-window -h -p 30 -t "${Sess}:.3" -c $Root *> $null; Start-Sleep -Milliseconds 300
$plan = @(
    @{ i = 0; cmd = $cmds.monitor; title = '◉ moniteur · tous les comptes' }
    @{ i = 1; cmd = $cmds.claudeA; title = '✦ claude · Compte 1'; acct = 'principal' }
    @{ i = 2; cmd = $cmds.claudeB; title = '✦ claude · Compte 2'; acct = 'second' }
    @{ i = 3; cmd = $cmds.office; title = '⌂ bureau' }
    @{ i = 4; cmd = $cmds.sim; title = '▶ simulateur (démo)' }
)
foreach ($p in $plan) {
    $t = "${Sess}:.$($p.i)"
    & psmux -L $Sock set -p -t $t '@flow_role' $p.title *> $null
    & psmux -L $Sock set -p -t $t '@flow_base' $p.title *> $null
    if ($p.acct) { & psmux -L $Sock set -p -t $t '@flow_acct' $p.acct *> $null }
}
Start-Sleep -Milliseconds 1500
foreach ($p in $plan) {
    & psmux -L $Sock send-keys -t "${Sess}:.$($p.i)" -l "Clear-Host; $($p.cmd)" *> $null
    & psmux -L $Sock send-keys -t "${Sess}:.$($p.i)" Enter *> $null
}
& psmux -L $Sock select-pane -t "${Sess}:.3" *> $null

if (-not $NoWindow) {
    # lancé depuis une session psmux (ex. Claude dans FLOW) : sans ces variables, psmux refuse de s'imbriquer ;
    # NO_COLOR (posé par les shells de Claude Code) ferait tout afficher en noir et blanc
    $att = "Get-ChildItem Env: | Where-Object Name -match '^(TMUX|PSMUX|NO_COLOR$)' | Remove-Item; `$env:COLORTERM = 'truecolor'; psmux -L $Sock attach -t $Sess"
    Start-Process pwsh -ArgumentList @('-NoProfile', '-Command', $att) -WindowStyle Maximized
}
"démo lancée : $(if ($NoWindow) { "psmux -L $Sock attach -t $Sess" } else { 'nouvelle fenêtre « FLOW démo »' }) — arrêt : psmux -L $Sock kill-server"
