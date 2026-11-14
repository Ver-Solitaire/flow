#Requires -Version 7
# Workflow du projet (tools\flow-workflow.ps1) : feuille de route, cahier, création guidée, validation, transmission aux Claude.
# Aucun vrai Claude : les tâches de fond renvoient des réponses toutes prêtes ; les écrans sont remplacés par des réponses scriptées.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowwf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode', 'RevJobs', 'GuidedPrefFile') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    $global:GuidedPrefFile = Join-Path $global:Base 'team-prefs.json'
    $global:FlowNoAi = $true

    Remove-Item Alias:cls -Force -ErrorAction SilentlyContinue
    function Notify { }
    function Cls { }
    function Show-Frame { }
    function Wait-Job-Spinner($job, [string]$label) { [void](Wait-Job $job); $rv = Receive-Job $job; Remove-Job $job -Force; $rv }
    function Envelope([string]$json) { (@{ result = $json; is_error = $false } | ConvertTo-Json -Compress) }
    $global:Prompts = @()
    $global:FakeQueue = [Collections.Generic.Queue[string]]::new()
    function Start-ClaudeJob([string]$cwd, $acct, [string]$promptFile, [string]$model, [string]$tools, [string]$addDir = '') {
        $global:Prompts += , (Get-Content -LiteralPath $promptFile -Raw -Encoding utf8)
        $out = if ($global:FakeQueue.Count) { $global:FakeQueue.Dequeue() } else { '' }
        $j = Start-Job -ScriptBlock { param($o) [pscustomobject]@{ Code = 0; Out = $o } } -ArgumentList $out
        [void](Wait-Job $j); $j
    }
    $global:KeyQ = [Collections.Generic.Queue[string]]::new()
    $global:LineQ = [Collections.Generic.Queue[string]]::new()
    function Read-KeyOrHint {
        $c = if ($global:KeyQ.Count) { $global:KeyQ.Dequeue() } else { 'esc' }
        if ($c -eq 'enter') { [pscustomobject]@{ Key = 'Enter'; KeyChar = [char]13; Modifiers = 0 } } elseif ($c -eq 'esc') { [pscustomobject]@{ Key = 'Escape'; KeyChar = [char]27; Modifiers = 0 } } else { [pscustomobject]@{ Key = $c.ToUpper(); KeyChar = [char]$c; Modifiers = 0 } }
    }
    function Message-Screen { param($title, $body, $keys) $global:Screens += "$title :: $($body -join ' | ')"; Read-KeyOrHint }
    function Read-Line([string]$title, [string]$prompt) { if ($global:LineQ.Count) { $global:LineQ.Dequeue() } else { $null } }
    function Ask-Questions($qs, [string]$title, [string]$intro = '') {
        $global:Asked = @($qs).Count
        , @(@($qs) | ForEach-Object { @{ a = @($_.options)[0]; mode = 'option'; idx = 0 } })
    }

    function New-Project {
        $d = Join-Path $global:Base ([guid]::NewGuid().ToString('N').Substring(0, 6)); $p = Join-Path $d 'mon-projet'
        New-Item -ItemType Directory -Force $p | Out-Null
        $global:RepoRoot = $p
        $global:Cfg = [pscustomobject]@{ checks = @(); setup = $null; commitStyle = 'libre'; protectedPaths = @(); guardrails = @(); deliver = 'merge'; detected = @() }
        $global:Prompts = @(); $global:Screens = @(); $global:KeyQ.Clear(); $global:LineQ.Clear(); $global:FakeQueue.Clear()
        $global:FlowWfOffered = $false
        $p
    }
    $script:Study = '{"type":"API Node","resume":"Une API de recettes en Node, sans tests.","questions":[{"question":"Qui utilise l''API ?","why":"w","options":["Une appli mobile","Des partenaires"]},{"question":"Que ne faut-il jamais toucher ?","why":"w","options":["La base de production","Rien"]}]}'
    $script:Draft = '{"cahier":{"vision":"Une API fiable pour l''appli de recettes.","public":"L''appli mobile.","regles":["Les routes restent compatibles"],"interdits":["Ne jamais modifier la base de production"],"contraintes":["Node 20"],"donneesProtegees":["data/prod","/data/archives","../secret"],"critere":"Tous les tests passent et /health répond 200.","verification":["npm test","curl /health"],"questionsOuvertes":["Quel hébergeur ?"]},"etapes":[{"id":"E1","titre":"Socle de l''API","but":"Routes et tests de base","documents":["src/","README.md"],"passe":"complète"},{"id":"E2","titre":"Texte | accents é","but":"Doc","documents":[],"passe":"légère"}]}'
}

