#Requires -Version 7
# Surveillance des ouvriers (tools\flow-watch.ps1) : questions, permissions, confiance, limites, connexion, silence ; journal attentes.md.
# Les écrans de test sont des copies de vrais écrans de Claude Code capturés pendant l'essai « budget-cli ».

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowwatch-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode', 'RevJobs', 'GuidedPrefFile', 'Sock') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    $global:Screen = ''; $global:Keys = @()
    function Find-Pane([string]$tag) { 'win.1' }
    function psmux { $a = @($args); if ($a -contains 'capture-pane') { $global:Screen -split "`n" } elseif ($a -contains 'send-keys') { $global:Keys += $a[-1] } }
    function Write-Event([string]$kind, $data) { $global:Events += "$kind" }
    $global:Psmux = $true; $global:Sock = 'flow'
    $global:RunDir = Join-Path $global:Base 'run'; New-Item -ItemType Directory -Force $global:RunDir | Out-Null
    $global:State = [pscustomobject]@{ id = '20261114-234302' }
    $global:Task = [pscustomobject]@{ id = 'D'; worktree = 'C:\proj-flow\20261114-234302\D'; live = 'working' }
    $global:Events = @()

    $global:TrustScreen = "Accessing workspace:`n C:\proj-flow\20261114-234302\D`n Quick safety check: Is this a project you created or one you trust?`n ❯ No, exit`n   Yes, I trust this folder`n Enter to confirm · Esc to cancel"
    $global:AskScreen = "│ Pester 5 n'est pas installé (seul Pester 3.4.0 est présent). Sans lui, je ne peux pas lancer`n│ Invoke-Pester -CI, donc ni valider la tâche D ni livrer. Comment procéder ?`n❯ 1. Installer pour l'utilisateur (Recommandé)`n  2. Module portable dans un dossier temporaire`n  3. Ne pas installer`nEnter to select · ↑/↓ to navigate · Esc to cancel"
    $global:PermScreen = "Edit file src/x.ps1`n Do you want to make this edit to x.ps1?`n ❯ 1. Yes`n   2. Yes, and don't ask again this session`n   3. No`nEsc to cancel"
    $global:Normal = "✻ Undulating… (15s · ↓ 466 tokens · thinking)`n❯`n  ◆ Opus 5.5 · ctx 6% · semaine 12%`n  ⏵⏵ bypass permissions on (shift+tab to cycle)"
}
AfterAll { Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Reconnaître ce que dit l''écran d''un ouvrier' {
    It 'confiance dans le dossier' { (Classify-Screen $global:TrustScreen).Kind | Should -Be 'confiance' }
    It 'question posée à l''utilisateur : la question est extraite' {
        $c = Classify-Screen $global:AskScreen
        $c.Kind | Should -Be 'question'
        $c.Text | Should -Match 'Comment procéder \?'
    }
    It 'demande de permission' {
        $c = Classify-Screen $global:PermScreen
        $c.Kind | Should -Be 'permission'
        $c.Text | Should -Match 'make this edit'
    }
    It 'limite d''usage et compte déconnecté' {
        (Classify-Screen "Claude usage limit reached. Your limit will reset at 3pm").Kind | Should -Be 'limite'
        (Classify-Screen "Invalid API key · Please run /login").Kind | Should -Be 'connexion'
    }
    It 'écran normal, vide ou nul : rien de bloquant (« bypass permissions on » n''est pas une permission demandée)' {
        Classify-Screen $global:Normal | Should -BeNullOrEmpty
        Classify-Screen '' | Should -BeNullOrEmpty
        Classify-Screen $null | Should -BeNullOrEmpty
    }
}

