#Requires -Version 7
# Étapes de la feuille de route (tools\flow-steps.ps1) : conception (cartographie en parallèle, critique, spec, relectures), validation, construction liée
# à l'étape, enchaînement, empreintes des données protégées. Aucun vrai Claude : un routeur répond selon le nom du fichier de consigne.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowstep-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode', 'RevJobs', 'GuidedPrefFile') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    $env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    $global:GuidedPrefFile = Join-Path $global:Base 'team-prefs.json'
    $global:FlowNoAi = $true

    Remove-Item Alias:cls -Force -ErrorAction SilentlyContinue
    function Notify { }
    function Cls { }
    function Show-Frame { }
    function Git-Run([string]$dir, [string[]]$a) { & git -C $dir -c user.name=t -c user.email=t@t @a 2>&1 | Out-String }
    function Wait-Job-Spinner($job, [string]$label) { [void](Wait-Job $job); $rv = Receive-Job $job; Remove-Job $job -Force; $rv }
    function Envelope([string]$json) { (@{ result = $json; is_error = $false } | ConvertTo-Json -Compress) }
    $global:KeyQ = [Collections.Generic.Queue[string]]::new()
    $global:LineQ = [Collections.Generic.Queue[string]]::new()
    function Key-Of([string]$c) {
        if ($c -eq 'esc') { [pscustomobject]@{ Key = 'Escape'; KeyChar = [char]27; Modifiers = 0 } } elseif ($c -eq 'enter') { [pscustomobject]@{ Key = 'Enter'; KeyChar = [char]13; Modifiers = 0 } }
        elseif ($c -eq 'down') { [pscustomobject]@{ Key = 'DownArrow'; KeyChar = [char]0; Modifiers = 0 } } else { [pscustomobject]@{ Key = $c.ToUpper(); KeyChar = [char]$c; Modifiers = 0 } }
    }
    function Read-KeyOrHint { Key-Of $(if ($global:KeyQ.Count) { $global:KeyQ.Dequeue() } else { 'esc' }) }
    function Read-Action { param([switch]$Wait, [int]$TimeoutMs = 0, [switch]$Wheel) if ($global:KeyQ.Count) { @{ K = (Key-Of $global:KeyQ.Dequeue()) } } else { $null } }
    function Message-Screen { param($title, $body, $keys) $global:Screens += "$title :: $($body -join ' | ')"; Read-KeyOrHint }
    function Read-Line([string]$title, [string]$prompt) { if ($global:LineQ.Count) { $global:LineQ.Dequeue() } else { $null } }
    function Ask-Questions($qs, [string]$title, [string]$intro = '') { $global:Asked = @($qs).Count; , @(@($qs) | ForEach-Object { @{ a = @($_.options)[0]; mode = 'option'; idx = 0 } }) }

    # routeur : répond selon le nom du fichier de consigne (carte-plan, lecteur-<zone>, critique, spec, spec-legere, revue-*, spec-final, spec-refaite)
    $global:Calls = @(); $global:Router = @{}
    function Start-ClaudeJob([string]$cwd, $acct, [string]$promptFile, [string]$model, [string]$tools, [string]$addDir = '') {
        $name = [IO.Path]::GetFileNameWithoutExtension($promptFile)
        $global:Calls += $name; $global:Models[$name] = $model
        $global:Prompts[$name] = Get-Content -LiteralPath $promptFile -Raw -Encoding utf8
        $key = if ($name -like 'lecteur-*') { 'lecteur' } else { $name }
        $out = if ($global:Router.ContainsKey($key)) { $global:Router[$key] } else { '' }
        if ($key -eq 'lecteur' -and $out) { $out = $out.Replace('ZONE', $name.Substring(8)) }
        $j = Start-Job -ScriptBlock { param($o) [pscustomobject]@{ Code = 0; Out = $o } } -ArgumentList $out
        [void](Wait-Job $j); $j
    }
    $global:Models = @{}; $global:Prompts = @{}

    $script:Zones = Envelope '{"zones":[{"key":"api","consigne":"routes"},{"key":"donnees","consigne":"formats"}]}'
    $script:Reader = Envelope '{"zone":"ZONE","constats":"- src/routes.js:12 : le routeur"}'
    $script:Critic = Envelope '{"manques":["pas de test d''erreur"],"contradictions":[],"pieges":["CRLF"],"decisions_ouvertes":[]}'
    $script:SpecJson = Envelope '{"resume":"Ajouter l''authentification par jeton.","decisions":[{"point":"Durée du jeton","choix":"1 heure"}],"questions":[{"question":"Où stocker les jetons ?","why":"sécurité","options":["En base","En mémoire"]}],"emplacements":[{"sujet":"Routes","ou":"src/routes.js","constat":"point d''entrée | unique"}],"lots":[{"nom":"Serveur","fichiers":["src/auth.js","src/routes.js"],"consigne":"écrire le middleware"},{"nom":"Tests","fichiers":["tests/auth.test.js"],"consigne":"tester les erreurs"}],"tests":["401 sans jeton"],"verifications":["curl /me avec et sans jeton"],"risques":["jeton volé"]}'
    $script:Review = Envelope '{"corrections":["préciser la durée du jeton"]}'
    $script:NoReview = Envelope '{"corrections":[]}'

    function New-StepProject([string[]]$Etats = @('fait', 'à faire', 'à faire'), [string[]]$Passes = @('complète', 'complète', 'légère')) {
        $d = Join-Path $global:Base ([guid]::NewGuid().ToString('N').Substring(0, 6)); $p = Join-Path $d 'proj'
        New-Item -ItemType Directory -Force "$p\.flow\workflow" | Out-Null
        $global:RepoRoot = $p
        [void](Git-Run $p @('init', '-q', '-b', 'main')); Set-Content "$p\base.txt" 'x'; [void](Git-Run $p @('add', '-A')); [void](Git-Run $p @('commit', '-q', '-m', 'init'))
        Set-Content "$p\.flow\workflow\CAHIER.md" "# Cahier`n## Vision`nUne API." -Encoding utf8
        $i = 0; Write-Roadmap @($Etats | ForEach-Object { $i++; [pscustomobject]@{ id = "E$i"; titre = "Étape $i"; but = "But $i"; documents = @('src/'); passe = $Passes[$i - 1]; etat = $_ } })
        Save-WfMeta $true
        $global:Cfg = [pscustomobject]@{ checks = @(); commitStyle = 'libre'; protectedPaths = @(); guardrails = @(); deliver = 'merge'; detected = @(); branchPrefix = 'flow/'; targetBranch = $null }
        $global:Calls = @(); $global:Models = @{}; $global:Prompts = @{}; $global:Screens = @(); $global:Asked = 0
        $global:KeyQ.Clear(); $global:LineQ.Clear(); $global:State = $null
        # un vrai Start-Run (Use-Run) pose $script:State / RunDir / WtRoot, qui masquent les variables globales des scénarios suivants
        foreach ($n in 'State', 'RunDir', 'WtRoot') { Remove-Variable -Name $n -Scope Script -ErrorAction SilentlyContinue }
        $p
    }
    function Etat([string]$id) { ((Read-Roadmap).Steps | Where-Object { $_.id -eq $id }).etat }
    function Journal { $f = Wf-File 'journal.md'; if (Test-Path $f) { Get-Content $f -Raw -Encoding utf8 } else { '' } }
    function Step-Of([string]$id) { (Read-Roadmap).Steps | Where-Object { $_.id -eq $id } }
    function Route-Full { $global:Router = @{ 'carte-plan' = $script:Zones; 'lecteur' = $script:Reader; 'critique' = $script:Critic; 'spec' = $script:SpecJson; 'revue-fidelite' = $script:Review; 'revue-faisabilite' = $script:NoReview; 'spec-final' = $script:SpecJson; 'spec-legere' = $script:SpecJson; 'spec-refaite' = $script:SpecJson } }
}

