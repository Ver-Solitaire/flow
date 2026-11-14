#Requires -Version 7
# Le tri (tools\flow-curation.ps1) : contrôles mécaniques, contradictions, actions avec archivage, écran, proposition. Aucun vrai Claude, aucun vrai compte.

BeforeAll {
    $global:FlowRoot = Split-Path $PSScriptRoot -Parent
    $global:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowtri-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $global:Base | Out-Null
    . (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -LoadOnly -Repo $global:Base
    foreach ($n in 'RepoRoot', 'RunDir', 'WtRoot', 'State', 'Cfg', 'Psmux', 'GitCode', 'RevJobs', 'GuidedPrefFile') { Remove-Variable -Name $n -Scope Local -ErrorAction SilentlyContinue }
    $env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
    $global:FlowLogFile = Join-Path $global:Base 'flow.log'
    $global:GuidedPrefFile = Join-Path $global:Base 'team-prefs.json'
    $global:FlowNoAi = $true
    $global:FlowSkillDirs = $null

    Remove-Item Alias:cls -Force -ErrorAction SilentlyContinue
    function Notify { }
    function Cls { }
    function Show-Frame { }
    function Git-Run([string]$dir, [string[]]$a) { & git -C $dir -c user.name=t -c user.email=t@t @a 2>&1 | Out-String }
    function Wait-Job-Spinner($job, [string]$label) { [void](Wait-Job $job); $rv = Receive-Job $job; Remove-Job $job -Force; $rv }
    function Envelope([string]$json) { (@{ result = $json; is_error = $false } | ConvertTo-Json -Compress) }
    $global:KeyQ = [Collections.Generic.Queue[string]]::new()
    function Key-Of([string]$c) {
        if ($c -eq 'esc') { [pscustomobject]@{ Key = 'Escape'; KeyChar = [char]27; Modifiers = 0 } } elseif ($c -eq 'enter') { [pscustomobject]@{ Key = 'Enter'; KeyChar = [char]13; Modifiers = 0 } }
        elseif ($c -eq 'down') { [pscustomobject]@{ Key = 'DownArrow'; KeyChar = [char]0; Modifiers = 0 } } else { [pscustomobject]@{ Key = $c.ToUpper(); KeyChar = [char]$c; Modifiers = 0 } }
    }
    function Read-KeyOrHint { Key-Of $(if ($global:KeyQ.Count) { $global:KeyQ.Dequeue() } else { 'esc' }) }
    function Read-Action { param([switch]$Wait, [int]$TimeoutMs = 0, [switch]$Wheel) @{ K = (Read-KeyOrHint) } }
    function Message-Screen { param($title, $body, $keys) $global:Screens += "$title :: $($body -join ' | ')"; Read-KeyOrHint }
    $global:Installed = @()
    function Install-Skills([string]$claudeDir) { $global:Installed += $claudeDir }
    $global:Router = ''; $global:Prompt = ''
    function Start-ClaudeJob([string]$cwd, $acct, [string]$promptFile, [string]$model, [string]$tools, [string]$addDir = '') {
        $global:Prompt = Get-Content -LiteralPath $promptFile -Raw -Encoding utf8
        $j = Start-Job -ScriptBlock { param($o) [pscustomobject]@{ Code = 0; Out = $o } } -ArgumentList $global:Router
        [void](Wait-Job $j); $j
    }

    function New-TriProject {
        $d = Join-Path $global:Base ([guid]::NewGuid().ToString('N').Substring(0, 6)); $p = Join-Path $d 'proj'
        New-Item -ItemType Directory -Force "$p\memoire", "$p\src", "$p\.flow\workflow" | Out-Null
        $global:RepoRoot = $p
        [void](Git-Run $p @('init', '-q', '-b', 'main'))
        Set-Content "$p\src\app.js" 'x'; Set-Content "$p\.gitignore" "journal-local.log`n"
        Set-Content "$p\CLAUDE.md" "# Projet`n`n## Règles`n- Toujours écrire les messages d'erreur en français dans toute l'application`n- Les routes restent compatibles avec la version précédente de l'API`n" -Encoding utf8
        Set-Content "$p\memoire\INDEX.md" "# INDEX`n`n| Fiche | Contenu | Mots-clés |`n|---|---|---|`n| [decisions.md](decisions.md) | Décisions | choix |`n| [pieges.md](pieges.md) | Pièges | bugs |`n" -Encoding utf8
        Set-Content "$p\memoire\decisions.md" "# Décisions`nMis à jour : 10/11/2026`n`n## État actuel`n- On garde SQLite pour la base de données du projet`n" -Encoding utf8
        Set-Content "$p\memoire\pieges.md" "# Pièges`nMis à jour : 10/11/2026`n`n## État actuel`n- Le port 5000 est déjà pris par un autre service de la machine`n" -Encoding utf8
        [void](Git-Run $p @('add', '-A')); [void](Git-Run $p @('commit', '-q', '-m', 'init'))
        $global:Cfg = [pscustomobject]@{ checks = @(); protectedPaths = @(); guardrails = @(); hooks = $false; commitStyle = 'libre'; deliver = 'merge'; detected = @(); branchPrefix = 'flow/'; targetBranch = $null }
        $global:Screens = @(); $global:KeyQ.Clear(); $global:Installed = @(); $global:FlowSkillDirs = $null
        $global:FlowTriOffered = $false; $global:FlowWfOffered = $true
        $p
    }
    function Types($f) { @($f | ForEach-Object { $_.type }) }
    function Put([string]$rel, [string]$text) { $f = Join-Path $global:RepoRoot $rel; New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null; Set-Content $f $text -Encoding utf8 }
}

AfterAll { Remove-Item -LiteralPath $global:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Texte : normalisation et puces' {
    It 'deux phrases qui ne diffèrent que par la casse, les accents, la ponctuation et les guillemets typographiques sont identiques' {
        (Norm-Text 'Toujours écrire les messages d''erreur « en français » !') | Should -Be (Norm-Text ('toujours ecrire les messages d' + [char]0x2019 + 'erreur en francais'))
        (Jaccard (Words-Of 'les routes restent compatibles') (Words-Of 'les routes restent compatibles')) | Should -Be 1.0
        (Jaccard @('a') @()) | Should -Be 0.0
    }
    It 'les puces ignorent blocs de code, tableaux, textes trop courts et modèles « (à compléter) »' {
        [void](New-TriProject)
        Put 'memoire\x.md' "# X`n- une puce assez longue pour être retenue`n- court`n``````n- une puce dans un bloc de code qui doit être ignorée`n``````n| a | b |`n- (à compléter : décrire)`n1. une puce numérotée assez longue aussi`n"
        $b = @(Get-Bullets "$RepoRoot\memoire\x.md" 'memoire\x.md')
        $b.text | Should -Be @('une puce assez longue pour être retenue', 'une puce numérotée assez longue aussi')
        $b[0].line | Should -Be 2
    }
}

Describe 'Références mortes' {
    It 'signale un fichier cité qui n''existe plus, pas ceux qui existent, ni les URL, jokers, chemins ignorés par Git ou absolus' {
        [void](New-TriProject)
        Put 'memoire\ref.md' "# R`n- Le routeur est dans ``src/app.js`` et le module ``src/disparu.js`` s'en sert pour les routes`n- Voir ``https://exemple.org/doc.md`` et ``src/*.js`` ainsi que ``journal-local.log`` pour le détail`n- Le test ``src/app.js:12`` et ``C:\Windows\x.dll`` existent ailleurs sur la machine`n"
        $f = @(Check-DeadRefs @(All-Statements))
        @($f).Count | Should -Be 1
        $f[0].titre | Should -Match 'src\\disparu.js|src/disparu.js'
        $f[0].type | Should -Be 'ref-morte'
        $f[0].sources[0].file | Should -Be 'memoire\ref.md'
    }
    It 'un chemin relatif à la fiche est accepté' {
        [void](New-TriProject)
        Put 'memoire\detail.md' 'contenu'
        Put 'memoire\ref2.md' "# R`n- Les détails sont dans ``detail.md`` pour les curieux de la question`n"
        @(Check-DeadRefs @(All-Statements)).Count | Should -Be 0
    }
}

Describe 'Doublons' {
    It 'la même affirmation dans CLAUDE.md et une fiche : un constat, la source la plus prioritaire en premier' {
        [void](New-TriProject)
        Put 'memoire\regles.md' "# R`n- Toujours ÉCRIRE les messages d'erreur en français, dans toute l'application !`n"
        $f = @(Check-Duplicates @(All-Statements) | Where-Object { $_.type -eq 'doublon' })
        $f.Count | Should -Be 1
        $f[0].sources.Count | Should -Be 2
        $f[0].sources[0].file | Should -Be 'CLAUDE.md'                       # le cahier, puis CLAUDE.md, puis la mémoire
        $f[0].sources[1].file | Should -Be 'memoire\regles.md'
    }
    It 'presque identiques (85 % des mots) dans deux fichiers : signalé ; dans le même fichier : non' {
        [void](New-TriProject)
        Put 'memoire\a.md' "# A`n- On utilise PostgreSQL en production avec des sauvegardes chaque nuit et un compte de lecture seule pour les rapports`n"
        Put 'memoire\b.md' "# B`n- On utilise PostgreSQL en production avec des sauvegardes chaque nuit et un compte de lecture seule pour les rapports internes`n"
        $f = @(Check-Duplicates @(All-Statements) | Where-Object { $_.type -eq 'quasi-doublon' })
        $f.Count | Should -Be 1
        Put 'memoire\b.md' "# B`n- Tout autre sujet complètement différent à propos des couleurs de l'interface et de leur contraste`n"
        Put 'memoire\a.md' "# A`n- On utilise PostgreSQL en production avec des sauvegardes chaque nuit et un compte de lecture seule pour les rapports`n- On utilise PostgreSQL en production avec des sauvegardes chaque nuit et un compte de lecture seule pour les rapports internes`n"
        @(Check-Duplicates @(All-Statements) | Where-Object { $_.type -eq 'quasi-doublon' }).Count | Should -Be 0
    }
}

Describe 'INDEX, fraîcheur, cohérence' {
    It 'INDEX : fiche absente de l''INDEX et lien mort' {
        [void](New-TriProject)
        Put 'memoire\orpheline.md' "# O`n- contenu"
        Add-Content "$RepoRoot\memoire\INDEX.md" "| [fantome.md](fantome.md) | Rien | rien |" -Encoding utf8
        $f = @(Check-Index)
        (Types $f) | Should -Contain 'index-manquant'
        (Types $f) | Should -Contain 'index-mort'
        ($f | Where-Object { $_.type -eq 'index-manquant' }).titre | Should -Match 'orpheline.md'
        ($f | Where-Object { $_.type -eq 'index-mort' }).titre | Should -Match 'fantome.md'
    }
    It 'fiche très ancienne alors que le projet a avancé, fiche trop longue' {
        [void](New-TriProject)
        Put 'memoire\vieille.md' "# V`nMis à jour : 01/01/2025`n- contenu"
        Put 'memoire\enorme.md' ("# E`n" + ((1..300 | ForEach-Object { "ligne $_" }) -join "`n"))
        $f = @(Check-Freshness)
        (Types $f) | Should -Contain 'fiche-ancienne'
        (Types $f) | Should -Contain 'fiche-grande'
    }
    It 'cahier ≠ profil : des données protégées dans le cahier mais pas dans le profil' {
        [void](New-TriProject)
        Put '.flow\workflow\CAHIER.md' "# Cahier`n## Données à protéger`n- data/prod`n- secrets`n`n## Critère de réussite`nTout passe."
        Write-Roadmap @([pscustomobject]@{ id = 'E1'; titre = 't'; but = 'b'; documents = @('src/app.js', 'docs/absent.md'); passe = 'complète'; etat = 'à faire' })
        $Cfg.protectedPaths = @('secrets')
        $f = @(Check-Consistency)
        $inc = $f | Where-Object { $_.type -eq 'incoherence' }
        $inc.titre | Should -Match 'data/prod'
        $inc.titre | Should -Not -Match 'secrets'
        ($f | Where-Object { $_.type -eq 'ref-morte' }).titre | Should -Match 'docs/absent.md'
    }
}

Describe 'Skills' {
    BeforeEach {
        [void](New-TriProject)
        $global:S1 = Join-Path $global:Base ('skills1-' + [guid]::NewGuid().ToString('N').Substring(0, 5)); $global:S2 = Join-Path $global:Base ('skills2-' + [guid]::NewGuid().ToString('N').Substring(0, 5))
        New-Item -ItemType Directory -Force $global:S1, $global:S2 | Out-Null
        $global:FlowSkillDirs = @($global:S1, $global:S2)
        function Skill([string]$root, [string]$dir, [string]$name, [string]$desc, [string]$body = 'corps') { New-Item -ItemType Directory -Force "$root\$dir" | Out-Null; Set-Content "$root\$dir\SKILL.md" "---`nname: $name`ndescription: $desc`n---`n$body" -Encoding utf8 }
    }
    It 'même nom, contenus différents dans deux comptes : signalé ; mêmes contenus : non' {
        Skill $S1 'a' 'projet-x' 'décrit un sujet' 'version 1'; Skill $S2 'a' 'projet-x' 'décrit un sujet' 'version 2'
        (Types (Check-Skills)) | Should -Contain 'skill-double'
        Skill $S2 'a' 'projet-x' 'décrit un sujet' 'version 1'
        (Types (Check-Skills)) | Should -Not -Contain 'skill-double'
    }
    It 'sans description : signalé ; descriptions presque identiques dans un même compte : signalé' {
        New-Item -ItemType Directory -Force "$S1\vide" | Out-Null; Set-Content "$S1\vide\SKILL.md" "---`nname: vide`n---`ncorps" -Encoding utf8
        Skill $S1 'u' 'creer-site' 'crée un nouveau site web complet à partir de zéro avec structure dossiers et premier commit propre'
        Skill $S1 'v' 'creer-appli' 'crée un nouveau site web complet à partir de zéro avec structure dossiers et premier commit propre aussi'
        $t = Types (Check-Skills)
        $t | Should -Contain 'skill-incomplet'
        $t | Should -Contain 'skill-chevauche'
    }
    It 'un skill de FLOW dont la copie diffère de celle livrée est obsolète ; l''action le remet à jour après archivage' {
        New-Item -ItemType Directory -Force "$S1\projet-creer" | Out-Null
        Set-Content "$S1\projet-creer\SKILL.md" "---`nname: projet-creer`ndescription: vieille version`n---`nancien" -Encoding utf8
        Set-Content "$S1\projet-creer\.flow-skill" '' -Encoding utf8
        $f = @(Check-Skills | Where-Object { $_.type -eq 'skill-obsolete' })
        $f.Count | Should -Be 1
        $msg = Apply-Finding $f[0] 'x'
        $msg | Should -Match 'remis à jour'
        (Get-Content "$S1\projet-creer\SKILL.md" -Raw) | Should -Not -Match 'ancien'
        @(Check-Skills | Where-Object { $_.type -eq 'skill-obsolete' }).Count | Should -Be 0
        @(Get-ChildItem "$RepoRoot\.flow\tri\archives" -Recurse -Filter SKILL.md).Count | Should -Be 1
    }
    It 'rien n''est examiné pendant les tests, sauf dossier d''essai explicite (jamais les vrais comptes)' {
        $global:FlowSkillDirs = $null
        @(Skill-Dirs).Count | Should -Be 0
    }
}

Describe 'Candidats en retard et conflits du scribe' {
    It 'plus de 40 candidats : signalé ; chaque puce de conflits.md devient un constat grave' {
        [void](New-TriProject)
        New-Item -ItemType Directory -Force "$RepoRoot\.flow\candidats" | Out-Null
        1..45 | ForEach-Object { @{ t = (Get-Date).ToString('o'); genre = 'preference'; texte = "c$_" } | ConvertTo-Json -Compress | Add-Content "$RepoRoot\.flow\candidats\candidats.jsonl" -Encoding utf8 }
        Put 'memoire\conflits.md' "# Conflits à trancher`n- [12/11] ancien : on garde SQLite (decisions.md) | nouveau : migration vers PostgreSQL (retour de l'utilisateur)`n"
        $f = @(Check-Backlog)
        (Types $f) | Should -Contain 'candidats'
        $c = $f | Where-Object { $_.type -eq 'conflit' }
        $c.gravite | Should -Be 'haute'
        $c.sources[0].file | Should -Be 'memoire\conflits.md'
    }
}

Describe 'Ce qui est ignoré ne revient pas' {
    It 'l''empreinte d''un constat est stable, et un constat ignoré n''apparaît plus' {
        [void](New-TriProject)
        Put 'memoire\ref.md' "# R`n- Le module ``src/disparu.js`` s'en sert pour toutes les routes de l'application`n"
        $a = @(Scan-Project | Where-Object { $_.type -eq 'ref-morte' })
        $a.Count | Should -Be 1
        $b = @(Scan-Project | Where-Object { $_.type -eq 'ref-morte' })
        $b[0].id | Should -Be $a[0].id
        Apply-Finding $a[0] 'i' | Out-Null
        @(Scan-Project | Where-Object { $_.type -eq 'ref-morte' }).Count | Should -Be 0
        @(Scan-Project -IncludeIgnored | Where-Object { $_.type -eq 'ref-morte' }).Count | Should -Be 1
    }
}

Describe 'Appliquer : archive d''abord, rien de perdu' {
    It 'retire la ligne voulue (retrouvée par son texte), garde les fins de ligne CRLF, archive l''original et journalise' {
        [void](New-TriProject)
        [IO.File]::WriteAllText("$RepoRoot\memoire\f.md", "# F`r`n- première puce assez longue pour exister`r`n- seconde puce assez longue à retirer ici`r`n- troisième puce assez longue aussi`r`n", [Text.UTF8Encoding]::new($false))
        $src = [pscustomobject]@{ file = 'memoire\f.md'; line = 9; text = 'seconde puce assez longue à retirer ici' }       # numéro de ligne périmé : retrouvée par son texte
        Remove-SourceLine $src | Should -BeTrue
        $raw = [IO.File]::ReadAllText("$RepoRoot\memoire\f.md")
        $raw | Should -Not -Match 'seconde puce'
        $raw | Should -Match "première puce assez longue pour exister`r`n- troisième"
        $arch = Get-ChildItem "$RepoRoot\.flow\tri\archives" -Recurse -Filter f.md
        $arch.Count | Should -Be 1
        (Get-Content $arch[0].FullName -Raw) | Should -Match 'seconde puce'
        (Get-Content "$RepoRoot\.flow\tri\journal.md" -Raw -Encoding utf8) | Should -Match 'ligne retirée de memoire\\f.md'
    }
    It 'une ligne qui n''existe plus : rien n''est touché, pas d''archive' {
        [void](New-TriProject)
        Remove-SourceLine ([pscustomobject]@{ file = 'memoire\pieges.md'; line = 1; text = 'texte inexistant partout' }) | Should -BeFalse
        Test-Path "$RepoRoot\.flow\tri\archives" | Should -BeFalse
    }
    It 'doublon : « garder 1 » retire les autres sources seulement' {
        [void](New-TriProject)
        Put 'memoire\regles.md' "# R`n- Toujours écrire les messages d'erreur en français dans toute l'application`n"
        $d = @(Check-Duplicates @(All-Statements) | Where-Object { $_.type -eq 'doublon' })[0]
        $msg = Apply-Finding $d '1'
        $msg | Should -Match '1 ligne'
        (Get-Content "$RepoRoot\CLAUDE.md" -Raw) | Should -Match 'Toujours écrire les messages'
        (Get-Content "$RepoRoot\memoire\regles.md" -Raw) | Should -Not -Match 'Toujours écrire'
    }
    It 'INDEX : l''action ajoute la fiche au tableau, après archivage' {
        [void](New-TriProject)
        Put 'memoire\orpheline.md' "# O`n- contenu"
        $f = @(Check-Index | Where-Object { $_.type -eq 'index-manquant' })[0]
        Apply-Finding $f 'x' | Out-Null
        $idx = Get-Content "$RepoRoot\memoire\INDEX.md" -Raw -Encoding utf8
        $idx | Should -Match '\[orpheline.md\]\(orpheline.md\)'
        @(Check-Index | Where-Object { $_.type -eq 'index-manquant' }).Count | Should -Be 0
        @(Get-ChildItem "$RepoRoot\.flow\tri\archives" -Recurse -Filter INDEX.md).Count | Should -Be 1
    }
    It 'incohérence cahier ≠ profil : l''action aligne le profil (et le garde dans .flow\config.json)' {
        [void](New-TriProject)
        Put '.flow\workflow\CAHIER.md' "# Cahier`n## Données à protéger`n- data/prod`n`n## Critère de réussite`nok"
        $f = @(Check-Consistency | Where-Object { $_.type -eq 'incoherence' })[0]
        Apply-Finding $f 'x' | Out-Null
        @($Cfg.protectedPaths) | Should -Contain 'data/prod'
        (Get-Content "$RepoRoot\.flow\config.json" -Raw | ConvertFrom-Json).protectedPaths | Should -Contain 'data/prod'
        @(Check-Consistency | Where-Object { $_.type -eq 'incoherence' }).Count | Should -Be 0
    }
}

Describe 'Contradictions (Claude)' {
    BeforeEach {
        [void](New-TriProject)
        $global:FlowNoAi = $false
        function Log-Call([string]$role, $acct, [string]$model, $res) { }
    }
    AfterEach { $global:FlowNoAi = $true }
    It 'une paire trouvée devient un constat avec ses deux sources (la plus prioritaire d''abord) ; un numéro inventé est écarté' {
        Put 'memoire\actuel.md' "# A`n- On est passé à PostgreSQL pour la base de données du projet cette semaine`n"
        $st = @(All-Statements); $iSql = ($st | Where-Object { $_.text -match 'SQLite' }).sid
        $stm = @(All-Statements); $n = 0; foreach ($s in $stm) { $n++ }
        $ids = @{}; $k = 0; foreach ($s in (All-Statements | Select-Object -First 250)) { $k++; $ids[$s.text] = "S$k" }
        $a = $ids[((All-Statements) | Where-Object { $_.text -match 'SQLite' }).text]; $b = $ids[((All-Statements) | Where-Object { $_.text -match 'PostgreSQL' }).text]
        $global:Router = Envelope ('{"contradictions":[{"a":"' + $a + '","b":"' + $b + '","pourquoi":"SQLite ou PostgreSQL, pas les deux","gravite":"haute"},{"a":"S999","b":"' + $a + '","pourquoi":"inventé","gravite":"haute"},{"a":"' + $a + '","b":"' + $a + '","pourquoi":"même","gravite":"haute"}]}')
        $f = @(Find-Contradictions)
        $f.Count | Should -Be 1
        $f[0].type | Should -Be 'contradiction'
        $f[0].gravite | Should -Be 'haute'
        $f[0].detail | Should -Match 'pas les deux'
        $f[0].sources.Count | Should -Be 2
        $global:Prompt | Should -Match 'CONTRADICTIONS'
        $global:Prompt | Should -Match 'On garde SQLite'
        $global:Prompt | Should -Match '\[memoire\\actuel.md\]'
    }
    It 'aucune contradiction : liste vide ; réponse illisible : $null (pas de faux « tout va bien »)' {
        $global:Router = Envelope '{"contradictions":[]}'
        @(Find-Contradictions).Count | Should -Be 0
        $global:Router = 'pas du JSON'
        Find-Contradictions | Should -BeNullOrEmpty
        (Find-Contradictions) -eq $null | Should -BeTrue
    }
    It 'moins de deux affirmations : aucun appel' {
        $d = Join-Path $global:Base 'vide'; New-Item -ItemType Directory -Force $d | Out-Null; $global:RepoRoot = $d
        $global:Prompt = ''
        @(Find-Contradictions).Count | Should -Be 0
        $global:Prompt | Should -Be ''
    }
}

Describe 'L''écran du tri' {
    It 'rien à trier : message clair ; Échap revient et mémorise le tri (compteur de livraisons remis à zéro)' {
        [void](New-TriProject)
        $s = Tri-State; $s.deliveries = 5; Save-TriState $s
        $global:KeyQ.Enqueue('esc')
        Mode-Tri -Initial @() | Should -Be 'quit'
        (Tri-State).deliveries | Should -Be 0
        (Tri-State).last | Should -Not -BeNullOrEmpty
    }
    It 'garder la source 1 : la ligne en trop est retirée et le point disparaît de la liste' {
        [void](New-TriProject)
        Put 'memoire\regles.md' "# R`n- Toujours écrire les messages d'erreur en français dans toute l'application`n"
        $global:KeyQ.Enqueue('1'); $global:KeyQ.Enqueue('esc')
        [void](Mode-Tri)
        (Get-Content "$RepoRoot\memoire\regles.md" -Raw) | Should -Not -Match 'Toujours écrire'
        (Get-Content "$RepoRoot\CLAUDE.md" -Raw) | Should -Match 'Toujours écrire'
    }
    It 'retirer une ligne de CLAUDE.md ou du cahier demande une confirmation explicite' {
        [void](New-TriProject)
        Put 'memoire\regles.md' "# R`n- Toujours écrire les messages d'erreur en français dans toute l'application`n"
        $global:KeyQ.Enqueue('2'); $global:KeyQ.Enqueue('esc'); $global:KeyQ.Enqueue('esc')          # garder 2 = retirer CLAUDE.md → confirmation → refus
        [void](Mode-Tri)
        (Get-Content "$RepoRoot\CLAUDE.md" -Raw) | Should -Match 'Toujours écrire'
        ($global:Screens -join ' ') | Should -Match 'modifier un fichier de règles'
        $global:KeyQ.Clear()
        $global:KeyQ.Enqueue('2'); $global:KeyQ.Enqueue('o'); $global:KeyQ.Enqueue('esc')            # même chose, confirmé
        [void](Mode-Tri)
        (Get-Content "$RepoRoot\CLAUDE.md" -Raw) | Should -Not -Match 'Toujours écrire'
        @(Get-ChildItem "$RepoRoot\.flow\tri\archives" -Recurse -Filter CLAUDE.md).Count | Should -Be 1
    }
    It 'ignorer : le point ne revient plus' {
        [void](New-TriProject)
        Put 'memoire\ref.md' "# R`n- Le module ``src/disparu.js`` s'en sert pour toutes les routes de l'application`n"
        $global:KeyQ.Enqueue('i'); $global:KeyQ.Enqueue('esc')
        [void](Mode-Tri)
        @(Scan-Project | Where-Object { $_.type -eq 'ref-morte' }).Count | Should -Be 0
    }
    It 'doublons exacts en lot : confirmation, garde la première source, ne touche jamais CLAUDE.md ni le cahier' {
        [void](New-TriProject)
        Put 'memoire\regles.md' "# R`n- Toujours écrire les messages d'erreur en français dans toute l'application`n"
        Put 'memoire\autre.md' "# R`n- Toujours écrire les messages d'erreur en français dans toute l'application`n"
        $global:KeyQ.Enqueue('m'); $global:KeyQ.Enqueue('o'); $global:KeyQ.Enqueue('esc')
        [void](Mode-Tri)
        (Get-Content "$RepoRoot\CLAUDE.md" -Raw) | Should -Match 'Toujours écrire'
        $left = @('regles.md', 'autre.md' | Where-Object { (Get-Content "$RepoRoot\memoire\$_" -Raw) -match 'Toujours écrire' })
        $left.Count | Should -Be 0
    }
    It 'C : ajoute les contradictions trouvées par Claude à la liste' {
        [void](New-TriProject)
        $global:FlowNoAi = $false
        function Log-Call([string]$role, $acct, [string]$model, $res) { }
        Put 'memoire\actuel.md' "# A`n- On est passé à PostgreSQL pour la base de données du projet cette semaine`n"
        $k = 0; $ids = @{}; foreach ($s in (All-Statements | Select-Object -First 250)) { $k++; $ids[$s.text] = "S$k" }
        $a = $ids[((All-Statements) | Where-Object { $_.text -match 'SQLite' }).text]; $b = $ids[((All-Statements) | Where-Object { $_.text -match 'PostgreSQL' }).text]
        $global:Router = Envelope ('{"contradictions":[{"a":"' + $a + '","b":"' + $b + '","pourquoi":"incompatibles","gravite":"haute"}]}')
        $global:KeyQ.Enqueue('c'); $global:KeyQ.Enqueue('i'); $global:KeyQ.Enqueue('esc')
        try { [void](Mode-Tri) } finally { $global:FlowNoAi = $true }
        $global:Prompt | Should -Match 'CONTRADICTIONS'
        @(Tri-Ignored).Count | Should -Be 1                                                           # le premier point de la liste était la contradiction (grave) : ignorée
    }
}

Describe 'Proposer le tri' {
    BeforeEach { [void](New-TriProject); $global:FlowNoAi = $false }
    AfterEach { $global:FlowNoAi = $true }
    It 'rien d''anormal et peu de livraisons : pas de proposition' {
        Tri-Offer-Due | Should -BeNullOrEmpty
    }
    It 'un point grave justifie la proposition ; elle n''est faite qu''une fois par session' {
        Put '.flow\workflow\CAHIER.md' "# Cahier`n## Données à protéger`n- data/prod`n`n## Critère de réussite`nok"
        $d = Tri-Offer-Due
        $d | Should -Not -BeNullOrEmpty
        $d.Why | Should -Match 'grave'
        $global:FlowTriOffered = $true
        Tri-Offer-Due | Should -BeNullOrEmpty
    }
    It '8 équipes livrées depuis le dernier tri : proposé ; « plus tard » le repousse, « ne plus proposer » le coupe' {
        $s = Tri-State; $s.deliveries = 8; Save-TriState $s
        (Tri-Offer-Due).Why | Should -Match '8 équipes livrées'
        $s.snoozeUntil = (Get-Date).AddDays(7).ToString('o'); Save-TriState $s
        Tri-Offer-Due | Should -BeNullOrEmpty
        $s.snoozeUntil = ''; $s.declined = $true; Save-TriState $s
        Tri-Offer-Due | Should -BeNullOrEmpty
    }
    It 'jamais pendant les tests (FlowNoAi) ni sans mémoire, cahier ou CLAUDE.md' {
        $global:FlowNoAi = $true
        Tri-Offer-Due | Should -BeNullOrEmpty
        $global:FlowNoAi = $false
        $d = Join-Path $global:Base 'rien'; New-Item -ItemType Directory -Force $d | Out-Null; $global:RepoRoot = $d
        Tri-Offer-Due | Should -BeNullOrEmpty
    }
    It 'à l''accueil : N (« ne plus proposer ») est retenu ; S repousse de 7 jours' {
        function Open-Runs { @() }
        function Read-Prompt($x) { $null }
        $s = Tri-State; $s.deliveries = 9; Save-TriState $s
        $global:KeyQ.Enqueue('n'); [void](Mode-Home)
        (Tri-State).declined | Should -BeTrue
        $s = Tri-State; $s.declined = $false; Save-TriState $s; $global:FlowTriOffered = $false
        $global:KeyQ.Enqueue('s'); [void](Mode-Home)
        ([datetime](Tri-State).snoozeUntil) | Should -BeGreaterThan (Get-Date).AddDays(6)
    }
    It 'chaque livraison compte ; le scribe sait noter une contradiction au lieu de l''écraser' {
        Tri-Note-Delivery; Tri-Note-Delivery
        (Tri-State).deliveries | Should -Be 2
        (Get-Content (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -Raw -Encoding utf8) | Should -Match 'memoire\\conflits.md'
        (Get-Content (Join-Path $global:FlowRoot 'tools\flow-team.ps1') -Raw -Encoding utf8) | Should -Match 'ne remplace RIEN'
    }
}
