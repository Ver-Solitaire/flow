#Requires -Version 7
# Dépendances : une seule déclaration (dependances.json), des versions contrôlées, une installation qui ne ment pas,
# un point d'entrée qui marche sans PowerShell 7. Rien n'est installé : les outils sont simulés (faux programmes dans un dossier d'essai).

# (découverte) Windows PowerShell 5.1 présent ? Évalué avant les tests, pour les -Skip ; redéfini dans BeforeAll pour l'exécution
$script:Ps51 = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'tools\flow-deps.ps1')
    $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowdeps-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $script:Base | Out-Null
    $script:Ps51 = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source

    function New-FakeProbe([hashtable]$Table) {
        # un « Probe » qui répond ce que dit la table : id -> @{ Path ; Versions }
        $t = $Table
        { param($d) if ($t.ContainsKey($d.id)) { $t[$d.id] } else { @{ Path = $null; Versions = @() } } }.GetNewClosure()
    }
    function Get-Fake([string]$Id) { Get-FlowDep -Id $Id }
    function Run-Ps51([string[]]$ArgList, [hashtable]$Env = @{}) {
        # lance Windows PowerShell 5.1 dans un environnement contrôlé ; renvoie sortie et code de sortie
        $psi = [Diagnostics.ProcessStartInfo]::new($script:Ps51)
        foreach ($a in $ArgList) { [void]$psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true; $psi.UseShellExecute = $false
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        foreach ($k in $Env.Keys) { $psi.Environment[$k] = $Env[$k] }
        $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd(); [void]$p.WaitForExit(120000)
        [pscustomobject]@{ Out = $out; Code = $p.ExitCode }
    }
    # un dossier de faux outils + une déclaration à soi
    function New-Sandbox([string]$Name) {
        $d = Join-Path $script:Base $Name; $bin = Join-Path $d 'bin'
        New-Item -ItemType Directory -Force $bin | Out-Null
        $decl = @{ schema = 1; dependances = @(
                @{ id = 'alpha'; nom = 'Alpha'; commande = 'fakealpha'; winget = 'Fake.Alpha'; obligatoire = $true; quand = 'toujours'; role = 'l''outil principal'; min = '2.0'; testee = '2.3.4'; chemins = @()
                    version = @{ args = @('--version'); motif = 'fakealpha (\d+\.\d+\.\d+)' } },
                @{ id = 'beta'; nom = 'Beta'; commande = 'fakebeta'; winget = 'Fake.Beta'; obligatoire = $false; quand = 'recommandé'; role = 'un confort'; min = $null; testee = $null; chemins = @(); version = $null },
                @{ id = 'winget'; nom = 'winget'; commande = 'winget'; winget = $null; obligatoire = $false; quand = 'installation'; role = 'installe'; installation = 'installe App Installer'; chemins = @(); version = $null }
            ) } | ConvertTo-Json -Depth 8
        Set-Content (Join-Path $d 'deps.json') $decl -Encoding UTF8
        [pscustomobject]@{ Dir = $d; Bin = $bin; Deps = (Join-Path $d 'deps.json') }
    }
    function Add-Shim([string]$Bin, [string]$Name, [string]$Text) { Set-Content (Join-Path $Bin "$Name.cmd") "@echo off`r`necho $Text" -Encoding ascii }
    function Child-Path([string]$Bin) { "$Bin;$env:WINDIR\System32;$env:WINDIR\System32\WindowsPowerShell\v1.0" }
}

