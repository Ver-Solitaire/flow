#Requires -Version 7
# Banc de mesure (tools\flow-bench.ps1) : la mécanique de notation, sans appeler Claude (un faux Claude corrige ou non les fichiers).
BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $global:FlowRoot 'tools\flow-bench.ps1') -LoadOnly -Sortie (Join-Path ([IO.Path]::GetTempPath()) ('bench-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.jsonl'))
    $global:Sortie = $Sortie
}
AfterAll { Remove-Item -LiteralPath $global:Sortie -Force -ErrorAction SilentlyContinue }

Describe 'Banc de mesure' {
    It 'les tâches livrées sont lisibles : chacune a une demande, des fichiers et au moins une vérification' {
        $t = @(Bench-Load (Join-Path $global:FlowRoot 'bench\taches.json'))
        $t.Count | Should -BeGreaterOrEqual 3
        foreach ($x in $t) { $x.id | Should -Not -BeNullOrEmpty; $x.demande | Should -Not -BeNullOrEmpty; @($x.verifications).Count | Should -BeGreaterThan 0 }
    }
    It 'sans travail de Claude, les vérifications échouent (le banc ne donne pas de point gratuit)' {
        $runner = { param($d, $demande, $m) @{ Cout = 0; DureeMs = 0; Erreur = '' } }
        $r = Run-Bench -Ids 'corriger-bug', 'ajouter-fonction', 'renommer' -Runner $runner
        $r.reussies | Should -BeLessThan $r.total
        ($r.taches | Where-Object tache -eq 'corriger-bug').reussies | Should -Be 0
    }
    It 'un Claude qui travaille bien obtient tous les points, coût et durée sont notés, le résultat est ajouté au fichier' {
        $runner = {
            param($d, $demande, $m)
            Set-Content (Join-Path $d 'calc.ps1') "function Add-Numbers([int]`$a, [int]`$b) { return `$a + `$b }`n" -ErrorAction SilentlyContinue
            @{ Cout = 0.0123; DureeMs = 5; Erreur = '' }
        }
        $r = Run-Bench -Ids 'corriger-bug' -Runner $runner
        $r.reussies | Should -Be 2
        $r.total | Should -Be 2
        $r.cout | Should -Be 0.0123
        @(Get-Content $global:Sortie).Count | Should -BeGreaterThan 0
        (Get-Content $global:Sortie | Select-Object -Last 1 | ConvertFrom-Json).taches[0].tache | Should -Be 'corriger-bug'
    }
    It 'le résumé signale une régression entre deux mesures' {
        Remove-Item $global:Sortie -Force -ErrorAction SilentlyContinue
        $bon = { param($d, $demande, $m) Set-Content (Join-Path $d 'calc.ps1') "function Add-Numbers([int]`$a, [int]`$b) { return `$a + `$b }"; @{ Cout = 0; DureeMs = 0; Erreur = '' } }
        $mauvais = { param($d, $demande, $m) @{ Cout = 0; DureeMs = 0; Erreur = '' } }
        [void](Run-Bench -Ids 'corriger-bug' -Runner $bon); [void](Run-Bench -Ids 'corriger-bug' -Runner $mauvais)
        ((Show-BenchResume | Out-String) + ((Show-BenchResume 6>&1) | Out-String)) | Should -Match 'régression'
    }
}
