#Requires -Version 7
# Équipe autonome : toujours en équipe, messages directs entre ouvriers, consignes.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowauto-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    $global:FlowNoAi = $true      # rien n'est écrit dans la vraie mémoire de l'utilisateur
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode', 'RevJobs') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    function Notify { }
    $global:Sent = [Collections.Generic.List[string]]::new()
    function Send-ToPane([string]$tag, [string]$text) { $global:Sent.Add("$tag|$text"); $true }
    function New-Team {
        $global:RunDir = Join-Path $global:Base ([guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force (Join-Path $global:RunDir 'annonces') | Out-Null
        $mk = { param($id, $st) [pscustomobject]@{ id = $id; title = "Tâche $id"; status = $st; annLines = 0; annSeen = '' } }
        $global:State = [pscustomobject]@{ id = 'T1'; tasks = @((& $mk 'A' 'running'), (& $mk 'B' 'running'), (& $mk 'C' 'running'), (& $mk 'D' 'done')) }
        $global:Sent.Clear()
    }
}

AfterAll { Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Relay-Announcements : messages directs entre ouvriers' {
    It 'une ligne « @B : … » ne va qu''à B' {
        New-Team
        Add-Content (Join-Path $global:RunDir 'annonces\A.md') '12:00 — @B : ta fonction doit renvoyer une liste' -Encoding utf8
        Relay-Announcements (Task-ById 'A') | Should -Be 1
        $global:Sent.Count | Should -Be 1
        $global:Sent[0] | Should -Match '^B\|\[FLOW\] Message de l''ouvrier A .*ta fonction doit renvoyer une liste'
        $global:Sent[0] | Should -Match '@A :'          # il sait comment répondre
    }
    It 'une ligne sans @ va à tous les ouvriers encore au travail (pas à l''auteur, pas aux tâches finies)' {
        New-Team
        Add-Content (Join-Path $global:RunDir 'annonces\A.md') '12:01 — le fichier de données s''appelle taches.json' -Encoding utf8
        [void](Relay-Announcements (Task-ById 'A'))
        @($global:Sent | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object) | Should -Be @('B', 'C')
    }
    It 'ne retransmet jamais deux fois une ligne déjà vue' {
        New-Team
        $f = Join-Path $global:RunDir 'annonces\A.md'
        Add-Content $f '@C : première' -Encoding utf8
        [void](Relay-Announcements (Task-ById 'A'))
        Relay-Announcements (Task-ById 'A') | Should -Be 0
        Add-Content $f '@C : seconde' -Encoding utf8
        Relay-Announcements (Task-ById 'A') | Should -Be 1
        $global:Sent.Count | Should -Be 2
    }
    It 'un « @ » qui ne désigne aucune tâche (adresse, mention) est traité comme une annonce pour tous' {
        New-Team
        Add-Content (Join-Path $global:RunDir 'annonces\A.md') 'contact : moi@exemple.ch pour la clé' -Encoding utf8
        [void](Relay-Announcements (Task-ById 'A'))
        @($global:Sent | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object) | Should -Be @('B', 'C')
    }
}

Describe 'Consignes de l''équipe autonome' {
    It 'le planificateur compose toujours une équipe, par rôles quand la demande est petite' {
        $global:State = [pscustomobject]@{ id = 'T1' }
        $global:RepoRoot = $global:Base; $global:MaxTasks = 4
        $p = Planner-Prompt 'corrige une faute dans le README' ''
        $p | Should -Match 'TOUJOURS une équipe'
        $p | Should -Match 'RÔLES'
        $p | Should -Match 'testeur'
    }
    It 'les ouvriers ont toutes les permissions d''avance (aucune demande de permission)' {
        $WorkerArgs | Should -Match 'permission-mode bypassPermissions'
    }
    It 'le profil Équipe donne aussi toutes les permissions à ses Claude' {
        $p = Get-Content (Join-Path $global:FlowRoot 'profiles\equipe.json') -Raw | ConvertFrom-Json
        $cl = @($p.rows.panes | Where-Object { $_.role -eq 'claude' })
        $cl.Count | Should -BeGreaterThan 0
        foreach ($c in $cl) { $c.args | Should -Match 'bypassPermissions' }
    }
}