AfterAll { Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Feuille de route : un tableau lisible et lu par FLOW' {
    It 'ce qu''on écrit se relit à l''identique (accents, barres verticales, documents vides)' {
        $steps = @(
            [pscustomobject]@{ id = 'E1'; titre = 'Socle | API'; but = 'Écrire les routes é à'; documents = @('src/', 'README.md'); passe = 'complète'; etat = 'fait' },
            [pscustomobject]@{ id = 'E2'; titre = 'Doc'; but = 'Documenter'; documents = @(); passe = 'légère'; etat = 'à faire' })
        $r = ConvertFrom-Roadmap (ConvertTo-Roadmap $steps 'p')
        $r.Errors | Should -BeNullOrEmpty
        $r.Steps.Count | Should -Be 2
        $r.Steps[0].titre | Should -Be 'Socle | API'
        $r.Steps[0].but | Should -Be 'Écrire les routes é à'
        $r.Steps[0].documents | Should -Be @('src/', 'README.md')
        $r.Steps[0].etat | Should -Be 'fait'
        $r.Steps[1].documents.Count | Should -Be 0
        $r.Steps[1].passe | Should -Be 'légère'
    }
    It 'signale ce qui est illisible au lieu de l''ignorer : colonnes, identifiant, doublon, état, passe' {
        $t = "| Étape | Titre | But | Documents | Passe | État |`n|---|---|---|---|---|---|`n| E1 | a | b | - | complète | fait |`n| E1 | doublon | b | - | complète | fait |`n| E 3! | x | b | - | complète | fait |`n| E4 | x | b | - | bizarre | peut-être |`n| E5 | trop court |"
        $r = ConvertFrom-Roadmap $t
        ($r.Errors -join ' | ') | Should -Match 'existe déjà'
        ($r.Errors -join ' | ') | Should -Match 'identifiant d''étape invalide'
        ($r.Errors -join ' | ') | Should -Match 'état « peut-être » inconnu'
        ($r.Errors -join ' | ') | Should -Match 'passe « bizarre » inconnue'
        ($r.Errors -join ' | ') | Should -Match '6 colonnes attendues'
        ($r.Steps | Where-Object { $_.id -eq 'E4' }).etat | Should -Be 'à faire'     # valeur sûre, mais l'erreur est dite
    }
    It 'change l''état d''une étape, refuse une étape ou un état inconnus' {
        [void](New-Project)
        Write-Roadmap @([pscustomobject]@{ id = 'E1'; titre = 'a'; but = 'b'; documents = @(); passe = 'complète'; etat = 'à faire' })
        Set-StepState 'e1' 'en cours' | Should -BeTrue
        (Read-Roadmap).Steps[0].etat | Should -Be 'en cours'
        Set-StepState 'E9' 'fait' | Should -BeFalse
        Set-StepState 'E1' 'terminé' | Should -BeFalse
        (Read-Roadmap).Steps[0].etat | Should -Be 'en cours'
    }
    It 'l''étape à poursuivre : en cours, sinon en conception, sinon la première à faire' {
        [void](New-Project)
        $mk = { param($etats) $i = 0; Write-Roadmap @($etats | ForEach-Object { $i++; [pscustomobject]@{ id = "E$i"; titre = "t$i"; but = ''; documents = @(); passe = 'complète'; etat = $_ } }) }
        & $mk @('fait', 'à faire', 'en cours'); (Current-Step).id | Should -Be 'E3'
        & $mk @('fait', 'conception', 'à faire'); (Current-Step).id | Should -Be 'E2'
        & $mk @('fait', 'à faire', 'à faire'); (Current-Step).id | Should -Be 'E2'
        & $mk @('fait', 'fait'); Current-Step | Should -BeNullOrEmpty
    }
}

