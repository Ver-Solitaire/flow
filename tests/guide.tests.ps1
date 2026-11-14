#Requires -Version 7
# Mode GUIDÉ : questions avant le plan, décisions au plan, ouvriers qui demandent, validation « c'est ce que tu voulais ? ».
# Aucun vrai Claude : les tâches de fond renvoient des réponses toutes prêtes ; les écrans sont remplacés par des réponses scriptées.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowguide-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode', 'RevJobs', 'GuidedPrefFile') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    $env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    $global:GuidedPrefFile = Join-Path $global:Base 'team-prefs.json'     # jamais les préférences réelles de l'utilisateur
    $global:FlowNoAi = $true

    Remove-Item Alias:cls -Force -ErrorAction SilentlyContinue
    function Notify { }
    function Cls { }
    function Show-Frame { }
    function Set-PaneState { }
    function Wait-Job-Spinner($job, [string]$label) { [void](Wait-Job $job); $rv = Receive-Job $job; Remove-Job $job -Force; $rv }
    function Git-Run([string]$dir, [string[]]$a) { & git -C $dir -c user.name=t -c user.email=t@t @a 2>&1 | Out-String }
    function Envelope([string]$json) { (@{ result = $json; is_error = $false } | ConvertTo-Json -Compress) }
    function New-DoneJob([string]$out) {
        $j = Start-Job -ScriptBlock { param($o) [pscustomobject]@{ Code = 0; Out = $o } } -ArgumentList $out
        [void](Wait-Job $j); $j
    }
    # réponses de « Claude », prises dans l'ordre (la dernière est répétée)
    $global:FakeQueue = [Collections.Generic.Queue[string]]::new()
    $global:FakeOut = ''
    function Start-ClaudeJob([string]$cwd, $acct, [string]$promptFile, [string]$model, [string]$tools) {
        $global:Prompts += , (Get-Content -LiteralPath $promptFile -Raw -Encoding utf8)
        New-DoneJob $(if ($global:FakeQueue.Count) { $global:FakeQueue.Dequeue() } else { $global:FakeOut })
    }
    # écrans : réponses scriptées
    $global:KeyQ = [Collections.Generic.Queue[string]]::new()
    $global:LineQ = [Collections.Generic.Queue[string]]::new()
    $global:Asked = @()
    function Message-Screen {
        param($title, $body, $keys)
        $global:Screens += "$title :: $($body -join ' | ')"
        $c = if ($global:KeyQ.Count) { $global:KeyQ.Dequeue() } else { 'enter' }
        if ($c -eq 'enter') { [pscustomobject]@{ Key = 'Enter'; KeyChar = [char]13 } } elseif ($c -eq 'esc') { [pscustomobject]@{ Key = 'Escape'; KeyChar = [char]27 } } else { [pscustomobject]@{ Key = $c.ToUpper(); KeyChar = [char]$c } }
    }
    function Read-Line([string]$title, [string]$prompt) { if ($global:LineQ.Count) { $global:LineQ.Dequeue() } else { $null } }
    function Read-KeyOrHint {
        $c = if ($global:KeyQ.Count) { $global:KeyQ.Dequeue() } else { 'esc' }
        if ($c -eq 'enter') { [pscustomobject]@{ Key = 'Enter'; KeyChar = [char]13; Modifiers = 0 } } elseif ($c -eq 'esc') { [pscustomobject]@{ Key = 'Escape'; KeyChar = [char]27; Modifiers = 0 } } else { [pscustomobject]@{ Key = $c.ToUpper(); KeyChar = [char]$c; Modifiers = 0 } }
    }

    function New-Fixture([string[]]$Ids) {
        $root = Join-Path $global:Base ([guid]::NewGuid().ToString('N').Substring(0, 6))
        $repo = Join-Path $root 'proj'
        New-Item -ItemType Directory -Force $repo | Out-Null
        [void](Git-Run $repo @('init', '-q', '-b', 'main'))
        Set-Content (Join-Path $repo 'base.txt') 'x'
        [void](Git-Run $repo @('add', '-A')); [void](Git-Run $repo @('commit', '-q', '-m', 'init'))
        $sha = (Git-Run $repo @('rev-parse', 'HEAD')).Trim()
        $global:RepoRoot = $repo
        $global:RunDir = Join-Path $repo '.flow\runs\T1'
        $global:WtRoot = Join-Path $root 'proj-flow\T1'
        New-Item -ItemType Directory -Force $global:RunDir, $global:WtRoot, (Join-Path $global:RunDir 'relectures') | Out-Null
        $tasks = foreach ($id in $Ids) {
            $wt = Join-Path $global:WtRoot $id
            [void](Git-Run $repo @('worktree', 'add', '-q', '-b', "flow/T1-$id", $wt, $sha))
            [pscustomobject]@{ id = $id; title = "Tâche $id"; goal = 'faire'; done = 'c''est fait'; status = 'done'; worktree = $wt; depends = @(); files = @("$id.txt"); account = ''; model = 'sonnet'; review = ''; reviews = 0 }
        }
        $global:State = [pscustomobject]@{
            id = 'T1'; prefix = 'flow/'; base = $sha; baseBranch = 'main'; summary = 'essai'; prompt = 'demande de test'; crossReview = $false; updated = ''; status = 'integrating'
            depth = 'full'; guided = $true; precisions = ''; planner = ''; brief = 'brief'; commitTitle = ''
            tasks = @($tasks)
            integration = [pscustomobject]@{ merged = @(); skipped = @(); conflict = ''; tests = $null; checks = @(); delivered = '' }
        }
        $global:Cfg = [pscustomobject]@{ checks = @(); setup = $null; commitStyle = 'libre' }
        $global:Psmux = $false
        $global:RevJobs = @{}
        $global:Prompts = @(); $global:Screens = @(); $global:Asked = @()
        $global:KeyQ.Clear(); $global:LineQ.Clear(); $global:FakeQueue.Clear()
        $global:FlowPrefill = ''; $global:FlowNextBase = ''
        $repo
    }
    function Commit-In([string]$id, [string]$name = "$id.txt") {
        $wt = Join-Path $global:WtRoot $id
        Set-Content (Join-Path $wt $name) "travail de $id"
        [void](Git-Run $wt @('add', '-A')); [void](Git-Run $wt @('commit', '-q', '-m', "tâche $id"))
    }
    $script:Questions = '{"questions":[{"question":"Pour qui est ce site ?","why":"le ton change","options":["Des clients","Des collègues"]},{"question":"Quel style ?","why":"","options":["Sobre","Coloré","Libre"]}]}'
}