AfterAll { Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Déclaration unique' {
    It 'est lisible, chaque entrée est complète et les identifiants sont uniques' {
        $deps = @(Get-FlowDeps)
        $deps.Count | Should -BeGreaterThan 5
        foreach ($d in $deps) {
            foreach ($k in 'id', 'nom', 'commande', 'quand', 'role') { "$($d.$k)" | Should -Not -BeNullOrEmpty -Because "$($d.id) : champ $k" }
            $d.PSObject.Properties.Name | Should -Contain 'obligatoire'
            $d.PSObject.Properties.Name | Should -Contain 'min'
            $d.PSObject.Properties.Name | Should -Contain 'testee'
            if ($d.winget) { $d.winget | Should -Match '^[A-Za-z0-9]+\.[A-Za-z0-9\.\-]+$' }
            if ($d.min) { { ConvertTo-DepVersion $d.min } | Should -Not -Throw; ConvertTo-DepVersion $d.min | Should -Not -BeNullOrEmpty }
            if ($d.min -and $d.min_source -ne $null) { "$($d.min_source)" | Should -Not -BeNullOrEmpty -Because "$($d.id) : d'où vient le minimum ?" }
        }
        @($deps.id | Select-Object -Unique).Count | Should -Be $deps.Count
    }
    It 'contient les outils obligatoires de FLOW, avec une version minimale contrôlée' {
        foreach ($id in 'pwsh', 'psmux', 'claude', 'git') {
            $d = Get-FlowDep -Id $id
            $d.obligatoire | Should -BeTrue
            $d.winget | Should -Not -BeNullOrEmpty
            $d.min | Should -Not -BeNullOrEmpty
            $d.version.args | Should -Not -BeNullOrEmpty
        }
    }
    It 'Pester est borné à la série 5 (minimum et maximum)' {
        $p = Get-FlowDep -Id 'pester'
        $p.min | Should -Be '5.0'
        (ConvertTo-DepVersion $p.max).Major | Should -Be 5
    }
    It 'les minimums ne dépassent pas les versions essayées' {
        foreach ($d in @(Get-FlowDeps | Where-Object { $_.min -and $_.testee })) { (Compare-DepVersion $d.testee $d.min) | Should -BeGreaterOrEqual 0 -Because $d.id }
    }
    It 'se lit aussi sous Windows PowerShell 5.1' -Skip:(-not $script:Ps51) {
        $r = Run-Ps51 @('-NoProfile', '-Command', "`$j = Get-Content -LiteralPath '$(Get-DepsFilePath)' -Raw -Encoding UTF8 | ConvertFrom-Json; `$j.dependances.Count; `$j.dependances[0].role")
        $r.Out | Should -Match 'PowerShell 7'
    }
}

Describe 'Versions : comparées comme des versions' {
    It 'extrait un numéro d''une sortie de commande' {
        (ConvertTo-DepVersion 'git version 2.56.0.windows.4').ToString() | Should -Be '2.56.0'
        (ConvertTo-DepVersion '2.17').ToString() | Should -Be '2.17.0'
        (ConvertTo-DepVersion '2.1.318 (Claude Code)').ToString() | Should -Be '2.1.318'
        ConvertTo-DepVersion 'rien' | Should -BeNullOrEmpty
    }
    It '5.10 vient après 5.9 (et non avant, comme du texte)' {
        (Compare-DepVersion '5.10.0' '5.9.1') | Should -Be 1
        ('5.10.0' -lt '5.9.1') | Should -BeTrue                 # l'erreur à éviter : comparer comme du texte
        (Compare-DepVersion '2.56.0.windows.4' '2.17') | Should -Be 1
        (Compare-DepVersion '3.4.0' '3.4.0') | Should -Be 0
        (Compare-DepVersion '3.3.8' '3.4.0') | Should -Be -1
    }
    It 'choisit la plus haute version DE LA SÉRIE (Pester 5.10 plutôt que 5.9, jamais 6.x ni 3.x)' {
        $p = Get-FlowDep -Id 'pester'
        Select-DepVersion @('3.4.0', '5.9.1', '5.10.0', '6.2.0') $p | Should -Be '5.10.0'
        Select-DepVersion @('3.4.0', '6.2.0') $p | Should -BeNullOrEmpty
    }
}