AfterAll { Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Régression : la zone de demande de l''accueil' {
    It 'la demande préremplie et la branche de départ d''un ajustement sont consommées (une apostrophe isolée les cassait)' {
        [void](New-StepProject)
        function Open-Runs { @() }
        $global:SeenPrefill = $null
        function Read-Prompt($x) { $global:SeenPrefill = $x; $null }
        $global:FlowPrefill = 'ajuste le titre'; $global:FlowNextBase = 'flow/E1'; $global:FlowWfOffered = $true
        Mode-Home | Should -Be 'quit'
        $global:SeenPrefill | Should -Be 'ajuste le titre'
        $global:FlowPrefill | Should -Be ''
        $global:FlowNextBase | Should -Be ''
        $global:FlowPrefill = ''; $global:SeenPrefill = 'x'
        [void](Mode-Home); $global:SeenPrefill | Should -Be ''
    }
    It 'aucune ligne de FLOW ne se termine par une apostrophe orpheline (« = '' » écrit avec une seule apostrophe)' {
        $files = @(Get-ChildItem (Join-Path $global:FlowRoot 'tools') -Filter *.ps1) + @(Get-Item (Join-Path $global:FlowRoot 'FLOW.ps1'))
        $hits = foreach ($f in $files) { $n = 0; foreach ($l in Get-Content $f.FullName -Encoding utf8) { $n++; if ($l -match '^\s*\$[\w:]+\s*=\s*''\s*$') { "$($f.Name):$n" } } }
        @($hits) | Should -BeNullOrEmpty
    }
}