AfterAll { Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Mode guidé : préférence et touches' {
    It 'la préférence est retenue d''un lancement à l''autre' {
        Save-GuidedPref $true
        Load-GuidedPref | Should -BeTrue
        Save-GuidedPref $false
        Load-GuidedPref | Should -BeFalse
    }
    It 'un clic sur « F7 » donne bien la touche F7 (et plus la lettre f)' {
        (Fake-Key 'F7').Key | Should -Be 'F7'
        (Fake-Key 'F4').Key | Should -Be 'F4'
        (Fake-Key 'F2').Key | Should -Be 'F2'
    }
}

Describe 'Questions du guide' {
    It 'le guide demande 4 à 8 questions au premier tour, au plus 4 au second, et connaît déjà les réponses' {
        [void](New-Fixture 'A')
        $p1 = Questioner-Prompt 1
        $p1 | Should -Match 'entre 4 et 8 questions'
        $p1 | Should -Match 'demande de test'
        $p1 | Should -Match '"questions"'
        $global:State.precisions = '- **Pour qui ?** → Des clients'
        $p2 = Questioner-Prompt 2
        $p2 | Should -Match 'au plus 4 questions'
        $p2 | Should -Match 'Des clients'
    }
    It 'les réponses sont mises en forme selon leur nature (choix, mots de l''utilisateur, « décide »)' {
        $qs = @([pscustomobject]@{ question = 'Q1'; options = @('a') }, [pscustomobject]@{ question = 'Q2'; options = @('b') }, [pscustomobject]@{ question = 'Q3'; options = @('c') })
        $ans = @(@{ a = 'a'; mode = 'option'; idx = 0 }, @{ a = 'mes mots'; mode = 'libre'; idx = -1 }, @{ a = 'c'; mode = 'délégué'; idx = 0 })
        $t = Format-Answers $qs $ans
        $t | Should -Match '\*\*Q1\*\* → a'
        $t | Should -Match 'mes mots \(réponse libre'
        $t | Should -Match 'te laisse décider ; option recommandée : c'
    }
    It 'les réponses vont dans l''état, un fichier de l''équipe, le brief et le prompt du planificateur' {
        [void](New-Fixture 'A')
        Add-Precisions '- **Pour qui ?** → Des clients'
        $global:State.precisions | Should -Match 'Des clients'
        (Get-Content (Join-Path $global:RunDir 'precisions.md') -Raw -Encoding utf8) | Should -Match 'Des clients'
        Write-TaskFiles
        (Get-Content (Join-Path $global:RunDir 'BRIEF.md') -Raw -Encoding utf8) | Should -Match 'Précisions de l.utilisateur'
        (Planner-Prompt 'x' '') | Should -Match 'RÉPONSES DE L.UTILISATEUR'
    }
    It 'la découverte pose les questions du guide, garde les réponses, et s''arrête quand il n''a plus rien à demander' {
        [void](New-Fixture 'A')
        $global:FakeQueue.Enqueue((Envelope $script:Questions))
        $global:FakeQueue.Enqueue((Envelope '{"questions":[]}'))
        function Ask-Questions($qs, [string]$title, [string]$intro = '') {
            $global:Asked += , @($qs).Count
            , @(@{ a = 'Des clients'; mode = 'option'; idx = 0 }, @{ a = 'Sobre'; mode = 'option'; idx = 0 })
        }
        Invoke-Discovery
        $global:Asked | Should -Be @(2)
        $global:Prompts.Count | Should -Be 2                       # tour 1 puis tour 2 (vide)
        $global:State.precisions | Should -Match 'Pour qui est ce site'
        $global:State.precisions | Should -Match 'Sobre'
    }
    It 'passer les questions (Échap) laisse la demande telle quelle' {
        [void](New-Fixture 'A')
        $global:FakeOut = Envelope $script:Questions
        function Ask-Questions($qs, [string]$title, [string]$intro = '') { $null }
        Invoke-Discovery
        "$($global:State.precisions)".Trim() | Should -Be ''
    }
}

