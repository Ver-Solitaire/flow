#Requires -Version 7
# « À toi » : bannière animée, alerte (notification + son), rappel, animation pendant l'attente. Aucune vraie notification, aucun vrai écran.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowattn-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode', 'RevJobs', 'GuidedPrefFile') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    $global:Sent = @()
    function Notify([string]$title, [string]$text, [switch]$Attention) { $global:Sent += [pscustomobject]@{ Title = $title; Text = $text; Attention = [bool]$Attention } }
    function Strip([string]$s) { [regex]::Replace($s, "\x1b\[[0-9;]*[A-Za-z]", '') }
}
AfterAll { Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Bannière « À toi »' {
    It 'la ligne porte le repère, le message, et remplit toute la largeur' {
        $l = Attn-Line 'vérifie le plan' 0
        $p = Strip $l
        $p | Should -Match '⚑ À TOI'
        $p | Should -Match 'vérifie le plan'
        $p.Length | Should -Be ([Math]::Max(30, (ConW) - 1))
    }
    It 'elle pulse : la couleur et les chevrons changent d''une image à l''autre' {
        $a = Attn-Line 'x' 0; $b = Attn-Line 'x' 3; $c = Attn-Line 'x' 6
        ($a -ne $b) | Should -BeTrue
        ($a -ne $c) | Should -BeTrue
        (Strip $a) | Should -Not -Be (Strip (Attn-Line 'x' 1))        # les chevrons avancent
    }
    It 'les écrans qui attendent l''utilisateur utilisent la bannière (plan, résultat, spec, workflow)' {
        foreach ($f in 'flow-team.ps1', 'flow-steps.ps1', 'flow-workflow.ps1') {
            (Get-Content (Join-Path $global:FlowRoot "tools\$f") -Raw -Encoding utf8) | Should -Match "\(Attn '"
        }
        $all = (Get-Content (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -Raw -Encoding utf8)
        $all | Should -Match "Attn 'vérifie le plan"
        $all | Should -Match "Attn 'Entrée = VALIDER"
    }
    It 'Show-Frame repère la ligne de la bannière (pour la redessiner), et seulement elle' {
        $script:AttnRow = -1
        $lines = @('', 'titre', (Attn-Line 'va' 1), 'suite')
        $script:AttnMark | Should -Be '⚑ À TOI'
        $idx = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ("$($lines[$i])" -like "*$script:AttnMark*") { $idx = $i; break } }
        $idx | Should -Be 2
    }
}

Describe 'Alerte et rappel' {
    BeforeEach { $global:Sent = @(); $script:AttnAlerts = @{}; $global:FlowNoAi = $false }
    AfterEach { $global:FlowNoAi = $true }
    It 'la première fois : une notification avec son et clignotement ; la même situation ne re-notifie pas aussitôt' {
        (Attention-Alert '⚑ FLOW : un plan attend ta validation' 'plan') | Should -BeTrue
        (Attention-Alert '⚑ FLOW : un plan attend ta validation' 'plan') | Should -BeFalse
        @($global:Sent).Count | Should -Be 1
        $global:Sent[0].Attention | Should -BeTrue
    }
    It 'une autre situation notifie tout de suite' {
        [void](Attention-Alert 'a' 'x'); [void](Attention-Alert 'b' 'y')
        @($global:Sent).Count | Should -Be 2
    }
    It 'rappel au bout de 3 minutes si l''utilisateur n''a toujours rien fait' {
        [void](Attention-Alert 'a' 'x')
        $script:AttnAlerts['a|x'] = (Get-Date).AddSeconds(-($script:AttnRemindSec + 5))
        (Attention-Alert 'a' 'x') | Should -BeTrue
        @($global:Sent).Count | Should -Be 2
    }
    It 'Attn : affiche la ligne ET prévient' {
        $l = Attn 'vérifie' '⚑ FLOW : test'
        (Strip $l) | Should -Match 'vérifie'
        @($global:Sent).Count | Should -Be 1
        $script:AttnMsg | Should -Be 'vérifie'
    }
    It 'Pulse-Attention : redessine la ligne à la bonne place, sans rien faire s''il n''y a pas de bannière' {
        $script:AttnRow = -1; $script:AttnMsg = ''
        { Pulse-Attention } | Should -Not -Throw
        $script:AttnRow = 3; $script:AttnMsg = 'vérifie'; $p0 = $script:AttnPhase
        Pulse-Attention
        $script:AttnPhase | Should -Be ($p0 + 1)
    }
    It 'jamais d''alerte pendant les tests (FlowNoAi)' {
        $global:FlowNoAi = $true
        (Attention-Alert 'a' 'x') | Should -BeFalse
        @($global:Sent).Count | Should -Be 0
    }
}

Describe 'Attente animée' {
    It 'Read-Action attend par petits pas quand une bannière est affichée (pour la faire pulser)' {
        (Get-Content (Join-Path $global:FlowRoot 'tools\flow-input.ps1') -Raw -Encoding utf8) | Should -Match 'Pulse-Attention'
    }
    It 'le script de clignotement existe et est syntaxiquement correct' {
        $f = Join-Path $global:FlowRoot 'tools\flow-flash.ps1'
        Test-Path $f | Should -BeTrue
        $er = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$er)
        $er.Count | Should -Be 0
    }
}

Describe 'Écran plus haut que la fenêtre' {
    It 'on garde le haut et les deux dernières lignes (touches et message), le milieu est coupé' {
        $lines = @(1..60 | ForEach-Object { "ligne $_" })
        $r = @(Fit-Height $lines 30)
        $r.Count | Should -Be 29
        $r[0] | Should -Be 'ligne 1'
        $r[-1] | Should -Be 'ligne 60'
        $r[-2] | Should -Be 'ligne 59'
        (($r | Where-Object { $_ -like '*écran trop haut*' }).Count) | Should -Be 1
    }
    It 'un écran qui tient n''est pas modifié' {
        $lines = @(1..10 | ForEach-Object { "ligne $_" })
        @(Fit-Height $lines 30).Count | Should -Be 10
    }
}