#Requires -Version 7
# Délais maximum des attentes (tâches de fond lancées par FLOW) : un Claude bloqué ne fige plus l'écran.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowwait-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    $global:FlowNoAi = $true
    Remove-Item Alias:cls -Force -ErrorAction SilentlyContinue
    function Cls { }
    function Show-Frame { }
    function Read-Action { param([switch]$Wait, [int]$TimeoutMs = 0, [switch]$Wheel) $null }
}

AfterAll { Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Wait-Job-Spinner : délai maximum' {
    It 'une tâche qui dépasse le délai est arrêtée, la fonction rend $null et le journal le dit' {
        $job = Start-Job -ScriptBlock { Start-Sleep 30; 'jamais' }
        $t0 = Get-Date
        $r = Wait-Job-Spinner $job 'un Claude bloqué' 0.02              # 1,2 seconde
        ((Get-Date) - $t0).TotalSeconds | Should -BeLessThan 10
        $r | Should -BeNullOrEmpty
        @(Get-Job -Id $job.Id -ErrorAction SilentlyContinue).Count | Should -Be 0
        (Get-Content $global:FlowLogFile -Raw -Encoding utf8) | Should -Match 'délai de 0,02 minutes dépassé|délai de 0.02 minutes dépassé'
    }
    It 'une tâche qui rend son résultat à temps le renvoie' {
        $job = Start-Job -ScriptBlock { [pscustomobject]@{ Out = 'ok' } }
        (Wait-Job-Spinner $job 'une tâche rapide' 5).Out | Should -Be 'ok'
    }
    It 'le délai par défaut est de 20 minutes' {
        (Get-Command Wait-Job-Spinner).Parameters['TimeoutMin'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }) | Out-Null
        (Get-Content (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -Raw -Encoding utf8) | Should -Match '\[double\]\$TimeoutMin = 20'
    }
}

Describe 'Wait-Jobs-Spinner : plusieurs tâches, délai maximum' {
    It 'les tâches rendues à temps gardent leur résultat, les autres sont arrêtées ($null à leur place)' {
        $jobs = @((Start-Job -ScriptBlock { [pscustomobject]@{ Out = 'a' } }), (Start-Job -ScriptBlock { Start-Sleep 30; 'jamais' }))
        $r = Wait-Jobs-Spinner $jobs 'deux tâches' 0.03        # comme FLOW l'appelle : affectation simple
        $r.Count | Should -Be 2
        $r[0].Out | Should -Be 'a'
        $r[1] | Should -BeNullOrEmpty
    }
}
