#Requires -Version 7
# Qualité du travail d'équipe : passe légère / complète, garde-fous, contre-vérification des relectures, fichiers protégés, scribe et juge.
# Aucun vrai Claude n'est lancé : les tâches de fond sont remplacées par des réponses toutes prêtes.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowqual-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode', 'RevJobs') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    $env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    $global:FlowNoAi = $true

    Remove-Item Alias:cls -Force -ErrorAction SilentlyContinue
    function Notify { }
    function Cls { }
    function Show-Frame { }
    function Set-PaneState { }
    function Send-ToPane { $global:Sent += , ($args -join ' '); $true }
    function Wait-Job-Spinner($job, [string]$label) { [void](Wait-Job $job); $rv = Receive-Job $job; Remove-Job $job -Force; $rv }
    function Git-Run([string]$dir, [string[]]$a) { & git -C $dir -c user.name=t -c user.email=t@t @a 2>&1 | Out-String }
    function Envelope([string]$json) { (@{ result = $json; is_error = $false } | ConvertTo-Json -Compress) }
    function New-DoneJob([string]$out) {
        $j = Start-Job -ScriptBlock { param($o) [pscustomobject]@{ Code = 0; Out = $o } } -ArgumentList $out
        [void](Wait-Job $j); $j
    }
    # remplace le lancement de Claude : la réponse est choisie par chaque test
    $global:FakeOut = ''
    function Start-ClaudeJob([string]$cwd, $acct, [string]$promptFile, [string]$model, [string]$tools) { New-DoneJob $global:FakeOut }

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
            id = 'T1'; prefix = 'flow/'; base = $sha; baseBranch = 'main'; summary = 'essai'; prompt = 'demande de test'; crossReview = $true; updated = ''; status = 'integrating'; depth = 'full'
            tasks = @($tasks)
            integration = [pscustomobject]@{ merged = @(); skipped = @(); conflict = ''; tests = $null; checks = @(); delivered = '' }
        }
        $global:Cfg = [pscustomobject]@{ checks = @(); setup = $null; commitStyle = 'libre' }
        $global:Psmux = $false
        $global:RevJobs = @{}
        $global:Sent = @()
        $repo
    }
    function Commit-In([string]$id, [string]$name = "$id.txt") {
        $wt = Join-Path $global:WtRoot $id
        $dir = Split-Path (Join-Path $wt $name) -Parent
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content (Join-Path $wt $name) "travail de $id"
        [void](Git-Run $wt @('add', '-A')); [void](Git-Run $wt @('commit', '-q', '-m', "tâche $id"))
    }
    # une relecture déjà « rendue » pour la tâche A, prête à être lue par Check-Reviews
    function Add-ReviewJob([string]$issuesJson) {
        $out = Envelope ('{"verdict":"changes","summary":"à revoir","issues":[' + $issuesJson + ']}')
        $global:RevJobs = @{ A = [pscustomobject]@{ Job = (New-DoneJob $out); Model = 'sonnet'; Acct = [pscustomobject]@{ Id = 'principal'; Label = 'Compte 1'; Short = 'C1' }; Round = 1; Start = Get-Date } }
    }
    $script:Issue = '{"severity":"bloquant","angle":"logique","file":"a.txt","problem":"division par zéro","scenario":"liste vide → plantage","fix":"tester la liste"}'
}

AfterAll { $global:FlowNoAi = $true; Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Passe légère ou complète' {
    It 'est complète par défaut (équipes anciennes comprises) et légère seulement si l''état le dit' {
        [void](New-Fixture 'A')
        $global:State.PSObject.Properties.Remove('depth')
        Depth | Should -Be 'full'
        $global:State | Add-Member depth 'light' -Force
        Depth | Should -Be 'light'
        Depth-Label | Should -Be 'légère'
    }
    It 'le planificateur choisit la passe dans son JSON' {
        [void](New-Fixture 'A')
        $p = Planner-Prompt 'une demande' ''
        $p | Should -Match '"depth": "light \| full"'
        $p | Should -Match 'En cas de doute : "full"'
    }
    It 'la relecture complète a 5 angles ; la légère en a 2, sans les problèmes mineurs' {
        [void](New-Fixture 'A')
        $t = Task-ById 'A'
        $full = Review-Prompt $t (Join-Path $global:RunDir 'a.diff') 1
        $full | Should -Match 'donnees'
        $full | Should -Match 'logique'
        $full | Should -Match 'SCÉNARIO'
        $global:State | Add-Member depth 'light' -Force
        $light = Review-Prompt $t (Join-Path $global:RunDir 'a.diff') 1
        $light | Should -Match 'conformite'
        $light | Should -Not -Match 'donnees'
        $light | Should -Match 'PASSE LÉGÈRE'
    }
}