Describe 'Création guidée' {
    It 'étudie, pose les questions, écrit cahier et feuille de route, puis les fait valider' {
        [void](New-Project)
        $global:FakeQueue.Enqueue((Envelope $script:Study)); $global:FakeQueue.Enqueue((Envelope $script:Draft))
        $global:KeyQ.Enqueue('enter')                                    # valider
        $msg = Invoke-WorkflowCreation
        $msg | Should -Match 'workflow validé'
        $global:Asked | Should -Be 2
        Wf-Validated | Should -BeTrue
        $c = Get-Content (Wf-File 'CAHIER.md') -Raw -Encoding utf8
        $c | Should -Match '## Vision'
        $c | Should -Match 'Une API fiable'
        $c | Should -Match 'Ne jamais modifier la base de production'
        $c | Should -Match 'Tous les tests passent'
        (Read-Roadmap).Steps.Count | Should -Be 2
        (Read-Roadmap).Errors | Should -BeNullOrEmpty
        (Get-Content (Wf-File 'workflow.json') -Raw | ConvertFrom-Json).version | Should -Be 1
    }
    It 'la demande d''étude porte sur ce que le code ne dit pas ; le brouillon reçoit les réponses de l''utilisateur' {
        [void](New-Project)
        $global:FakeQueue.Enqueue((Envelope $script:Study)); $global:FakeQueue.Enqueue((Envelope $script:Draft))
        $global:KeyQ.Enqueue('enter'); [void](Invoke-WorkflowCreation)
        $global:Prompts[0] | Should -Match 'SUR CE QUE LE CODE NE DIT PAS'
        $global:Prompts[0] | Should -Match 'GROS projet'
        $global:Prompts[1] | Should -Match 'Une appli mobile'
        $global:Prompts[1] | Should -Match 'API Node'
        $global:Prompts[1] | Should -Match 'MESURABLE'
    }
    It 'inscrit les données protégées (nettoyées) et les interdits dans le profil du projet, une seule source' {
        [void](New-Project)
        $global:FakeQueue.Enqueue((Envelope $script:Study)); $global:FakeQueue.Enqueue((Envelope $script:Draft))
        $global:KeyQ.Enqueue('enter'); [void](Invoke-WorkflowCreation)
        @($Cfg.protectedPaths) | Should -Contain 'data/prod'
        @($Cfg.protectedPaths) | Should -Contain 'data/archives'          # « /data/archives » est rendu relatif
        @($Cfg.protectedPaths) | Should -Not -Contain '../secret'         # un chemin qui sort du projet est refusé
        @($Cfg.guardrails) | Should -Contain 'Ne jamais modifier la base de production'
        (Get-Content (Cfg-Path) -Raw | ConvertFrom-Json).protectedPaths | Should -Contain 'data/prod'
    }
    It 'un interdit écrit sans « ne jamais » est étiqueté : il ne peut pas être lu comme un ordre' {
        Wf-Forbid 'Toucher à la base de production' | Should -Be 'À ne jamais faire : Toucher à la base de production'
        Wf-Forbid 'Ne jamais toucher à la production' | Should -Be 'Ne jamais toucher à la production'
        Wf-Forbid 'Ne pas publier' | Should -Be 'Ne pas publier'
        Wf-Forbid '  ' | Should -Be ''
        [void](New-Project)
        $d = $script:Draft -replace 'Ne jamais modifier la base de production', 'Modifier la base de production'
        $global:FakeQueue.Enqueue((Envelope $script:Study)); $global:FakeQueue.Enqueue((Envelope $d)); $global:KeyQ.Enqueue('enter')
        [void](Invoke-WorkflowCreation)
        @($Cfg.guardrails) | Should -Contain 'À ne jamais faire : Modifier la base de production'
        (Get-Content (Wf-File 'CAHIER.md') -Raw -Encoding utf8) | Should -Match '- À ne jamais faire : Modifier la base de production'
        (Guardrails-Text) | Should -Match '- À ne jamais faire : Modifier la base de production'
    }
    It 'Échap sur l''écran de validation garde un brouillon : écrit, mais PAS transmis aux Claude' {
        [void](New-Project)
        $global:FakeQueue.Enqueue((Envelope $script:Study)); $global:FakeQueue.Enqueue((Envelope $script:Draft))
        $global:KeyQ.Enqueue('esc')
        (Invoke-WorkflowCreation) | Should -Match 'brouillon'
        Wf-Exists | Should -BeTrue
        Wf-Validated | Should -BeFalse
        Cahier-Block | Should -Be ''
        (Planner-Prompt 'x' '') | Should -Not -Match 'Cahier du projet'
    }
    It 'annuler les questions n''écrit aucun fichier' {
        [void](New-Project)
        $global:FakeQueue.Enqueue((Envelope $script:Study))
        function Ask-Questions($qs, [string]$title, [string]$intro = '') { $null }
        (Invoke-WorkflowCreation) | Should -Match 'annulée'
        Wf-Exists | Should -BeFalse
        Test-Path (Wf-Dir) | Should -BeFalse
        function Ask-Questions($qs, [string]$title, [string]$intro = '') { $global:Asked = @($qs).Count; , @(@($qs) | ForEach-Object { @{ a = @($_.options)[0]; mode = 'option'; idx = 0 } }) }
    }
    It '« refaire » relance le brouillon avec la précision de l''utilisateur, sans reposer les questions' {
        [void](New-Project)
        $global:FakeQueue.Enqueue((Envelope $script:Study)); $global:FakeQueue.Enqueue((Envelope $script:Draft)); $global:FakeQueue.Enqueue((Envelope $script:Draft))
        $global:KeyQ.Enqueue('r'); $global:LineQ.Enqueue('ajoute une étape de sécurité'); $global:KeyQ.Enqueue('enter')
        [void](Invoke-WorkflowCreation)
        $global:Prompts.Count | Should -Be 3                              # étude, brouillon, brouillon refait
        $global:Prompts[2] | Should -Match 'ajoute une étape de sécurité'
        Wf-Validated | Should -BeTrue
    }
    It 'un brouillon illisible ne détruit rien et le dit' {
        [void](New-Project)
        $global:FakeQueue.Enqueue((Envelope $script:Study)); $global:FakeQueue.Enqueue('n''importe quoi')
        (Invoke-WorkflowCreation) | Should -Match 'inexploitable'
        Wf-Exists | Should -BeFalse
    }
    It 'refaire un workflow archive l''ancien : rien n''est perdu' {
        [void](New-Project)
        $global:FakeQueue.Enqueue((Envelope $script:Study)); $global:FakeQueue.Enqueue((Envelope $script:Draft)); $global:KeyQ.Enqueue('enter')
        [void](Invoke-WorkflowCreation)
        Set-Content (Wf-File 'CAHIER.md') 'MODIFIÉ À LA MAIN' -Encoding utf8
        $d2 = $script:Draft -replace 'Une API fiable', 'Une API très fiable'
        $global:FakeQueue.Enqueue((Envelope $script:Study)); $global:FakeQueue.Enqueue((Envelope $d2)); $global:KeyQ.Enqueue('enter')
        [void](Invoke-WorkflowCreation -Redo)
        $arch = @(Get-ChildItem (Join-Path (Wf-Dir) 'archives') -Directory)
        $arch.Count | Should -BeGreaterThan 0
        (Get-Content (Join-Path $arch[0].FullName 'CAHIER.md') -Raw) | Should -Match 'MODIFIÉ À LA MAIN'
        (Get-Content (Wf-File 'CAHIER.md') -Raw) | Should -Match 'très fiable'
    }
}

