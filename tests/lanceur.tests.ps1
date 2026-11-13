#Requires -Version 7
# Lanceur (FLOW.ps1) : commandes tapées dans les panneaux.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $global:FlowRoot 'FLOW.ps1') -LoadOnly
    foreach ($n in 'Accounts') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    function New-Acct([string]$Id, [bool]$On = $true) { [pscustomobject]@{ Id = $Id; Label = $Id; Dir = $null; Enabled = $On; Logged = $true; Home = "C:\x\$Id"; Hex = 'ffffff'; Short = $Id } }
}

Describe 'Expand-Rows : un Claude par compte connecté, quel que soit le profil' {
    BeforeAll {
        function New-Prof { [pscustomobject]@{ rows = @([pscustomobject]@{ height = 60; panes = @([pscustomobject]@{ role = 'team'; width = 40 }, [pscustomobject]@{ role = 'claude'; perAccount = $true; args = '--x'; width = 60; focus = $true }) }) } }
    }
    It 'crée un panneau par compte connecté (les comptes non connectés ou désactivés sont ignorés) et se partage la largeur' {
        $global:Accounts = @((New-Acct 'a'), (New-Acct 'b'), (New-Acct 'c'), [pscustomobject]@{ Id = 'd'; Label = 'd'; Dir = 'x'; Enabled = $true; Logged = $false }, (New-Acct 'e' $false))
        $panes = @((Expand-Rows (New-Prof))[0].panes)
        $panes.Count | Should -Be 4                                              # team + 3 Claude
        $cl = @($panes | Where-Object { $_.role -eq 'claude' })
        ($cl.account -join ',') | Should -Be 'a,b,c'
        ($cl | ForEach-Object { $_.width } | Measure-Object -Sum).Sum | Should -Be 60
        @($cl | Where-Object { $_.focus }).Count | Should -Be 1                  # le focus reste sur un seul panneau
        $cl[0].PSObject.Properties['perAccount'] | Should -BeNullOrEmpty
    }
    It 'ne modifie pas le profil d''origine' {
        $global:Accounts = @((New-Acct 'a'), (New-Acct 'b'))
        $p = New-Prof
        [void](Expand-Rows $p)
        @($p.rows[0].panes).Count | Should -Be 2
        $p.rows[0].panes[1].perAccount | Should -BeTrue
    }
    It 'sans aucun compte connecté, garde un seul Claude (compte par défaut)' {
        $global:Accounts = @([pscustomobject]@{ Id = 'principal'; Label = 'Compte 1'; Dir = $null; Enabled = $true; Logged = $false })
        @((Expand-Rows (New-Prof))[0].panes | Where-Object { $_.role -eq 'claude' }).Count | Should -Be 1
    }
}

Describe 'Profile-Sig : savoir si une session ouverte correspond encore au profil' {
    BeforeAll {
        function Get-Accounts { , @($global:Accounts) }
        function Make-Prof([object[]]$panes) { [pscustomobject]@{ rows = @([pscustomobject]@{ height = 100; panes = $panes }) } }
        $global:FlowVersion = '1.0'
    }
    It 'ne change pas quand on ne fait que déplacer ou redimensionner les panneaux (Ctrl+B W)' {
        $global:Accounts = @((New-Acct 'a'))
        $a = Make-Prof @([pscustomobject]@{ role = 'team'; width = 50 }, [pscustomobject]@{ role = 'monitor'; width = 50 })
        $b = Make-Prof @([pscustomobject]@{ role = 'monitor'; width = 20 }, [pscustomobject]@{ role = 'team'; width = 80 })
        Profile-Sig $a | Should -Be (Profile-Sig $b)
    }
    It 'change quand le profil gagne un panneau, ou quand un compte est connecté' {
        $global:Accounts = @((New-Acct 'a'))
        $base = Make-Prof @([pscustomobject]@{ role = 'team' })
        $sig = Profile-Sig $base
        Profile-Sig (Make-Prof @([pscustomobject]@{ role = 'team' }, [pscustomobject]@{ role = 'exchanges' })) | Should -Not -Be $sig
        $global:Accounts = @((New-Acct 'a'), (New-Acct 'b'))
        Profile-Sig $base | Should -Not -Be $sig
    }
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