Describe 'Garde-fous transmis à chaque Claude' {
    It 'ouvriers, relecteurs et intégrateur les reçoivent, avec les règles propres au projet' {
        [void](New-Fixture 'A')
        $global:Cfg | Add-Member protectedPaths @('data/reel') -Force
        $global:Cfg | Add-Member guardrails @('Ne jamais toucher à la base de production.') -Force
        $t = Task-ById 'A'
        foreach ($txt in (Worker-Prompt $t), (Integrator-Prompt $t @('a.txt')), (Review-Prompt $t 'x.diff' 1)) {
            $txt | Should -Match 'Garde-fous'
            $txt | Should -Match 'secret'
            $txt | Should -Match 'data/reel'
            $txt | Should -Match 'base de production'
        }
        (Worker-Prompt $t) | Should -Match 'plus petite modification'
        (Worker-Prompt $t) | Should -Match 'jamais « vert »'
    }
}

Describe 'Relecture : contre-vérification des problèmes graves' {
    BeforeEach { $global:FlowNoAi = $false }
    AfterAll { $global:FlowNoAi = $true }

    It 'un problème grave est d''abord contre-vérifié : l''ouvrier n''est pas dérangé tant que le verdict n''est pas rendu' {
        [void](New-Fixture 'A')
        Add-ReviewJob $script:Issue
        $global:FakeOut = Envelope '{"verdicts":[{"n":1,"real":false,"reason":"la liste n''est jamais vide ici","correctedFix":""}]}'
        $note = Check-Reviews
        $global:RevJobs['A'].Phase | Should -Be 'verify'
        $global:Sent.Count | Should -Be 0
        "$note" | Should -Match 'contre-vérification'
    }
    It 'un problème réfuté ne dérange pas l''ouvrier : la tâche est relue' {
        [void](New-Fixture 'A')
        Add-ReviewJob $script:Issue
        $global:FakeOut = Envelope '{"verdicts":[{"n":1,"real":false,"reason":"la liste n''est jamais vide ici","correctedFix":""}]}'
        [void](Check-Reviews)          # relecture → contre-vérification lancée
        [void](Check-Reviews)          # contre-vérification rendue
        (Task-ById 'A').review | Should -Be 'ok'
        $global:Sent.Count | Should -Be 0
        $global:RevJobs.Count | Should -Be 0
        (Get-Content (Review-File 'A') -Raw -Encoding utf8) | Should -Match 'réfuté'
    }
    It 'un problème confirmé est renvoyé à l''ouvrier, avec la correction corrigée par le vérificateur' {
        [void](New-Fixture 'A')
        Add-ReviewJob $script:Issue
        $global:FakeOut = Envelope '{"verdicts":[{"n":1,"real":true,"reason":"le plantage est réel","correctedFix":"retourner 0 si la liste est vide"}]}'
        [void](Check-Reviews); [void](Check-Reviews)
        (Task-ById 'A').review | Should -Be 'changes'
        $global:Sent.Count | Should -Be 1
        $global:Sent[0] | Should -Match 'confirmés par une contre-vérification'
        (Get-Content (Review-File 'A') -Raw -Encoding utf8) | Should -Match 'retourner 0 si la liste est vide'
    }
    It 'une contre-vérification illisible ne fait pas disparaître les problèmes' {
        [void](New-Fixture 'A')
        Add-ReviewJob $script:Issue
        $global:FakeOut = 'pas du JSON'
        [void](Check-Reviews); [void](Check-Reviews)
        (Task-ById 'A').review | Should -Be 'changes'
        $global:Sent.Count | Should -Be 1
    }
    It 'passe légère : pas de contre-vérification, les corrections partent tout de suite' {
        [void](New-Fixture 'A')
        $global:State | Add-Member depth 'light' -Force
        Add-ReviewJob $script:Issue
        [void](Check-Reviews)
        $global:RevJobs.Count | Should -Be 0
        (Task-ById 'A').review | Should -Be 'changes'
        $global:Sent.Count | Should -Be 1
    }
    It 'un problème seulement mineur ne déclenche rien' {
        [void](New-Fixture 'A')
        Add-ReviewJob '{"severity":"mineur","angle":"logique","file":"a.txt","problem":"nom bizarre","scenario":"-","fix":"renommer"}'
        [void](Check-Reviews)
        $global:RevJobs.Count | Should -Be 0
        (Task-ById 'A').review | Should -Be 'ok'
    }
}

