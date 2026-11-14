#Requires -Version 7
# Journal des échanges entre les Claude de l'équipe et panneau « échanges ».

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowech-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    $global:FlowNoAi = $true      # rien n'est écrit dans la vraie mémoire de l'utilisateur
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    function Notify { }
    $global:Sent = [Collections.Generic.List[string]]::new()
    function Send-ToPane([string]$tag, [string]$text) { $global:Sent.Add("$tag|$text"); $true }
}

AfterAll { Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Journal des échanges' {
    It 'un message direct entre deux ouvriers est journalisé avec les deux comptes' {
        $global:RunDir = Join-Path $global:Base 'run1'
        New-Item -ItemType Directory -Force (Join-Path $global:RunDir 'annonces') | Out-Null
        $mk = { param($id, $acct) [pscustomobject]@{ id = $id; title = "Tâche $id"; status = 'running'; annLines = 0; annSeen = ''; account = $acct } }
        $global:State = [pscustomobject]@{ id = 'T1'; tasks = @((& $mk 'A' 'principal'), (& $mk 'B' 'second')) }
        Add-Content (Join-Path $global:RunDir 'annonces\A.md') '@B : renvoie une liste, pas un tuple' -Encoding utf8
        [void](Relay-Announcements (Task-ById 'A'))
        $e = Get-Content (Join-Path $global:RunDir 'echanges.jsonl') -Raw | ConvertFrom-Json
        $e.from | Should -Be 'A'; $e.fromAcct | Should -Be 'principal'
        $e.to | Should -Be 'B'; $e.toAcct | Should -Be 'second'
        $e.kind | Should -Be 'message'
        $e.text | Should -Match 'renvoie une liste'
    }
}

Describe 'flow-exchanges.ps1' {
    It 'affiche qui parle à qui, avec le nom court du compte, et ce qui a été dit' {
        $repo = Join-Path $global:Base 'projet'
        $run = Join-Path $repo '.flow\runs\20261114-090000'
        New-Item -ItemType Directory -Force $run | Out-Null
        $acc = Join-Path $global:Base 'accounts.json'
        Set-Content $acc '{ "accounts": [ { "id": "principal", "short": "C1", "color": "#ff8a5c" }, { "id": "second", "short": "C2", "color": "#54baff" } ] }'
        @(
            '{"t":"09:00:01","from":"FLOW","fromAcct":"","to":"A","toAcct":"principal","kind":"tâche","text":"tâche confiée (sonnet) : Réalisateur"}',
            '{"t":"09:01:10","from":"A","fromAcct":"principal","to":"B","toAcct":"second","kind":"message","text":"ta fonction doit renvoyer une liste"}',
            '{"t":"09:02:30","from":"second","fromAcct":"second","to":"A","toAcct":"principal","kind":"relecture","text":"1 point(s) à corriger — cas de la liste vide"}'
        ) | Set-Content (Join-Path $run 'echanges.jsonl') -Encoding utf8
        $out = (pwsh -NoProfile -File (Join-Path $global:FlowRoot 'tools\flow-exchanges.ps1') -Repo $repo -AccountsFile $acc -Once 2>&1 | Out-String) -replace "\x1b\[[0-9;]*m", ''
        $out | Should -Match 'ÉCHANGES ENTRE LES CLAUDE'
        $out | Should -Match 'message\s+C1·A\s+➜\s+C2·B'
        $out | Should -Match 'ta fonction doit renvoyer une liste'
        $out | Should -Match 'relecture\s+C2\s+➜\s+C1·A'
        $out | Should -Match 'tâche\s+FLOW\s+➜\s+C1·A'
    }
    It 'sans équipe, le dit simplement' {
        $out = (pwsh -NoProfile -File (Join-Path $global:FlowRoot 'tools\flow-exchanges.ps1') -Repo (Join-Path $global:Base 'rien') -AccountsFile (Join-Path $global:Base 'nulle.json') -Once 2>&1 | Out-String) -replace "\x1b\[[0-9;]*m", ''
        $out | Should -Match 'aucun échange'
    }
}