Describe 'Surveiller un ouvrier' {
    BeforeEach {
        $script:Blockers = @{}; $script:WatchSeen = @{}; $global:Keys = @(); $global:Events = @()
        Remove-Item (Attentes-File) -Force -ErrorAction SilentlyContinue
        $global:Task.live = 'working'
    }
    It 'une question : blocage enregistré, visible, journalisé (attentes.md) et événement écrit' {
        $global:Screen = $global:AskScreen
        $b = Watch-Worker $global:Task
        $b.Kind | Should -Be 'question'
        @(Blockers-Summary).Count | Should -Be 1
        (Blockers-Summary)[0].Id | Should -Be 'D'
        (Get-Content (Attentes-File) -Raw -Encoding utf8) | Should -Match 'pose une question'
        @($global:Events | Where-Object { $_ -eq 'blocage' }).Count | Should -Be 1
        @($global:Keys).Count | Should -Be 0                     # FLOW ne répond jamais à la place de l'utilisateur
    }
    It 'la même question lue plusieurs fois : une seule ligne de journal' {
        $global:Screen = $global:AskScreen
        1..3 | ForEach-Object { [void](Watch-Worker $global:Task) }
        @(Get-Content (Attentes-File) -Encoding utf8 | Where-Object { $_ -like '- *' }).Count | Should -Be 1
    }
    It 'la confiance dans SA copie de travail est réglée seule et notée, sans blocage' {
        $global:Screen = $global:TrustScreen
        Watch-Worker $global:Task | Should -BeNullOrEmpty
        $global:Keys | Should -Be @('Down', 'Enter')
        @(Blockers-Summary).Count | Should -Be 0
        (Get-Content (Attentes-File) -Raw -Encoding utf8) | Should -Match 'réglé par FLOW'
    }
    It 'la permission demandée est montrée à l''utilisateur, jamais accordée par FLOW' {
        $global:Screen = $global:PermScreen
        (Watch-Worker $global:Task).Kind | Should -Be 'permission'
        @($global:Keys).Count | Should -Be 0
    }
    It 'débloqué : le blocage disparaît et le journal le dit' {
        $global:Screen = $global:AskScreen; [void](Watch-Worker $global:Task)
        $global:Screen = $global:Normal;    [void](Watch-Worker $global:Task)
        @(Blockers-Summary).Count | Should -Be 0
        (Get-Content (Attentes-File) -Raw -Encoding utf8) | Should -Match 'reprise'
    }
    It 'silence : un écran qui ne change pas pendant trop longtemps est signalé ; un écran qui bouge, non' {
        $old = $script:SilentMin; $script:SilentMin = 8
        $global:Screen = $global:Normal
        [void](Watch-Worker $global:Task)                                     # première lecture
        Watch-Worker $global:Task | Should -BeNullOrEmpty                      # trop tôt
        $script:WatchSeen['D'].Since = (Get-Date).AddMinutes(-9)
        $b = Watch-Worker $global:Task
        $b.Kind | Should -Be 'silence'
        $global:Screen = $global:Normal + "`n✻ autre chose (3s)"               # l'écran a bougé
        Watch-Worker $global:Task | Should -BeNullOrEmpty
        $script:SilentMin = $old
    }
    It 'un ouvrier qui n''est pas « au travail » (terminé, en relecture) n''est pas accusé de silence' {
        $global:Task.live = 'review'
        $global:Screen = $global:Normal
        [void](Watch-Worker $global:Task)
        $script:WatchSeen['D'].Since = (Get-Date).AddMinutes(-30)
        Watch-Worker $global:Task | Should -BeNullOrEmpty
    }
    It 'hors psmux : rien' {
        $global:Psmux = $false
        $global:Screen = $global:AskScreen
        Watch-Worker $global:Task | Should -BeNullOrEmpty
        $global:Psmux = $true
    }
}

Describe 'Ce que voit l''utilisateur' {
    It 'l''écran de travail affiche la bannière « bloqué », la cause en rouge sur la ligne de l''ouvrier et dit comment répondre' {
        $src = Get-Content (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -Raw -Encoding utf8
        $src | Should -Match 'ouvrier\(s\) bloqué\(s\)'
        $src | Should -Match 'Blocker-Label \$script:Blockers\[\$t\.id\]\.Kind'
        $src | Should -Match 'Entrée pour voir son Claude et lui répondre'
        $src | Should -Match "flow-watch\.ps1"
    }
}