Describe 'Ouvriers et plan en mode guidé' {
    It 'l''ouvrier guidé demande avant les choix importants ; l''ouvrier autonome décide seul' {
        [void](New-Fixture 'A')
        $t = Task-ById 'A'
        $g = Worker-Prompt $t
        $g | Should -Match 'MODE GUIDÉ'
        $g | Should -Not -Match 'Autonomie : décide'
        $global:State.guided = $false
        $a = Worker-Prompt $t
        $a | Should -Match 'Autonomie : décide'
        $a | Should -Not -Match 'MODE GUIDÉ'
    }
    It 'le planificateur guidé liste les décisions ouvertes ; hors mode guidé, pas de champ « questions »' {
        [void](New-Fixture 'A')
        (Planner-Prompt 'x' '') | Should -Match '"questions": \['
        $global:State.guided = $false
        (Planner-Prompt 'x' '') | Should -Not -Match '"questions": \['
    }
    It 'une décision du plan différente de la recommandation fait refaire le plan en la respectant (une seule fois)' {
        [void](New-Fixture 'A')
        $plan1 = '{"summary":"s","commitTitle":"t","brief":"b","depth":"full","questions":[{"question":"Base de données ?","why":"w","options":["SQLite","Postgres"]}],"tasks":[{"id":"A","title":"Faire","goal":"g","files":["a.txt"],"depends":[],"done":"d","model":"sonnet","why":"w"}]}'
        $plan2 = '{"summary":"s","commitTitle":"t","brief":"b2","depth":"full","questions":[],"tasks":[{"id":"A","title":"Faire avec Postgres","goal":"g","files":["a.txt"],"depends":[],"done":"d","model":"sonnet","why":"w"}]}'
        $global:FakeQueue.Enqueue((Envelope $plan1)); $global:FakeQueue.Enqueue((Envelope $plan2))
        function Ask-Questions($qs, [string]$title, [string]$intro = '') { , @(@{ a = 'Postgres'; mode = 'option'; idx = 1 }) }
        (Invoke-Planner '') | Should -BeTrue
        $global:Prompts.Count | Should -Be 2
        $global:Prompts[1] | Should -Match 'a tranché les décisions ouvertes'
        $global:Prompts[1] | Should -Match 'Postgres'
        $global:State.tasks[0].title | Should -Be 'Faire avec Postgres'
    }
    It 'une décision conforme à la recommandation ne refait pas le plan, et elle entre dans le brief' {
        [void](New-Fixture 'A')
        $plan1 = '{"summary":"s","commitTitle":"t","brief":"b","depth":"full","questions":[{"question":"Base de données ?","why":"w","options":["SQLite","Postgres"]}],"tasks":[{"id":"A","title":"Faire","goal":"g","files":["a.txt"],"depends":[],"done":"d","model":"sonnet","why":"w"}]}'
        $global:FakeQueue.Enqueue((Envelope $plan1))
        function Ask-Questions($qs, [string]$title, [string]$intro = '') { , @(@{ a = 'SQLite'; mode = 'option'; idx = 0 }) }
        (Invoke-Planner '') | Should -BeTrue
        $global:Prompts.Count | Should -Be 1
        $global:State.brief | Should -Match 'Décisions de l.utilisateur'
        $global:State.brief | Should -Match 'SQLite'
    }
}

