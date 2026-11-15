#Requires -Version 7
# Approbation automatique du dossier d'un ouvrier par Claude Code (« Do you trust this folder ? ») : seulement pour la copie créée par FLOW.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowtrust-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode', 'RevJobs', 'GuidedPrefFile', 'Sock') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    $global:Screen = ''; $global:Keys = @()
    function Find-Pane([string]$tag) { 'win.1' }
    function psmux { $a = @($args); if ($a -contains 'capture-pane') { $global:Screen -split "`n" } elseif ($a -contains 'send-keys') { $global:Keys += $a[-1] } }
    $global:Psmux = $true; $global:Sock = 'flow'
    $global:State = [pscustomobject]@{ id = '20261114-234302' }
    $global:Task = [pscustomobject]@{ id = 'A'; worktree = 'C:\proj-flow\20261114-234302\A' }
    $global:Dialog = "Accessing workspace:`n C:\proj-flow\20261114-234302\A`n Quick safety check: Is this a project you created or one you trust?`n ❯ No, exit`n   Yes, I trust this folder`n Enter to confirm · Esc to cancel"
}
AfterAll { Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Approbation du dossier de l''ouvrier' {
    BeforeEach { $global:Keys = @() }
    It 'la boîte de confiance de SA copie de travail : Bas puis Entrée (choisit « Yes », jamais « No, exit »)' {
        $global:Screen = $global:Dialog
        (Accept-TrustPrompt $global:Task) | Should -BeTrue
        $global:Keys | Should -Be @('Down', 'Enter')
    }
    It 'un autre dossier (pas celui de l''équipe) : rien n''est répondu' {
        $global:Screen = $global:Dialog.Replace('20261114-234302', '20250101-000000').Replace('\A', '\Z')
        (Accept-TrustPrompt $global:Task) | Should -BeFalse
        @($global:Keys).Count | Should -Be 0
    }
    It 'un écran normal de Claude : rien n''est envoyé' {
        $global:Screen = "❯ `n ◆ Opus 5.5 · ctx 6%"
        (Accept-TrustPrompt $global:Task) | Should -BeFalse
        @($global:Keys).Count | Should -Be 0
    }
    It 'hors psmux ou sans copie de travail : rien' {
        $global:Screen = $global:Dialog
        $t2 = [pscustomobject]@{ id = 'B'; worktree = '' }
        (Accept-TrustPrompt $t2) | Should -BeFalse
        $global:Psmux = $false
        (Accept-TrustPrompt $global:Task) | Should -BeFalse
        $global:Psmux = $true
    }
}