Describe 'État d''une dépendance' {
    It 'absente : le message dit à quoi elle sert et la commande exacte' {
        $d = Get-Fake 'psmux'
        $s = Get-DepState $d -Probe (New-FakeProbe @{})
        $s.Statut | Should -Be 'absent'
        $m = Get-DepMessage $s $d
        $m | Should -Match 'psmux est introuvable'
        $m | Should -Match ([regex]::Escape("winget install --id $($d.winget) -e"))
        $m | Should -Match 'install.cmd'
    }
    It 'trop ancienne : le message donne la version trouvée, la version attendue et la mise à jour' {
        $d = Get-Fake 'psmux'
        $s = Get-DepState $d -Probe (New-FakeProbe @{ psmux = @{ Path = 'C:\x\psmux.exe'; Versions = @('3.3.8') } })
        $s.Statut | Should -Be 'ancienne'
        $m = Get-DepMessage $s $d
        $m | Should -Match '3\.3\.8'
        $m | Should -Match ([regex]::Escape($d.min))
        $m | Should -Match ([regex]::Escape("winget upgrade --id $($d.winget) -e"))
    }
    It 'à la bonne version, ou plus récente que la testée : ok' {
        $d = Get-Fake 'psmux'
        (Get-DepState $d -Probe (New-FakeProbe @{ psmux = @{ Path = 'p'; Versions = @($d.min) } })).Statut | Should -Be 'ok'
        (Get-DepState $d -Probe (New-FakeProbe @{ psmux = @{ Path = 'p'; Versions = @('3.10.2') } })).Statut | Should -Be 'ok'
    }
    It 'présente mais version illisible : « inconnue », qui n''empêche pas FLOW d''être prêt' {
        $d = Get-Fake 'claude'
        $s = Get-DepState $d -Probe (New-FakeProbe @{ claude = @{ Path = 'p'; Versions = @() } })
        $s.Statut | Should -Be 'inconnue'
        (Get-DepsVerdict @($s)).Ready | Should -BeTrue
    }
    It 'sans minimum : présente = ok (Windows Terminal)' {
        $d = Get-Fake 'wt'
        (Get-DepState $d -Probe (New-FakeProbe @{ wt = @{ Path = 'p'; Versions = @() } })).Statut | Should -Be 'ok'
    }
    It 'module hors série (Pester 6) : « trop-recente », pas accepté' {
        $d = Get-Fake 'pester'
        $s = Get-DepState $d -Probe (New-FakeProbe @{ pester = @{ Path = 'p'; Versions = @('6.2.0') } })
        $s.Statut | Should -Be 'trop-recente'
        (Get-DepMessage $s $d) | Should -Match 'série'
        (Get-DepState $d -Probe (New-FakeProbe @{ pester = @{ Path = 'p'; Versions = @('3.4.0', '5.10.0', '6.2.0') } })).Version | Should -Be '5.10.0'
        (Get-DepState $d -Probe (New-FakeProbe @{ pester = @{ Path = 'p'; Versions = @('3.4.0') } })).Statut | Should -Be 'ancienne'
    }
    It 'les messages des autres scripts viennent de la déclaration' {
        (Get-DepMissingText 'git') | Should -Match ([regex]::Escape("winget install --id $((Get-Fake 'git').winget) -e"))
        (Get-DepMissingText 'inexistant') | Should -Match 'introuvable'
    }
    It 'la lecture réelle trouve PowerShell et lit sa version' {
        $s = Get-DepState (Get-Fake 'pwsh')
        $s.Statut | Should -Be 'ok'
        $s.Version | Should -Match '^\d+\.\d+\.\d+$'
    }
}

Describe 'Verdict de l''installation' {
    It 'prêt seulement si tout l''obligatoire est là, à la bonne version' {
        $all = @('pwsh', 'psmux', 'claude', 'git') | ForEach-Object { Get-DepState (Get-Fake $_) -Probe (New-FakeProbe @{ $_ = @{ Path = 'p'; Versions = @((Get-Fake $_).min) } }) }
        (Get-DepsVerdict $all).Ready | Should -BeTrue
        $one = @($all | Where-Object { $_.Id -ne 'git' }) + @(Get-DepState (Get-Fake 'git') -Probe (New-FakeProbe @{}))
        $v = Get-DepsVerdict $one
        $v.Ready | Should -BeFalse
        $v.Missing.Id | Should -Contain 'git'
        $old = @($all | Where-Object { $_.Id -ne 'psmux' }) + @(Get-DepState (Get-Fake 'psmux') -Probe (New-FakeProbe @{ psmux = @{ Path = 'p'; Versions = @('3.0.0') } }))
        $v2 = Get-DepsVerdict $old
        $v2.Ready | Should -BeFalse
        $v2.Old.Id | Should -Contain 'psmux'
    }
    It 'un outil facultatif absent ne bloque pas, mais est signalé' {
        $mand = @('pwsh', 'psmux', 'claude', 'git') | ForEach-Object { Get-DepState (Get-Fake $_) -Probe (New-FakeProbe @{ $_ = @{ Path = 'p'; Versions = @((Get-Fake $_).min) } }) }
        $v = Get-DepsVerdict (@($mand) + @(Get-DepState (Get-Fake 'wt') -Probe (New-FakeProbe @{})))
        $v.Ready | Should -BeTrue
        $v.Optional.Id | Should -Contain 'wt'
    }
    It 'le PATH de la fenêtre est COMPLÉTÉ, jamais remplacé' {
        $keep = $env:Path
        try {
            $env:Path = 'C:\dossier-a-moi;C:\autre-dossier'
            Update-SessionPath
            $env:Path | Should -Match ([regex]::Escape('C:\dossier-a-moi'))
            $env:Path | Should -Match ([regex]::Escape('C:\autre-dossier'))
            ($env:Path -split ';' | Where-Object { $_ -ieq 'C:\dossier-a-moi' }).Count | Should -Be 1
            (($env:Path -split ';') | Select-Object -Unique).Count | Should -Be ($env:Path -split ';').Count   # pas de doublon
        } finally { $env:Path = $keep }
    }
}

