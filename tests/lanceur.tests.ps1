#Requires -Version 7
# Lanceur (FLOW.ps1) : commandes tapées dans les panneaux.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $global:FlowRoot 'FLOW.ps1') -LoadOnly
    foreach ($n in 'Accounts') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    function New-Acct([string]$Id, [bool]$On = $true) { [pscustomobject]@{ Id = $Id; Label = $Id; Dir = $null; Enabled = $On; Logged = $true; Home = "C:\x\$Id"; Hex = 'ffffff'; Short = $Id } }
}

Describe 'Pane-Command : panneau Claude' {
    It 'avec plusieurs comptes, ajoute la consigne de répartition (skill taches-repartir)' {
        $global:Accounts = @((New-Acct 'a'), (New-Acct 'b'))
        $p = [pscustomobject]@{ cwd = $global:FlowRoot; rows = @() }
        $c = Pane-Command ([pscustomobject]@{ role = 'claude'; args = '--teammate-mode tmux' }) $p
        $c | Should -Match "claude --append-system-prompt '.*taches-repartir.*' --teammate-mode tmux"
        $c | Should -Match '2 comptes Claude'
    }

    It 'avec un seul compte, ne change rien' {
        $global:Accounts = @((New-Acct 'a'), (New-Acct 'b' $false))
        $p = [pscustomobject]@{ cwd = $global:FlowRoot; rows = @() }
        $c = Pane-Command ([pscustomobject]@{ role = 'claude'; args = '' }) $p
        $c | Should -Not -Match 'append-system-prompt'
        $c | Should -Match 'claude$'
    }
}