Describe 'Transmission aux Claude' {
    BeforeEach {
        [void](New-Project)
        $global:FakeQueue.Enqueue((Envelope $script:Study)); $global:FakeQueue.Enqueue((Envelope $script:Draft)); $global:KeyQ.Enqueue('enter')
        [void](Invoke-WorkflowCreation)
        $global:State = [pscustomobject]@{ id = 'T1'; prefix = 'flow/'; base = 'x'; summary = 's'; prompt = 'p'; depth = 'full'; guided = $false; precisions = ''; brief = ''; crossReview = $false; tasks = @(); integration = [pscustomobject]@{ merged = @(); skipped = @(); checks = @() } }
        $global:RunDir = Join-Path $global:RepoRoot '.flow\runs\T1'; New-Item -ItemType Directory -Force $global:RunDir | Out-Null
    }
    It 'le planificateur, le guide, l''ouvrier et le relecteur reçoivent le cahier et l''étape en cours' {
        $t = [pscustomobject]@{ id = 'A'; title = 't'; worktree = $global:RepoRoot; model = 'sonnet'; goal = 'g'; done = 'd'; depends = @(); files = @() }
        foreach ($txt in (Planner-Prompt 'x' ''), (Questioner-Prompt 1), (Worker-Prompt $t), (Review-Prompt $t 'x.diff' 1)) {
            $txt | Should -Match 'Cahier du projet \(FAIT FOI'
            $txt | Should -Match 'Une API fiable'
            $txt | Should -Match 'Étape en cours de la feuille de route .*: E1 — Socle'
        }
    }
    It 'l''étape en cours suit la feuille de route' {
        [void](Set-StepState 'E1' 'fait')
        (Cahier-Block) | Should -Match 'E2'
        (Cahier-Block) | Should -Not -Match 'Étape en cours de la feuille de route .*: E1 — Socle'
    }
    It 'un cahier trop long est tronqué avec le chemin du fichier' {
        Set-Content (Wf-File 'CAHIER.md') ('x' * 6000) -Encoding utf8
        $b = Cahier-Block
        $b | Should -Match 'cahier tronqué'
        $b.Length | Should -BeLessThan 4200
    }
}