Describe 'install.ps1 sous Windows PowerShell 5.1 (outils simulés)' -Skip:(-not $script:Ps51) {
    It '-Check : tout est là, code 0, rien n''est modifié' {
        $sb = New-Sandbox 'ok'; Add-Shim $sb.Bin 'fakealpha' 'fakealpha 2.3.4'; Add-Shim $sb.Bin 'fakebeta' 'beta'
        $r = Run-Ps51 @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Root 'install.ps1'), '-Check', '-DepsFile', $sb.Deps) @{ Path = (Child-Path $sb.Bin) }
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'Alpha 2\.3\.4'
        $r.Out | Should -Match 'Tout ce qu.il faut pour FLOW est là'
    }
    It '-Check : un outil obligatoire absent → code 1, avec la commande à taper' {
        $sb = New-Sandbox 'absent'
        $r = Run-Ps51 @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Root 'install.ps1'), '-Check', '-DepsFile', $sb.Deps) @{ Path = (Child-Path $sb.Bin) }
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'Alpha est introuvable'
        $r.Out | Should -Match 'winget install --id Fake\.Alpha -e'
    }
    It '-Check : version trop ancienne → code 1, avec version trouvée, version attendue et mise à jour' {
        $sb = New-Sandbox 'ancien'; Add-Shim $sb.Bin 'fakealpha' 'fakealpha 1.0.0'
        $r = Run-Ps51 @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Root 'install.ps1'), '-Check', '-DepsFile', $sb.Deps) @{ Path = (Child-Path $sb.Bin) }
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'Alpha 1\.0\.0 est trop ancien'
        $r.Out | Should -Match 'FLOW demande 2\.0 ou plus'
        $r.Out | Should -Match 'winget upgrade --id Fake\.Alpha -e'
    }
    It '-Check : un facultatif absent ne change pas le code de sortie' {
        $sb = New-Sandbox 'facultatif'; Add-Shim $sb.Bin 'fakealpha' 'fakealpha 2.0.0'
        $r = Run-Ps51 @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Root 'install.ps1'), '-Check', '-DepsFile', $sb.Deps) @{ Path = (Child-Path $sb.Bin) }
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'Beta : absent'
    }
    It 'winget « réussit » mais l''outil reste invisible : pas de « FLOW est prêt », code 1, et on dit de rouvrir la fenêtre' {
        $sb = New-Sandbox 'invisible'
        Set-Content (Join-Path $sb.Bin 'winget.cmd') "@echo off`r`nexit /b 0" -Encoding ascii        # winget ne fait rien mais répond 0
        $r = Run-Ps51 @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Root 'install.ps1'), '-Yes', '-SansPreparation', '-DepsFile', $sb.Deps) @{ Path = (Child-Path $sb.Bin) }
        $r.Code | Should -Be 1
        $r.Out | Should -Not -Match 'FLOW est prêt'
        $r.Out | Should -Match 'FLOW n.est PAS prêt'
        $r.Out | Should -Match 'rouvre-la'
        $r.Out | Should -Match 'manque : Alpha'
    }
    It 'winget échoue : le dit, avec la commande à lancer à la main, code 1' {
        $sb = New-Sandbox 'echec'
        Set-Content (Join-Path $sb.Bin 'winget.cmd') "@echo off`r`nexit /b 7" -Encoding ascii
        $r = Run-Ps51 @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Root 'install.ps1'), '-Yes', '-SansPreparation', '-DepsFile', $sb.Deps) @{ Path = (Child-Path $sb.Bin) }
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'winget a échoué \(code 7\)'
        $r.Out | Should -Not -Match 'FLOW est prêt'
    }
    It 'winget installe vraiment : revérifié sur l''outil lui-même, « FLOW est prêt », code 0' {
        $sb = New-Sandbox 'reussi'
        Set-Content (Join-Path $sb.Bin 'winget.cmd') "@echo off`r`necho fakealpha 2.5.0> `"$($sb.Bin)\version.txt`"`r`n(echo @echo off& echo echo fakealpha 2.5.0)> `"$($sb.Bin)\fakealpha.cmd`"`r`nexit /b 0" -Encoding ascii
        $r = Run-Ps51 @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Root 'install.ps1'), '-Yes', '-SansPreparation', '-DepsFile', $sb.Deps) @{ Path = (Child-Path $sb.Bin) }
        $r.Out | Should -Match 'Vérification après installation'
        $r.Out | Should -Match 'Alpha 2\.5\.0'
        $r.Out | Should -Match 'FLOW est prêt'
        $r.Code | Should -Be 0
    }
}