Describe 'Fichiers protégés (données réelles)' {
    It 'l''intégration signale une équipe qui a modifié un chemin protégé' {
        [void](New-Fixture 'A')
        $global:Cfg | Add-Member protectedPaths @('data') -Force
        Commit-In 'A' 'data\reel.json'
        Mode-Integrate | Should -Be 'review'
        $c = @($global:State.integration.checks | Where-Object { $_.name -eq 'fichiers protégés' })
        $c.Count | Should -Be 1
        $c[0].ok | Should -BeFalse
        ($c[0].tail -join ' ') | Should -Match 'data/reel.json'
    }
    It 'rien à signaler quand l''équipe n''y touche pas' {
        [void](New-Fixture 'A')
        $global:Cfg | Add-Member protectedPaths @('data') -Force
        Commit-In 'A' 'src\code.txt'
        [void](Mode-Integrate)
        @($global:State.integration.checks | Where-Object { $_.name -eq 'fichiers protégés' })[0].ok | Should -BeTrue
    }
}

Describe 'Scribe : mémoire du projet tenue à jour' {
    BeforeEach { $global:FlowNoAi = $false }
    AfterAll { $global:FlowNoAi = $true }

    It 'ne fait rien sans dossier memoire\ dans le projet' {
        [void](New-Fixture 'A')
        $iw = Join-Path $global:WtRoot '_integration'
        [void](Git-Run $global:RepoRoot @('worktree', 'add', '-q', '-b', 'flow/T1', $iw, $global:State.base))
        Scribe-On $iw | Should -BeFalse
        Invoke-Scribe $iw
        $global:State.integration.scribe | Should -Be 'non'
    }
    It 'commite seulement ce qui est dans memoire\ et retire le reste' {
        [void](New-Fixture 'A')
        $iw = Join-Path $global:WtRoot '_integration'
        [void](Git-Run $global:RepoRoot @('worktree', 'add', '-q', '-b', 'flow/T1', $iw, $global:State.base))
        New-Item -ItemType Directory -Force (Join-Path $iw 'memoire') | Out-Null
        Set-Content (Join-Path $iw 'memoire\INDEX.md') 'index'
        Set-Content (Join-Path $iw 'memoire\etat-actuel.md') 'ancien état'
        [void](Git-Run $iw @('add', '-A')); [void](Git-Run $iw @('commit', '-q', '-m', 'memoire'))
        Scribe-On $iw | Should -BeTrue
        # le « scribe » met à jour la fiche… et touche aussi, à tort, à un fichier du projet
        function Start-ClaudeJob([string]$cwd, $acct, [string]$promptFile, [string]$model, [string]$tools) {
            $j = Start-Job -ScriptBlock { param($d) Set-Content "$d\memoire\etat-actuel.md" 'nouvel état'; Set-Content "$d\base.txt" 'altéré'
                [pscustomobject]@{ Code = 0; Out = '{"result":"{}"}' } } -ArgumentList $cwd
            [void](Wait-Job $j); $j
        }
        Invoke-Scribe $iw
        $global:State.integration.scribe | Should -Match '^ok:'
        (Get-Content (Join-Path $iw 'memoire\etat-actuel.md') -Raw).Trim() | Should -Be 'nouvel état'
        (Get-Content (Join-Path $iw 'base.txt') -Raw).Trim() | Should -Be 'x'
        (Git-Run $iw @('log', '-1', '--format=%s')).Trim() | Should -Match 'mémoire du projet mise à jour'
        @((Git-Run $iw @('status', '--porcelain')) -split "`n" | Where-Object { $_.Trim() }).Count | Should -Be 0
    }
}

Describe 'Juge final' {
    BeforeEach { $global:FlowNoAi = $false }
    AfterAll { $global:FlowNoAi = $true }

    It 'seulement en passe complète' {
        [void](New-Fixture 'A')
        Judge-On | Should -BeTrue
        $global:State | Add-Member depth 'light' -Force
        Judge-On | Should -BeFalse
    }
    It 'garde le verdict, les critères non remplis et ce que le juge a revérifié' {
        [void](New-Fixture 'A')
        Commit-In 'A'
        $global:FlowNoAi = $true; [void](Mode-Integrate); $global:FlowNoAi = $false
        $iw = Join-Path $global:WtRoot '_integration'
        $global:FakeOut = Envelope '{"ok":false,"summary":"un critère manque","unmet":["tâche A : aucun test"],"rechecked":"verifications.txt, 12 tests"}'
        Invoke-Judge $iw
        $j = $global:State.integration.judge
        $j.ok | Should -BeFalse
        $j.unmet | Should -Contain 'tâche A : aucun test'
        $j.rechecked | Should -Match '12 tests'
    }
    It 'une réponse illisible donne « pas de verdict », jamais « réussi »' {
        [void](New-Fixture 'A')
        $global:FakeOut = 'n''importe quoi'
        Invoke-Judge (Join-Path $global:WtRoot '_integration')
        $global:State.integration.judge.ok | Should -BeNullOrEmpty
        $global:State.integration.judge.summary | Should -Match 'illisible'
    }
}