Describe 'Proposition au premier lancement' {
    It 'proposée une seule fois par session, jamais si refusée pour ce projet, jamais si un workflow existe' {
        [void](New-Project)
        $global:FlowNoAi = $false
        try {
            Workflow-Offer-Due | Should -BeTrue
            $global:FlowWfOffered = $true; Workflow-Offer-Due | Should -BeFalse
            $global:FlowWfOffered = $false
            $Cfg | Add-Member workflowDeclined $true -Force; Workflow-Offer-Due | Should -BeFalse
            $Cfg.workflowDeclined = $false
            New-Item -ItemType Directory -Force (Wf-Dir) | Out-Null; Save-WfMeta $false
            Workflow-Offer-Due | Should -BeFalse
        } finally { $global:FlowNoAi = $true }
    }
    It 'à l''accueil : « ne plus proposer » est retenu dans le profil du projet' {
        [void](New-Project)
        $global:FlowNoAi = $false
        function Open-Runs { @() }
        function Read-Prompt($x) { $null }
        try {
            $global:KeyQ.Enqueue('n')
            [void](Mode-Home)
            $global:Screens -join ' ' | Should -Match 'WORKFLOW'
            $Cfg.workflowDeclined | Should -BeTrue
            (Get-Content (Cfg-Path) -Raw | ConvertFrom-Json).workflowDeclined | Should -BeTrue
        } finally { $global:FlowNoAi = $true }
    }
    It 'à l''accueil : « plus tard » ne crée rien et ne refuse rien' {
        [void](New-Project)
        $global:FlowNoAi = $false
        function Open-Runs { @() }
        function Read-Prompt($x) { $null }
        try {
            $global:KeyQ.Enqueue('s')
            [void](Mode-Home)
            Wf-Exists | Should -BeFalse
            $Cfg.workflowDeclined | Should -BeNullOrEmpty
        } finally { $global:FlowNoAi = $true }
    }
}