Describe 'Point d''entrée sans PowerShell 7' {
    It 'FLOW.ps1 lancé par Windows PowerShell 5.1 dit de double-cliquer sur install.cmd (et ne casse pas sur la syntaxe de PowerShell 7)' -Skip:(-not $script:Ps51) {
        $r = Run-Ps51 @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Root 'FLOW.ps1')) @{ FLOW_NOPAUSE = '1' }
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'PowerShell 7 est introuvable'
        $r.Out | Should -Match 'install\.cmd'
        $r.Out | Should -Not -Match 'Jeton inattendu|Unexpected token'
    }
    It 'FLOW.ps1 est en UTF-8 avec BOM : sans lui, 5.1 le lit en ANSI et la garde ne peut pas s''afficher' {
        foreach ($f in 'FLOW.ps1', 'install.ps1', 'tools\flow-deps.ps1') {
            $b = [IO.File]::ReadAllBytes((Join-Path $script:Root $f)) | Select-Object -First 3
            (($b[0] -eq 0xEF) -and ($b[1] -eq 0xBB) -and ($b[2] -eq 0xBF)) | Should -BeTrue -Because "$f doit avoir un BOM UTF-8"
        }
    }
    It 'les scripts de départ n''ont AUCUNE erreur de syntaxe sous Windows PowerShell 5.1' -Skip:(-not $script:Ps51) {
        foreach ($f in 'FLOW.ps1', 'install.ps1', 'tools\flow-deps.ps1') {
            $r = Run-Ps51 @('-NoProfile', '-Command', "`$e = `$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$(Join-Path $script:Root $f)', [ref]`$null, [ref]`$e); `$e.Count")
            "$($r.Out)".Trim() | Should -Be '0' -Because $f
        }
    }
    It 'FLOW.cmd sans PowerShell 7 : une phrase, pas de lancement, code 1' {
        $empty = Join-Path $script:Base 'sans-pwsh'; New-Item -ItemType Directory -Force $empty | Out-Null
        $line = "set `"PATH=$env:WINDIR\System32`" & set `"ProgramFiles=$empty`" & set `"LOCALAPPDATA=$empty`" & set FLOW_NOPAUSE=1 & call `"$(Join-Path $script:Root 'FLOW.cmd')`""
        $out = (cmd /c $line 2>&1 | Out-String)
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'PowerShell 7 est introuvable'
        $out | Should -Match 'install\.cmd'
    }
    It 'FLOW.cmd vérifie pwsh avant de lancer quoi que ce soit' {
        $c = Get-Content (Join-Path $script:Root 'FLOW.cmd') -Raw
        $c.IndexOf('where pwsh') | Should -BeGreaterThan -1
        $c.IndexOf('where pwsh') | Should -BeLessThan $c.IndexOf('start ')
    }
    It 'FLOW.exe vérifie pwsh avant d''ouvrir Windows Terminal, et renvoie vers install.cmd' {
        $c = Get-Content (Join-Path $script:Root 'app\FlowApp.cs') -Raw -Encoding UTF8
        $c | Should -Match 'FindPwsh\(\)'
        $c.IndexOf('var pwsh = FindPwsh()') | Should -BeLessThan $c.IndexOf('TryStart("wt.exe"')
        $c | Should -Match 'install\.cmd'
    }
    It 'sans compilateur, la compilation de FLOW.exe le dit et renvoie vers FLOW.cmd' {
        $keep = $env:WINDIR
        try {
            . (Join-Path $script:Root 'FLOW.ps1') -LoadOnly
            $env:WINDIR = Join-Path $script:Base 'pas-de-windows'
            $msg = (Build-App 6>&1 | Out-String)
        } finally { $env:WINDIR = $keep }
        $msg | Should -Match 'n.a pas pu être compilé'
        $msg | Should -Match 'FLOW\.cmd'
    }
}

Describe 'Garde-fous sur la déclaration' {
    It 'aucun identifiant winget n''est écrit en dur ailleurs que dans dependances.json (code, README, outils)' {
        $ids = @(Get-FlowDeps | Where-Object { $_.winget } | ForEach-Object { $_.winget })
        $files = @(& git -C $script:Root ls-files '*.ps1' '*.cs' '*.cmd' '*.md' '*.yml' '*.json' 2>$null | Where-Object {
                $_ -and $_ -notmatch '^(dependances\.json|CHANGELOG\.md)$' -and $_ -notmatch '^tests/' })
        $files.Count | Should -BeGreaterThan 10
        $hits = foreach ($f in $files) {
            $txt = Get-Content (Join-Path $script:Root $f) -Raw -Encoding UTF8
            foreach ($id in $ids) { if ($txt -match [regex]::Escape($id)) { "$f : $id" } }
            if ($txt -match 'winget\s+(install|upgrade)\s+(--id\s+)?[A-Za-z0-9]+\.[A-Za-z0-9\.]+') { "$f : commande winget avec identifiant écrit en dur" }
        }
        @($hits) | Should -BeNullOrEmpty
    }
    It 'le tableau du README est celui que produit la déclaration' {
        $readme = (Get-Content (Join-Path $script:Root 'README.md') -Raw -Encoding UTF8).Replace("`r`n", "`n")
        $m = [regex]::Match($readme, '(?s)<!-- DEPENDANCES:DEBUT -->\n(.*?)\n<!-- DEPENDANCES:FIN -->')
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Be (Get-DepsMarkdown)
        $readme | Should -Not -Match 'winget install'                    # plus de commande recopiée dans le README
    }
    It 'la CI passe par tests\run.ps1 (même règle de version de Pester) et n''installe pas Pester elle-même' {
        $ci = Get-Content (Join-Path $script:Root '.github\workflows\ci.yml') -Raw
        $ci | Should -Match 'tests/run\.ps1'
        $ci | Should -Not -Match 'Install-Module|Save-Module'
        $run = Get-Content (Join-Path $PSScriptRoot 'run.ps1') -Raw
        $run | Should -Match '-MaximumVersion'
        $run | Should -Not -Match 'Sort-Object Name'                      # tri de versions comme du texte : interdit
    }
    It 'le CHANGELOG note les versions de psmux et de Claude Code avec lesquelles la version courante a été essayée' {
        $cl = (Get-Content (Join-Path $script:Root 'CHANGELOG.md') -Raw -Encoding UTF8).Replace("`r`n", "`n")
        $top = [regex]::Match($cl, '(?s)^# Journal des changements\n+## [^\n]*\n(.*?)(?=\n## )').Groups[1].Value
        $top | Should -Match 'Essayé avec'
        $top | Should -Match ('psmux ' + [regex]::Escape((Get-FlowDep -Id 'psmux').testee))
        $top | Should -Match ('Claude Code ' + [regex]::Escape((Get-FlowDep -Id 'claude').testee))
    }
}