Describe 'Données protégées : empreintes avant et après' {
    BeforeEach {
        [void](New-StepProject)
        $global:Cfg.protectedPaths = @('data/prod', 'secrets/*')
        New-Item -ItemType Directory -Force "$global:RepoRoot\data\prod\sub", "$global:RepoRoot\secrets" | Out-Null
        Set-Content "$global:RepoRoot\data\prod\a.db" 'A'; Set-Content "$global:RepoRoot\data\prod\sub\b.db" 'B'; Set-Content "$global:RepoRoot\secrets\k.txt" 'K'
        $global:RunDir = Join-Path $global:RepoRoot '.flow\runs\T1'; New-Item -ItemType Directory -Force $global:RunDir | Out-Null
    }
    It 'sans changement : contrôle réussi ; les chemins à joker sont ignorés' {
        Write-DataManifest
        $m = Get-Content "$global:RunDir\donnees-avant.json" -Raw | ConvertFrom-Json
        @($m.files.PSObject.Properties.Name) | Should -Be @('data/prod/a.db', 'data/prod/sub/b.db')
        $c = Data-Check
        $c.ok | Should -BeTrue
        $c.name | Should -Be 'données protégées (contenu)'
    }
    It 'détecte une donnée modifiée, supprimée ou ajoutée, avec son nom' {
        Write-DataManifest
        Set-Content "$global:RepoRoot\data\prod\a.db" 'CHANGÉ'
        Remove-Item "$global:RepoRoot\data\prod\sub\b.db"
        Set-Content "$global:RepoRoot\data\prod\nouveau.db" 'N'
        $c = Data-Check
        $c.ok | Should -BeFalse
        ($c.tail -join ' | ') | Should -Match 'modifié : data/prod/a.db'
        ($c.tail -join ' | ') | Should -Match 'supprimé : data/prod/sub/b.db'
        ($c.tail -join ' | ') | Should -Match 'ajouté : data/prod/nouveau.db'
    }
    It 'rien à comparer sans chemins protégés ou sans empreintes' {
        $global:Cfg.protectedPaths = @(); Write-DataManifest
        Test-Path "$global:RunDir\donnees-avant.json" | Should -BeFalse
        Data-Check | Should -BeNullOrEmpty
    }
    It 'l''intégration ajoute ce contrôle aux vérifications (et il ne fait jamais disparaître les autres)' {
        (Get-Content (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -Raw -Encoding utf8) | Should -Match '@\(Data-Check\)'
    }
}

Describe 'La spécification' {
    It 'est nettoyée : 4 lots au plus, noms uniques, questions valides ; sans lot elle est refusée' {
        $j = '{"resume":"r","lots":[{"nom":"A","fichiers":["a"],"consigne":"x"},{"nom":"A","fichiers":["b"],"consigne":"y"},{"nom":"","fichiers":[],"consigne":"z"},{"nom":"D","fichiers":["d"]},{"nom":"E","fichiers":["e"]}],"questions":[{"question":"Q ?","options":["o"]},{"question":""}],"tests":["t",""],"decisions":[{"point":"p","choix":"c"},{"point":""}]}' | ConvertFrom-Json
        $s = Convert-Spec $j
        $s.lots.Count | Should -Be 4
        ($s.lots.nom | Select-Object -Unique).Count | Should -Be 4
        $s.lots[2].nom | Should -Be 'Lot 3'
        (Convert-Spec ('{"lots":[{"nom":"Lot 1 — Module et équipe","fichiers":["a"],"consigne":"x"},{"nom":"lot 2 : Tests","fichiers":["b"],"consigne":"y"}]}' | ConvertFrom-Json)).lots.nom | Should -Be @('Module et équipe', 'Tests')
        $s.questions.Count | Should -Be 1
        $s.tests | Should -Be @('t')
        $s.decisions.Count | Should -Be 1
        Convert-Spec ('{"resume":"r","lots":[]}' | ConvertFrom-Json) | Should -BeNullOrEmpty
        Convert-Spec $null | Should -BeNullOrEmpty
    }
    It 'deux lots ne peuvent pas modifier le même fichier : signalé' {
        $s = Convert-Spec ('{"lots":[{"nom":"A","fichiers":["src/x.js"],"consigne":"a"},{"nom":"B","fichiers":["SRC\\x.js","y.js"],"consigne":"b"}]}' | ConvertFrom-Json)
        @(Find-Overlaps $s).Count | Should -Be 1
        @(Find-Overlaps $s)[0] | Should -Match 'x.js'
    }
    It 'le document garde les décisions de l''utilisateur (qui font foi) séparées des choix par défaut' {
        [void](New-StepProject)
        $s = Convert-Spec (($script:SpecJson | ConvertFrom-Json).result | ConvertFrom-Json)
        $md = ConvertTo-Spec $s (Step-Of 'E2') '- **Où stocker les jetons ?** → En base'
        $md | Should -Match '## §0 Décisions'
        $md | Should -Match '### Décisions de l.utilisateur \(font foi\)\n- \*\*Où stocker les jetons \?\*\* → En base'
        $md | Should -Match '\*\*Durée du jeton\*\* : 1 heure \*\(choix par défaut, à confirmer\)\*'
        $md | Should -Match '### Lot 1 — Serveur\nFichiers : src/auth.js, src/routes.js'
        $md | Should -Match 'point d.entrée \\\| unique'                      # une barre verticale dans un tableau est échappée
        $md | Should -Match '## §3 Tests\n\n- 401 sans jeton'
        $md | Should -Match '## §5 Risques'
    }
}

Describe 'Conception d''une étape' {
    It 'passe complète : zones → lecteurs en parallèle → critique → spec → deux relectures → spec finale ; puis validation' {
        [void](New-StepProject); Route-Full
        $global:KeyQ.Enqueue('enter')
        $r = Invoke-StepDesign (Step-Of 'E2')
        $r.Mode | Should -Be 'build'
        $global:Calls | Should -Be @('carte-plan', 'lecteur-api', 'lecteur-donnees', 'critique', 'spec', 'revue-fidelite', 'revue-faisabilite', 'spec-final')
        $global:Models['lecteur-api'] | Should -Be 'sonnet'; $global:Models['spec'] | Should -Be 'opus'
        Spec-Validated 'E2' | Should -BeTrue
        $md = Get-Content (Spec-File 'E2') -Raw -Encoding utf8
        $md | Should -Match 'Ajouter l.authentification'
        $md | Should -Match 'Où stocker les jetons'                           # la décision posée à l'utilisateur est dans le §0
        (Get-Content (Join-Path (Step-Dir 'E2') 'carte.md') -Raw -Encoding utf8) | Should -Match 'src/routes.js:12'
        $global:Asked | Should -Be 1
        Etat 'E2' | Should -Be 'conception'
        Journal | Should -Match 'E2 — conception lancée \(passe complète\)'
        Journal | Should -Match 'E2 — conception terminée : spec validée \(2 lot\(s\)\)'
    }
    It 'les relectures corrigent la spec : leurs corrections arrivent dans la consigne de la spec finale' {
        [void](New-StepProject); Route-Full; $global:KeyQ.Enqueue('enter')
        [void](Invoke-StepDesign (Step-Of 'E2'))
        $global:Prompts['spec-final'] | Should -Match 'préciser la durée du jeton'
        $global:Prompts['revue-fidelite'] | Should -Match 'FIDÉLITÉ'
        $global:Prompts['revue-faisabilite'] | Should -Match 'FAISABILITÉ'
        $global:Prompts['lecteur-api'] | Should -Match 'LECTURE SEULE'
        $global:Prompts['spec'] | Should -Match 'CARTE DU CODE'
        $global:Prompts['spec'] | Should -Match 'pas de test d.erreur'           # la critique alimente la spec
    }
    It 'sans correction demandée par les relectures, pas de spec finale' {
        [void](New-StepProject); Route-Full; $global:Router['revue-fidelite'] = $script:NoReview; $global:KeyQ.Enqueue('enter')
        [void](Invoke-StepDesign (Step-Of 'E2'))
        $global:Calls | Should -Not -Contain 'spec-final'
    }
    It 'passe légère : un seul appel, ni cartographie ni relectures' {
        [void](New-StepProject); Route-Full; $global:KeyQ.Enqueue('enter')
        $r = Invoke-StepDesign (Step-Of 'E3')
        $r.Mode | Should -Be 'build'
        $global:Calls | Should -Be @('spec-legere')
        $global:Prompts['spec-legere'] | Should -Match 'Explore toi-même le projet'
    }
    It 'Échap garde un brouillon : la spec est écrite mais pas validée, donc pas de construction' {
        [void](New-StepProject); Route-Full; $global:KeyQ.Enqueue('esc')
        $r = Invoke-StepDesign (Step-Of 'E2')
        $r.Mode | Should -Be 'later'
        Test-Path (Spec-File 'E2') | Should -BeTrue
        Spec-Validated 'E2' | Should -BeFalse
        Journal | Should -Match 'spec gardée en brouillon'
    }
    It '« refaire » corrige la spec d''après la remarque de l''utilisateur' {
        [void](New-StepProject); Route-Full
        $global:KeyQ.Enqueue('r'); $global:LineQ.Enqueue('ajoute un lot de documentation'); $global:KeyQ.Enqueue('enter')
        [void](Invoke-StepDesign (Step-Of 'E2'))
        $global:Calls | Should -Contain 'spec-refaite'
        $global:Prompts['spec-refaite'] | Should -Match 'ajoute un lot de documentation'
        Spec-Validated 'E2' | Should -BeTrue
    }
    It 'cartographie illisible : la conception est abandonnée et l''étape retrouve son état' {
        [void](New-StepProject); Route-Full; $global:Router['carte-plan'] = 'pas du JSON'
        $r = Invoke-StepDesign (Step-Of 'E2')
        $r.Mode | Should -Be 'error'
        Etat 'E2' | Should -Be 'à faire'
        Journal | Should -Match 'abandonnée'
        Test-Path (Spec-File 'E2') | Should -BeFalse
    }
    It 'une spec sans lot est refusée sans rien écrire ; un lecteur raté n''empêche pas les autres' {
        [void](New-StepProject); Route-Full; $global:Router['spec'] = Envelope '{"resume":"r","lots":[]}'
        (Invoke-StepDesign (Step-Of 'E2')).Mode | Should -Be 'error'
        Test-Path (Spec-File 'E2') | Should -BeFalse
        [void](New-StepProject); Route-Full
        $one = $script:Reader; $global:Router['lecteur'] = $one
        $global:KeyQ.Enqueue('enter')
        (Invoke-StepDesign (Step-Of 'E2')).Mode | Should -Be 'build'
    }
}

Describe 'Lancer une étape' {
    BeforeEach {
        [void](New-StepProject); Route-Full
        $global:Started = $null
        function Start-Run { param([string]$req, [string]$nextBase = '', [string]$StepId = '', [string]$SpecPath = '', [string]$Depth = '') $global:Started = @{ Req = $req; Step = $StepId; Spec = $SpecPath; Depth = $Depth }; 'plan' }
    }
    It 'conception, validation, puis construction : l''équipe est liée à l''étape, à sa spec et à sa passe' {
        $global:KeyQ.Enqueue('enter')                                   # valider la spec
        Invoke-StepLaunch 'E2' | Should -Be 'plan'
        $global:Started.Step | Should -Be 'E2'
        $global:Started.Spec | Should -Be (Spec-File 'E2')
        $global:Started.Depth | Should -Be 'full'
        $global:Started.Req | Should -Match 'Construire l.étape E2'
        Journal | Should -Match 'E2 — construction lancée'
    }
    It 'une étape en passe légère impose la passe légère à l''équipe' {
        $global:KeyQ.Enqueue('enter')
        Invoke-StepLaunch 'E3' | Should -Be 'plan'
        $global:Started.Depth | Should -Be 'light'
    }
    It 'spec déjà validée : Entrée construit tout de suite, sans refaire la conception' {
        $global:KeyQ.Enqueue('enter'); [void](Invoke-StepLaunch 'E2')
        $global:Calls = @(); $global:Started = $null
        $global:KeyQ.Enqueue('enter')                                   # « construire »
        Invoke-StepLaunch 'E2' | Should -Be 'plan'
        $global:Calls.Count | Should -Be 0
        $global:Started.Step | Should -Be 'E2'
    }
    It 'spec déjà validée : R refait la conception' {
        $global:KeyQ.Enqueue('enter'); [void](Invoke-StepLaunch 'E2')
        $global:Calls = @()
        $global:KeyQ.Enqueue('r'); $global:KeyQ.Enqueue('enter')
        Invoke-StepLaunch 'E2' | Should -Be 'plan'
        $global:Calls | Should -Contain 'carte-plan'
    }
    It 'spec en brouillon : rien n''est construit' {
        $global:KeyQ.Enqueue('esc')
        Invoke-StepLaunch 'E2' | Should -Be 'home'
        $global:Started | Should -BeNullOrEmpty
    }
    It 'une étape déjà faite demande une confirmation explicite' {
        $global:KeyQ.Enqueue('esc')
        Invoke-StepLaunch 'E1' | Should -Be 'home'
        $global:Calls.Count | Should -Be 0
    }
    It 'ROADMAP.md à corriger : rien n''est lancé' {
        Add-Content (Wf-File 'ROADMAP.md') "`n| E9 | cassé |" -Encoding utf8
        Invoke-StepLaunch 'E2' | Should -Be 'home'
        $global:Calls.Count | Should -Be 0
        ($global:Screens -join ' ') | Should -Match 'à corriger'
    }
    It 'depuis l''écran de la feuille de route : L (ou Entrée) lance l''étape choisie et passe au plan' {
        $global:Started = $null
        function Invoke-StepLaunch([string]$id) { $global:Started = $id; 'plan' }
        function Open-Runs { @() }
        $global:KeyQ.Enqueue('down'); $global:KeyQ.Enqueue('l')
        Mode-Roadmap | Should -Be 'plan'
        $global:Started | Should -Be 'E2'
    }
}

Describe 'Équipe liée à une étape' {
    BeforeAll {
        function Invoke-Discovery { $global:Discovery++ }
        function Invoke-Planner([string]$extra, [switch]$NoQuestions) { $true }
        function Log-Quota([string]$m) { }
    }
    It 'Start-Run : étape, spec copiée dans le dossier de l''équipe, passe imposée, point de retour Git ; pas de nouvelles questions' {
        $p = New-StepProject
        $global:Cfg.protectedPaths = @('data'); New-Item -ItemType Directory -Force "$p\data" | Out-Null; Set-Content "$p\data\x.db" 'X'
        Set-Content "$p\spec-source.md" '# spec de test' -Encoding utf8
        [void](Git-Run $p @('add', '-A')); [void](Git-Run $p @('commit', '-q', '-m', 'données et spec'))
        $global:FlowGuided = $true; $global:Discovery = 0
        (Start-Run 'Construire E2' '' 'E2' "$p\spec-source.md" 'light') | Should -Be 'plan'
        $State.step | Should -Be 'E2'
        $State.depthFixed | Should -Be 'light'
        (Get-Content $State.specPath -Raw) | Should -Match 'spec de test'
        $State.specPath | Should -Be (Join-Path $RunDir 'SPEC.md')
        $global:Discovery | Should -Be 0
        (Git-Run $p @('rev-parse', '--verify', '-q', "refs/flow-backup/$($State.id)")).Trim() | Should -Be $State.base
        Test-Path (Join-Path $RunDir 'donnees-avant.json') | Should -BeTrue
        $global:FlowGuided = $false
    }
    It 'une équipe sans étape ne crée ni spec ni point de retour, et garde ses questions en mode guidé' {
        $p = New-StepProject
        $global:FlowGuided = $true; $global:Discovery = 0
        (Start-Run 'une demande libre') | Should -Be 'plan'
        $State.step | Should -Be ''
        $State.specPath | Should -Be ''
        $global:Discovery | Should -Be 1
        (Git-Run $p @('for-each-ref', 'refs/flow-backup')).Trim() | Should -Be ''
        $global:FlowGuided = $false
    }
    It 'la spec de l''étape est donnée au planificateur et au brief ; la passe de l''étape l''emporte sur celle du planificateur' {
        [void](New-StepProject)
        $global:RunDir = Join-Path $global:RepoRoot '.flow\runs\T1'; New-Item -ItemType Directory -Force $global:RunDir | Out-Null
        Set-Content "$global:RunDir\SPEC.md" "# spec`n### Lot 1 — Serveur" -Encoding utf8
        $global:State = [pscustomobject]@{ id = 'T1'; prefix = 'flow/'; base = 'x'; summary = 's'; commitTitle = ''; status = 'planning'; updated = ''; prompt = 'p'; depth = 'full'; depthFixed = 'light'; guided = $false; precisions = ''; step = 'E2'; specPath = "$global:RunDir\SPEC.md"; brief = ''; planner = ''; crossReview = $false; tasks = @(); integration = [pscustomobject]@{ merged = @(); skipped = @(); checks = @() } }
        $p = Planner-Prompt 'x' ''
        $p | Should -Match 'SPÉCIFICATION DE L.ÉTAPE \(FAIT FOI'
        $p | Should -Match 'Lot 1 — Serveur'
        $p | Should -Match 'DOIT reprendre ses lots'
        $plan = [pscustomobject]@{ summary = 's'; commitTitle = 't'; brief = 'b'; depth = 'full'; tasks = @([pscustomobject]@{ id = 'A'; title = 't'; goal = 'g'; files = @('a'); depends = @(); done = 'd'; model = 'sonnet'; why = 'w' }) }
        Apply-Plan $plan; $State.depth | Should -Be 'light'                   # le planificateur voulait « full » : la passe de l'étape gagne
        $State.depthFixed = ''; Apply-Plan $plan; $State.depth | Should -Be 'full'
        Write-TaskFiles
        (Get-Content (Join-Path $global:RunDir 'BRIEF.md') -Raw -Encoding utf8) | Should -Match 'Spécification de l.étape'
        (Judge-Prompt $global:RepoRoot) | Should -Match 'SPEC.md'
    }
}

Describe 'Enchaîner l''étape suivante' {
    BeforeEach { [void](New-StepProject @('fait', 'à faire', 'à faire')); $global:FlowChain = '' }
    It 'tout est vert : propose l''étape suivante, Entrée l''enchaîne' {
        $global:KeyQ.Enqueue('enter')
        Offer-NextStep $true | Should -Be 'E2'
    }
    It 'Échap : plus tard' {
        $global:KeyQ.Enqueue('esc')
        Offer-NextStep $true | Should -BeNullOrEmpty
    }
    It 'une vérification échouée ou un juge pas convaincu : FLOW n''enchaîne pas, et le dit' {
        $global:KeyQ.Enqueue('enter')
        Offer-NextStep $false | Should -BeNullOrEmpty
        ($global:Screens -join ' ') | Should -Match 'n.enchaîne pas'
    }
    It 'plus aucune étape à faire : la feuille de route est terminée' {
        [void](New-StepProject @('fait', 'fait', 'fait'))
        Offer-NextStep $true | Should -BeNullOrEmpty
        ($global:Screens -join ' ') | Should -Match 'terminée'
    }
    It 'à l''accueil, l''étape enchaînée est lancée une seule fois' {
        $global:Launched = @()
        function Invoke-StepLaunch([string]$id) { $global:Launched += $id; 'plan' }
        $global:FlowChain = 'E2'; $global:FlowWfOffered = $true
        Mode-Home | Should -Be 'plan'
        $global:FlowChain | Should -Be ''
        $global:Launched | Should -Be @('E2')
    }
}