Describe 'Un ouvrier qui pose une question attend l''utilisateur' {
    BeforeAll {
        function Fake-Transcript([string]$lastJson) {
            $home1 = Join-Path $global:Base 'compte'; $wt = Join-Path $global:Base 'copie\A'
            $pd = Join-Path (Join-Path $home1 'projects') (Proj-Key $wt); New-Item -ItemType Directory -Force $pd | Out-Null
            Set-Content (Join-Path $pd 's.jsonl') $lastJson -Encoding utf8
            @{ acct = [pscustomobject]@{ Home = $home1 }; wt = $wt }
        }
    }
    It 'AskUserQuestion sans réponse : « waiting » (et donc la notification « attend ta réponse »)' {
        $x = Fake-Transcript '{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"AskUserQuestion","input":{}}]}}'
        Claude-State $x.acct $x.wt | Should -Be 'waiting'
    }
    It 'un autre outil (Bash) en cours : « working »' {
        $x = Fake-Transcript '{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{}}]}}'
        Claude-State $x.acct $x.wt | Should -Be 'working'
    }
    It 'fin de tour : « waiting » ; réponse de l''utilisateur reçue : « working »' {
        $x = Fake-Transcript '{"type":"assistant","message":{"stop_reason":"end_turn","content":[]}}'
        Claude-State $x.acct $x.wt | Should -Be 'waiting'
        $x = Fake-Transcript '{"type":"user","message":{"content":"ok"}}'
        Claude-State $x.acct $x.wt | Should -Be 'working'
    }
}
Describe 'Pester 5 portable pour les vérifications du projet' {
    BeforeEach {
        $global:FlowModulesDir = Join-Path $global:Base ('mods-' + [guid]::NewGuid().ToString('N').Substring(0, 5))
        $global:Saved = 0; $global:SystemOk = $false
        function Pester-System { $global:SystemOk }
        function Save-PesterPortable([string]$dir) { $global:Saved++; New-Item -ItemType Directory -Force (Join-Path $dir 'Pester\5.9.1') | Out-Null; Set-Content (Join-Path $dir 'Pester\5.9.1\Pester.psd1') '@{}' }
    }
    AfterEach { $global:FlowModulesDir = $null }
    It 'une vérification qui ne lance pas Pester : rien à faire, rien de téléchargé' {
        Pester-Prefix 'npm test' | Should -Be ''
        $global:Saved | Should -Be 0
    }
    It 'Pester 5 déjà sur la machine : rien à faire' {
        $global:SystemOk = $true
        Pester-Prefix 'pwsh -NoProfile -Command "Invoke-Pester -CI"' | Should -Be ''
        $global:Saved | Should -Be 0
    }
    It 'machine avec l''ancien Pester seulement : Pester 5 est récupéré UNE fois, puis réutilisé ; le chemin des modules est complété pour cette vérification' {
        $p = Pester-Prefix 'pwsh -NoProfile -Command "Invoke-Pester -CI"'
        $p | Should -Match 'PSModulePath'
        $p | Should -Match ([regex]::Escape($global:FlowModulesDir))
        $global:Saved | Should -Be 1
        [void](Pester-Prefix 'Invoke-Pester')
        $global:Saved | Should -Be 1
    }
    It 'téléchargement impossible : pas de préfixe, pas de plantage' {
        function Save-PesterPortable([string]$dir) { throw 'hors ligne' }
        { Pester-Prefix 'Invoke-Pester -CI' } | Should -Not -Throw
        Pester-Prefix 'Invoke-Pester -CI' | Should -Be ''
    }
    It 'les versions 3 ou illisibles du dossier sont ignorées' {
        New-Item -ItemType Directory -Force (Join-Path $global:FlowModulesDir 'Pester\3.4.0'), (Join-Path $global:FlowModulesDir 'Pester\abc') | Out-Null
        Set-Content (Join-Path $global:FlowModulesDir 'Pester\3.4.0\Pester.psd1') '@{}'
        Pester-Max $global:FlowModulesDir | Should -BeNullOrEmpty
    }
}
Describe 'Questions : les options longues passent à la ligne' {
    It 'dans une fenêtre étroite, une option longue est écrite en entier sur plusieurs lignes (rien n''est coupé)' {
        $global:Frames = @()
        function Show-Frame($lines) { $global:Frames += , @($lines) }
        function ConW { 40 }
        function Read-Action { param([switch]$Wait, [int]$TimeoutMs = 0, [switch]$Wheel) @{ K = [pscustomobject]@{ Key = 'Escape'; KeyChar = [char]27; Modifiers = 0 } } }
        function Cls { }
        $long = 'Un fichier JSON local, extensible, dont les anciennes versions restent toujours lisibles par les nouvelles'
        $r = Ask-Questions @([pscustomobject]@{ question = 'Où stocker ?'; why = 'parce que'; options = @($long, 'Un fichier CSV') }) 'TEST'
        $txt = (@($global:Frames[0]) | ForEach-Object { [regex]::Replace("$_", "\x1b\[[0-9;]*[A-Za-z]", '') }) -join ' '
        $flat = ($txt -replace '\s+', ' ')
        $flat | Should -Match 'anciennes versions restent toujours lisibles par les nouvelles'
        $flat | Should -Match 'Un fichier CSV'
    }
}