Describe 'Validation guidée : « c''est bien ce que tu voulais ? »' {
    BeforeEach {
        [void](New-Fixture 'A')
        Commit-In 'A'
        [void](Mode-Integrate)
        $global:KeyQ.Clear(); $global:LineQ.Clear(); $global:Screens = @()
    }
    It '« presque » : l''équipe suivante repart du travail précédent, avec le retour de l''utilisateur' {
        $global:KeyQ.Enqueue('f')            # livrer…
        $global:KeyQ.Enqueue('p')            # …« presque »
        $global:LineQ.Enqueue('le titre est trop long')
        Mode-Review | Should -Be 'home'
        $global:FlowNextBase | Should -Be (Int-Branch)
        $global:FlowPrefill | Should -Match 'Ajuste le travail de l.équipe précédente'
        $global:FlowPrefill | Should -Match 'le titre est trop long'
        (Get-Content (Join-Path $global:RunDir 'retours.md') -Raw -Encoding utf8) | Should -Match 'le titre est trop long'
    }
    It '« non » : on repart de zéro, avec le retour de l''utilisateur' {
        $global:KeyQ.Enqueue('f'); $global:KeyQ.Enqueue('n')
        $global:LineQ.Enqueue('ce n''est pas du tout ça')
        Mode-Review | Should -Be 'home'
        $global:FlowNextBase | Should -Be ''
        $global:FlowPrefill | Should -Match 'Reprends cette demande'
        $global:FlowPrefill | Should -Match 'pas du tout ça'
    }
    It 'sans mode guidé, aucune question n''est posée avant la livraison' {
        $global:State.guided = $false
        $global:KeyQ.Enqueue('f')
        $global:Screens = @()
        # la livraison réelle n'est pas lancée : on vérifie seulement qu'aucun écran « guidé » n'a été montré
        function Deliver-Run { @{ Ok = $false; Info = 'stop' } }
        [void](Mode-Review)
        ($global:Screens -join "`n") | Should -Not -Match 'c.est bien ce que tu voulais'
    }
}
