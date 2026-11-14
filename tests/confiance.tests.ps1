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
