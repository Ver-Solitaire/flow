#Requires -Version 7
# Mémoire de la façon de travailler (tools\flow-profile.ps1) : journal, conversations, usage, profil, écran « Mémoire ».
# Tout se passe dans un dossier d'essai : jamais le vrai dossier de l'utilisateur, jamais de vrai Claude.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowprofil-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode', 'RevJobs', 'GuidedPrefFile') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    $global:GuidedPrefFile = Join-Path $global:Base 'team-prefs.json'
    $global:FlowProfileDir = Join-Path $global:Base 'profil'
    $global:FlowNoAi = $true        # sans dossier d'essai explicite, rien ne serait écrit : ici il est explicite

    Remove-Item Alias:cls -Force -ErrorAction SilentlyContinue
    function Notify { }
    function Cls { }
    function Show-Frame { }
    function Set-PaneState { }
    function Wait-Job-Spinner($job, [string]$label) { [void](Wait-Job $job); $rv = Receive-Job $job; Remove-Job $job -Force; $rv }
    $global:Prompts = @()
    $global:JobScript = { param($cwd) [pscustomobject]@{ Code = 0; Out = '{"result":"{}"}' } }
    function Start-ClaudeJob([string]$cwd, $acct, [string]$promptFile, [string]$model, [string]$tools) {
        $global:Prompts += , (Get-Content -LiteralPath $promptFile -Raw -Encoding utf8)
        $j = Start-Job -ScriptBlock $global:JobScript -ArgumentList $cwd
        [void](Wait-Job $j); $j
    }
    $global:KeyQ = [Collections.Generic.Queue[string]]::new()
    function Read-KeyOrHint {
        $c = if ($global:KeyQ.Count) { $global:KeyQ.Dequeue() } else { 'esc' }
        if ($c -eq 'esc') { [pscustomobject]@{ Key = 'Escape'; KeyChar = [char]27 } } else { [pscustomobject]@{ Key = $c.ToUpper(); KeyChar = [char]$c } }
    }
    function Message-Screen { param($title, $body, $keys) $c = if ($global:KeyQ.Count) { $global:KeyQ.Dequeue() } else { 'esc' }; if ($c -eq 'esc') { [pscustomobject]@{ Key = 'Escape'; KeyChar = [char]27 } } else { [pscustomobject]@{ Key = $c.ToUpper(); KeyChar = [char]$c } } }

    function New-State {
        $global:RepoRoot = Join-Path $global:Base 'mon-projet'
        $global:RunDir = Join-Path $global:RepoRoot '.flow\runs\E1'
        New-Item -ItemType Directory -Force $global:RunDir | Out-Null
        $global:State = [pscustomobject]@{
            id = 'E1'; prefix = 'flow/'; summary = 'essai'; prompt = 'ajoute un export'; depth = 'full'; guided = $false; precisions = ''; brief = 'b'
            planner = ''; crossReview = $true; tasks = @([pscustomobject]@{ id = 'A'; title = 'Faire'; model = 'sonnet'; account = 'principal'; status = 'done'; review = 'ok'; reviews = 1; startedAt = (Get-Date).AddMinutes(-12).ToString('o'); worktree = '' })
            integration = [pscustomobject]@{ merged = @(); skipped = @(); conflict = ''; checks = @() }
        }
        $global:Cfg = [pscustomobject]@{ checks = @(); commitStyle = 'libre' }
        $global:Psmux = $false
        $global:Prompts = @()
        Remove-Item -LiteralPath $global:FlowProfileDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $global:GuidedPrefFile -Force -ErrorAction SilentlyContinue
        $global:KeyQ.Clear()
    }
    function Read-Events { $f = Join-Path $global:FlowProfileDir 'evenements.jsonl'; if (Test-Path $f) { @(Get-Content $f -Encoding utf8 | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
}

AfterAll { Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Secrets masqués' {
    It 'clés, jetons et mots de passe ne sont jamais écrits' {
        $t = Redact-Text 'clé sk-ant-api03-abcdefghijklmnopqrstuvwx et ghp_abcdefghijklmnopqrstuvwxyz0123 et password=Sup3rSecret! et "token": "abcdef123456"'
        $t | Should -Not -Match 'sk-ant'
        $t | Should -Not -Match 'ghp_abc'
        $t | Should -Not -Match 'Sup3rSecret'
        $t | Should -Not -Match 'abcdef123456'
        $t | Should -Match '«secret»'
    }
    It 'laisse intact un texte ordinaire' {
        Redact-Text 'Ajoute un export en PDF, sobre, pour des clients.' | Should -Be 'Ajoute un export en PDF, sobre, pour des clients.'
    }
}

Describe 'Journal d''activité' {
    It 'écrit un événement horodaté avec le projet et l''équipe, secrets masqués' {
        New-State
        Write-Event 'demande' @{ texte = 'mon mot de passe est password=Abcdef123 merci'; guide = $true }
        $e = @(Read-Events)
        $e.Count | Should -Be 1
        $e[0].type | Should -Be 'demande'
        $e[0].projet | Should -Be 'mon-projet'
        $e[0].equipe | Should -Be 'E1'
        $e[0].t | Should -Not -BeNullOrEmpty
        $e[0].texte | Should -Not -Match 'Abcdef123'
    }
    It 'ne fait rien quand la collecte est coupée' {
        New-State
        Set-Pref 'collecte' $false
        Write-Event 'demande' @{ texte = 'x' }
        @(Read-Events).Count | Should -Be 0
    }
    It 'n''écrit jamais dans le vrai dossier pendant les tests (sans dossier d''essai explicite)' {
        $keep = $global:FlowProfileDir
        $global:FlowProfileDir = $null
        try { Profile-Off | Should -BeTrue } finally { $global:FlowProfileDir = $keep }
    }
    It 'les échanges entre Claude sont aussi journalisés' {
        New-State
        Write-Exchange 'Toi' 'A' 'message' 'plutôt sobre, sans couleurs' '' 'principal'
        $e = @(Read-Events | Where-Object { $_.type -eq 'echange' })
        $e.Count | Should -Be 1
        $e[0].de | Should -Be 'Toi'
        $e[0].texte | Should -Match 'sobre'
    }
    It 'les réponses guidées sont journalisées avec leur nature' {
        New-State
        $qs = @([pscustomobject]@{ question = 'Quel style ?'; options = @('Sobre', 'Coloré') })
        Log-Answers $qs @(@{ a = 'Coloré'; mode = 'option'; idx = 1 }) 'avant_plan'
        $e = @(Read-Events)[0]
        $e.type | Should -Be 'reponse_guidee'
        $e.reponse | Should -Be 'Coloré'
        $e.recommandee | Should -BeFalse
        $e.phase | Should -Be 'avant_plan'
    }
    It 'les changements faits dans le plan sont repérés' {
        New-State
        $State | Add-Member planOrig @([pscustomobject]@{ id = 'A'; title = 'Faire'; model = 'sonnet'; account = 'principal' }, [pscustomobject]@{ id = 'B'; title = 'Doc'; model = 'haiku'; account = 'principal' }) -Force
        $State.tasks[0].model = 'opus'
        $c = (Plan-Changes) -join ' | '
        $c | Should -Match 'modèle sonnet → opus'
        $c | Should -Match 'tâche B retirée'
    }
    It 'le coût et les jetons d''un appel Claude sont relevés' {
        New-State
        Log-Call 'planificateur' ([pscustomobject]@{ Id = 'principal' }) 'opus' ([pscustomobject]@{ Out = '{"result":"x","is_error":false,"duration_ms":4200,"num_turns":3,"total_cost_usd":0.12,"usage":{"input_tokens":1500,"output_tokens":300,"cache_read_input_tokens":9000}}' })
        $e = @(Read-Events)[0]
        $e.type | Should -Be 'appel_claude'
        $e.role | Should -Be 'planificateur'
        $e.cout_usd | Should -Be 0.12
        $e.entrees | Should -Be 1500
        $e.sorties | Should -Be 300
    }
}

Describe 'Conversations et usage des ouvriers' {
    BeforeAll {
        $script:Transcript = Join-Path $global:Base 'conv.jsonl'
        @(
            '{"type":"user","timestamp":"2026-11-14T10:00:00Z","message":{"role":"user","content":"fais un export"}}',
            '{"type":"assistant","timestamp":"2026-11-14T10:02:00Z","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":10,"cache_read_input_tokens":500},"content":[{"type":"text","text":"ok"},{"type":"tool_use","name":"Read"}]}}',
            '{"type":"assistant","timestamp":"2026-11-14T10:10:00Z","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":200,"output_tokens":80},"content":[{"type":"tool_use","name":"Edit"},{"type":"tool_use","name":"Bash"}]}}',
            '{"type":"user","timestamp":"2026-11-14T10:11:00Z","message":{"role":"user","content":"voici ma clé sk-ant-api03-abcdefghijklmnopqrstuvwx"}}'
        ) | Set-Content $script:Transcript -Encoding utf8
    }
    It 'compte jetons, outils, interventions et durée' {
        $u = Transcript-Usage $script:Transcript
        $u.entrees | Should -Be 300
        $u.sorties | Should -Be 130
        $u.cache_lecture | Should -Be 500
        $u.outils | Should -Be 3
        $u.messages_utilisateur | Should -Be 2
        $u.minutes | Should -Be 11
        $u.modeles | Should -Contain 'claude-sonnet-5-5'
    }
    It 'archive la conversation avec les secrets masqués, et seulement si l''utilisateur le veut' {
        New-State
        $dest = Archive-Transcript $script:Transcript 'A-sonnet'
        Test-Path $dest | Should -BeTrue
        (Get-Content $dest -Raw -Encoding utf8) | Should -Not -Match 'sk-ant'
        (Get-Content $dest -Raw -Encoding utf8) | Should -Match 'fais un export'
        Set-Pref 'conversations' $false
        Archive-Transcript $script:Transcript 'B' | Should -BeNullOrEmpty
    }
    It 'la fin d''une tâche journalise durée, jetons et conversation' {
        New-State
        function Worker-Transcript($t) { $script:Transcript }
        Log-TaskDone (Task-ById 'A')
        $e = @(Read-Events | Where-Object { $_.type -eq 'tache_terminee' })[0]
        $e.tache | Should -Be 'A'
        $e.minutes | Should -BeGreaterOrEqual 11
        $e.usage.entrees | Should -Be 300
        Test-Path $e.conversation | Should -BeTrue
    }
}

Describe 'Profil transmis aux Claude' {
    It 'sans profil, rien n''est ajouté aux consignes' {
        New-State
        Profile-Block | Should -Be ''
        (Planner-Prompt 'x' '') | Should -Not -Match 'Profil de travail de l.utilisateur'
    }
    It 'avec un profil, le planificateur, le guide et les ouvriers le reçoivent comme des hypothèses' {
        New-State
        New-Item -ItemType Directory -Force $global:FlowProfileDir | Out-Null
        Set-Content (Join-Path $global:FlowProfileDir 'profil.md') "# Profil de travail`n- Préfère les interfaces sobres (observé 5 fois)" -Encoding utf8
        foreach ($txt in (Planner-Prompt 'x' ''), (Questioner-Prompt 1), (Worker-Prompt ([pscustomobject]@{ id = 'A'; title = 't'; worktree = $global:RepoRoot; model = 'sonnet' }))) {
            $txt | Should -Match 'Profil de travail de l.utilisateur'
            $txt | Should -Match 'interfaces sobres'
            $txt | Should -Match 'HYPOTHÈSES'
        }
    }
    It 'le profil est tronqué s''il est trop long, et coupé si l''utilisateur le décide' {
        New-State
        New-Item -ItemType Directory -Force $global:FlowProfileDir | Out-Null
        Set-Content (Join-Path $global:FlowProfileDir 'profil.md') ('ligne ' * 2000) -Encoding utf8
        (Profile-Text 500).Length | Should -BeLessThan 560
        Set-Pref 'profil' $false
        Profile-Text | Should -Be ''
    }
}

Describe 'Mise à jour du profil' {
    It 'rien à faire sans événements, ni avec trop peu de nouveautés' {
        New-State
        Update-Profile | Should -BeFalse
        Write-Event 'demande' @{ texte = 'a' }
        Update-Profile | Should -BeFalse
        $global:Prompts.Count | Should -Be 0
    }
    It 'envoie au profileur seulement les événements qui disent comment l''utilisateur travaille, et retient où il en est' {
        New-State
        1..3 | ForEach-Object { Write-Event 'demande' @{ texte = "demande $_" } }
        Write-Event 'appel_claude' @{ role = 'relecture'; entrees = 5 }
        Write-Event 'echange' @{ genre = 'annonce'; de = 'A'; texte = 'bruit technique' }
        Write-Event 'echange' @{ genre = 'message'; de = 'Toi'; texte = 'plutôt sobre' }
        Write-Event 'validation' @{ choix = 'presque'; retour = 'titre trop long' }
        $global:JobScript = { param($cwd) Set-Content (Join-Path $cwd 'profil.md') "# Profil de travail`nMis à jour : test" -Encoding utf8; [pscustomobject]@{ Code = 0; Out = '{"result":"{}"}' } }
        Update-Profile | Should -BeTrue
        $extract = Get-Content (Join-Path $global:FlowProfileDir 'nouveaux-evenements.jsonl') -Raw -Encoding utf8
        $extract | Should -Match 'demande 1'
        $extract | Should -Match 'plutôt sobre'
        $extract | Should -Match 'titre trop long'
        $extract | Should -Not -Match 'bruit technique'
        $extract | Should -Not -Match 'appel_claude'
        $global:Prompts[0] | Should -Match 'PROFILEUR'
        (Test-Path (Join-Path $global:FlowProfileDir 'profil.md')) | Should -BeTrue
        (Profile-State).lastLine | Should -BeGreaterThan 5
        # rien de nouveau : pas de second appel
        $global:Prompts = @()
        Update-Profile | Should -BeFalse
        $global:Prompts.Count | Should -Be 0
        $global:JobScript = { param($cwd) [pscustomobject]@{ Code = 0; Out = '{"result":"{}"}' } }
    }
    It 'les statistiques résument journal, usage et conversations' {
        New-State
        Write-Event 'demande' @{ texte = 'a' }
        Write-Event 'appel_claude' @{ role = 'juge'; entrees = 2000; sorties = 500; cout_usd = 0.3 }
        $s = Profile-Stats
        $s.Evenements | Should -Be 2
        $s.Equipes | Should -Be 1
        $s.Appels | Should -Be 1
        $s.JetonsEntree | Should -Be 2000
        $s.Types | Should -Contain 'demande 1'
    }
}

Describe 'Écran Mémoire' {
    It 'les interrupteurs changent les réglages, Échap revient en arrière' {
        New-State
        $global:KeyQ.Enqueue('c'); $global:KeyQ.Enqueue('v'); $global:KeyQ.Enqueue('i')
        Mode-Memory | Should -Be 'quit'
        $p = Get-Prefs
        $p.collecte | Should -BeFalse
        $p.conversations | Should -BeFalse
        $p.profil | Should -BeFalse
    }
    It 'tout effacer demande confirmation, puis supprime le dossier de la mémoire (et lui seul)' {
        New-State
        Write-Event 'demande' @{ texte = 'a' }
        Test-Path $global:FlowProfileDir | Should -BeTrue
        $global:KeyQ.Enqueue('x'); $global:KeyQ.Enqueue('esc')      # confirmation refusée
        Mode-Memory | Out-Null
        Test-Path $global:FlowProfileDir | Should -BeTrue
        $global:KeyQ.Enqueue('x'); $global:KeyQ.Enqueue('o')        # confirmation donnée
        Mode-Memory | Out-Null
        Test-Path $global:FlowProfileDir | Should -BeFalse
        Test-Path $global:Base | Should -BeTrue
    }
}
