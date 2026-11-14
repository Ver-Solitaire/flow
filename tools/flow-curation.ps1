# flow-curation.ps1 - le TRI : garder la mémoire, les règles et les skills d'un projet sains, sans contradictions (chargé avec « . » par flow-team.ps1).
#
# FLOW ne trie pas selon un calendrier : il PROPOSE un tri quand un signal le justifie (livraisons depuis le dernier tri, références mortes, doublons,
# contradictions...). Deux familles de contrôles :
#   MÉCANIQUES (sans Claude, gratuits)  références mortes (fichiers cités qui n'existent plus), doublons exacts ou presque entre fiches / CAHIER / CLAUDE.md,
#                                       INDEX incohérent, fiches trop grandes ou trop anciennes, cahier ≠ profil (données protégées), skills en double ou obsolètes,
#                                       candidats des hooks en retard, conflits notés par le scribe (memoire\conflits.md).
#   PAR CLAUDE (sonnet, à la demande)   contradictions entre deux affirmations (« on garde SQLite » / « on est passé à Postgres »), avec leurs deux sources.
# RÈGLES : rien n'est modifié sans ta validation (une action = une touche) ; chaque fichier modifié est d'abord copié dans .flow\tri\archives\<date>\ ;
# une contradiction n'est jamais tranchée seule ; ce que tu ignores ne revient pas (empreinte dans .flow\tri\ignores.json).

function Tri-Dir { Join-Path $RepoRoot '.flow\tri' }
function Tri-StateFile { Join-Path (Tri-Dir) 'etat.json' }
function Tri-IgnoreFile { Join-Path (Tri-Dir) 'ignores.json' }

function Tri-State {
    $d = [pscustomobject]@{ last = ''; deliveries = 0; snoozeUntil = ''; declined = $false }
    try { if (Test-Path -LiteralPath (Tri-StateFile)) { $j = Get-Content -LiteralPath (Tri-StateFile) -Raw -Encoding utf8 | ConvertFrom-Json; foreach ($p in $d.PSObject.Properties) { if ($null -ne $j.($p.Name)) { $d.($p.Name) = $j.($p.Name) } } } } catch {}
    $d
}
function Save-TriState($s) { New-Item -ItemType Directory -Force (Tri-Dir) | Out-Null; Write-JsonAtomic $s (Tri-StateFile) }
function Tri-Note-Delivery { if (-not $RepoRoot) { return }; try { $s = Tri-State; $s.deliveries = [int]$s.deliveries + 1; Save-TriState $s } catch {} }

function Tri-Ignored { try { if (Test-Path -LiteralPath (Tri-IgnoreFile)) { return @(Get-Content -LiteralPath (Tri-IgnoreFile) -Raw -Encoding utf8 | ConvertFrom-Json) } } catch {}; @() }
function Add-Ignored([string]$id) { $l = @(Tri-Ignored) + $id | Select-Object -Unique; New-Item -ItemType Directory -Force (Tri-Dir) | Out-Null; Write-JsonAtomic @($l) (Tri-IgnoreFile) }
function Tri-Journal([string]$text) { try { New-Item -ItemType Directory -Force (Tri-Dir) | Out-Null; Add-Content -LiteralPath (Join-Path (Tri-Dir) 'journal.md') -Value "- $(Get-Date -Format 'dd/MM/yyyy HH:mm') — $text" -Encoding utf8 } catch {} }

# ───────────────────────── texte : puces, normalisation ─────────────────────────
function Norm-Text([string]$s) {
    $d = ("$s").ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $d = [regex]::Replace($d, '\p{Mn}', '')
    $d = [regex]::Replace($d, '[\*_`#>\-:;,\.\(\)\[\]«»"''\u2019\u201C\u201D!?/\\|=+]', ' ')
    ([regex]::Replace($d, '\s+', ' ')).Trim()
}
function Words-Of([string]$norm) { @($norm -split ' ' | Where-Object { $_.Length -ge 3 } | Select-Object -Unique) }
function Jaccard($a, $b) {
    $x = @($a); $y = @($b)
    if (-not $x.Count -or -not $y.Count) { return 0.0 }
    $set = @{}; foreach ($w in $x) { $set[$w] = 1 }
    $inter = 0; foreach ($w in $y) { if ($set.ContainsKey($w)) { $inter++ } }
    [double]$inter / ($x.Count + $y.Count - $inter)
}

function Get-Bullets([string]$path, [string]$rel) {
    # les puces d'un fichier Markdown (hors blocs de code, tableaux et modèles « (à compléter) ») : { file ; line ; text }
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $out = [Collections.Generic.List[object]]::new(); $fence = $false; $n = 0
    foreach ($ln in @(Get-Content -LiteralPath $path -Encoding utf8)) {
        $n++
        if ($ln -match '^\s*```') { $fence = -not $fence; continue }
        if ($fence) { continue }
        $m = [regex]::Match($ln, '^\s{0,4}(?:[-*]|\d+[\.\)])\s+(.{18,})$')
        if (-not $m.Success) { continue }
        $t = $m.Groups[1].Value.Trim()
        if ($t -match '^\((aucun|à compléter|rien|le projet est)' -or $t -match '^\[.*\]\(.*\)$') { continue }
        $out.Add([pscustomobject]@{ file = $rel; line = $n; text = $t })
    }
    @($out)
}

function Statement-Files {
    # les fichiers dont les puces sont des AFFIRMATIONS à comparer : cahier, CLAUDE.md, fiches de mémoire (hors historique)
    $l = @()
    $l += [pscustomobject]@{ rel = '.flow\workflow\CAHIER.md'; prio = 1 }
    $l += [pscustomobject]@{ rel = 'CLAUDE.md'; prio = 2 }
    $mem = Join-Path $RepoRoot 'memoire'
    if (Test-Path -LiteralPath $mem) { foreach ($f in Get-ChildItem -LiteralPath $mem -Filter *.md -File | Where-Object { $_.Name -notin 'INDEX.md', 'historique.md', 'conflits.md' }) { $l += [pscustomobject]@{ rel = "memoire\$($f.Name)"; prio = 3 } } }
    @($l | Where-Object { Test-Path -LiteralPath (Join-Path $RepoRoot $_.rel) })
}

function All-Statements {
    $o = [Collections.Generic.List[object]]::new()
    foreach ($f in @(Statement-Files)) { foreach ($bl in @(Get-Bullets (Join-Path $RepoRoot $f.rel) $f.rel)) { $bl | Add-Member -NotePropertyName prio -NotePropertyValue $f.prio -Force; $o.Add($bl) } }
    @($o)
}

function Finding($type, [string]$gravite, [string]$titre, [string]$detail, $sources, [string]$key, $actions = @()) {
    $id = ([BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("$type|$key"))).Replace('-', '').Substring(0, 10)).ToLower()
    [pscustomobject]@{ id = $id; type = $type; gravite = $gravite; titre = $titre; detail = $detail; sources = @($sources); actions = @($actions) }
}

# ───────────────────────── contrôles mécaniques ─────────────────────────
function Check-DeadRefs($stmts) {
    $out = @()
    $tracked = $null
    foreach ($s in $stmts) {
        foreach ($m in [regex]::Matches($s.text, '`([^`\r\n]{3,120})`')) {
            $tok = $m.Groups[1].Value.Trim()
            if ($tok -match '[<>\*\?\$\(\)=;|{}~]|^https?:|^-|\s' -or $tok -notmatch '[\\/]|\.[A-Za-z0-9]{1,5}(:\d+(-\d+)?)?$') { continue }
            $tok = ($tok -replace ':\d+(-\d+)?$', '')
            if ($tok -notmatch '^[\w\.\-\\/]+$' -or $tok -match '^[A-Za-z]:' -or $tok -notmatch '\.[A-Za-z0-9]{1,5}$|[\\/]') { continue }
            $rel = $tok.Replace('/', '\').TrimStart('.', '\')
            $cands = @((Join-Path $RepoRoot $rel), (Join-Path (Join-Path $RepoRoot (Split-Path $s.file -Parent)) $rel))
            if (@($cands | Where-Object { Test-Path -LiteralPath $_ }).Count) { continue }
            [void](Git-In $RepoRoot @('check-ignore', '-q', $tok.Replace('\', '/')))
            if ($GitCode -eq 0) { continue }                                   # un fichier ignoré par Git peut légitimement être absent
            if ($tok -match '^\.flow[\\/]runs|^\.flow[\\/]candidats|^\.flow[\\/]tri') { continue }
            $out += Finding 'ref-morte' 'moyenne' "Référence à un fichier qui n'existe plus : $tok" "cité dans $($s.file):$($s.line)" @($s) "$($s.file)|$($s.text)|$tok" @('d', 'o', 'i')
        }
    }
    $out
}

function Check-Duplicates($stmts) {
    $out = @(); $byNorm = @{}
    foreach ($s in $stmts) { $n = Norm-Text $s.text; if ($n.Length -lt 25) { continue }; $s | Add-Member -NotePropertyName norm -NotePropertyValue $n -Force; if (-not $byNorm.ContainsKey($n)) { $byNorm[$n] = [Collections.Generic.List[object]]::new() }; $byNorm[$n].Add($s) }
    foreach ($k in $byNorm.Keys) {
        $g = @($byNorm[$k]); if ($g.Count -lt 2) { continue }
        $g = @($g | Sort-Object prio, file, line)
        $out += Finding 'doublon' 'basse' "Même affirmation écrite $($g.Count) fois" "$($g[0].text.Substring(0, [Math]::Min(110, $g[0].text.Length)))" ($g | Select-Object -First 4) "exact|$k" @('1', '2', '3', '4', 'o', 'i')
    }
    # presque doublons : mêmes mots à 85 % ou plus, dans des fichiers différents
    $cand = @($stmts | Where-Object { $_.norm -and $_.norm.Length -ge 60 } | Select-Object -First 400)
    foreach ($c in $cand) { $c | Add-Member -NotePropertyName words -NotePropertyValue (Words-Of $c.norm) -Force }
    $seen = @{}
    for ($i = 0; $i -lt $cand.Count; $i++) {
        for ($j = $i + 1; $j -lt $cand.Count; $j++) {
            $a = $cand[$i]; $c2 = $cand[$j]
            if ($a.file -eq $c2.file -or $a.norm -eq $c2.norm) { continue }
            if ((Jaccard $a.words $c2.words) -ge 0.85) {
                $pair = @($a, $c2) | Sort-Object prio, file, line
                $key = "near|$($pair[0].norm)|$($pair[1].norm)"
                if ($seen.ContainsKey($key)) { continue }; $seen[$key] = 1
                $out += Finding 'quasi-doublon' 'basse' 'Deux affirmations presque identiques' "$($pair[0].text.Substring(0, [Math]::Min(100, $pair[0].text.Length)))" $pair $key @('1', '2', 'o', 'i')
            }
        }
    }
    $out
}

function Check-Index {
    $out = @(); $idx = Join-Path $RepoRoot 'memoire\INDEX.md'
    if (-not (Test-Path -LiteralPath $idx)) { return $out }
    $text = Get-Content -LiteralPath $idx -Raw -Encoding utf8
    $linked = @([regex]::Matches($text, '\]\(([^)\s#]+\.md)\)') | ForEach-Object { $_.Groups[1].Value })
    $n = 0
    foreach ($ln in @(Get-Content -LiteralPath $idx -Encoding utf8)) {
        $n++
        $m = [regex]::Match($ln, '^\|.*\]\(([^)\s#]+\.md)\)')
        if ($m.Success -and -not (Test-Path -LiteralPath (Join-Path (Split-Path $idx -Parent) $m.Groups[1].Value))) {
            $out += Finding 'index-mort' 'moyenne' "INDEX.md renvoie à une fiche absente : $($m.Groups[1].Value)" "ligne $n de memoire\INDEX.md" @([pscustomobject]@{ file = 'memoire\INDEX.md'; line = $n; text = $ln.Trim() }) "$($m.Groups[1].Value)" @('d', 'o', 'i')
        }
    }
    foreach ($f in Get-ChildItem -LiteralPath (Split-Path $idx -Parent) -Filter *.md -File | Where-Object { $_.Name -ne 'INDEX.md' }) {
        if ($linked -notcontains $f.Name) {
            $out += Finding 'index-manquant' 'basse' "Fiche absente de l'INDEX : $($f.Name)" 'une fiche que l''INDEX ne cite pas ne sera jamais ouverte par un Claude qui suit la règle « lire l''INDEX d''abord »' @([pscustomobject]@{ file = "memoire\$($f.Name)"; line = 0; text = $f.Name }) "$($f.Name)" @('x', 'o', 'i')
        }
    }
    $out
}

function Check-Freshness {
    $out = @(); $mem = Join-Path $RepoRoot 'memoire'
    if (-not (Test-Path -LiteralPath $mem)) { return $out }
    $recent = $false
    $lastCommit = "$(Git-In $RepoRoot @('log', '-1', '--format=%ct') | Select-Object -First 1)".Trim()
    if ($lastCommit -match '^\d+$') { $recent = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$lastCommit) -lt 30 * 86400 }
    foreach ($f in Get-ChildItem -LiteralPath $mem -Filter *.md -File) {
        $lines = @(Get-Content -LiteralPath $f.FullName -Encoding utf8)
        if ($lines.Count -gt 250) { $out += Finding 'fiche-grande' 'basse' "Fiche très longue : $($f.Name) ($($lines.Count) lignes)" 'une fiche trop longue n''est plus lue en entier : la découper par sujet' @([pscustomobject]@{ file = "memoire\$($f.Name)"; line = 0; text = $f.Name }) "$($f.Name)|$([int]($lines.Count / 50))" @('o', 'i') }
        $m = [regex]::Match(($lines | Select-Object -First 6) -join "`n", 'Mis à jour\s*:\s*(\d{2})/(\d{2})/(\d{4})')
        if ($m.Success -and $recent -and $f.Name -notin 'historique.md') {
            try { $dt = [datetime]::new([int]$m.Groups[3].Value, [int]$m.Groups[2].Value, [int]$m.Groups[1].Value); $age = ((Get-Date) - $dt).Days } catch { continue }
            if ($age -gt 150) { $out += Finding 'fiche-ancienne' 'basse' "Fiche pas mise à jour depuis $age jours : $($f.Name)" 'le projet a avancé depuis : vérifier qu''elle est encore vraie' @([pscustomobject]@{ file = "memoire\$($f.Name)"; line = 0; text = $f.Name }) "$($f.Name)|$([int]($age / 60))" @('o', 'i') }
        }
    }
    $out
}

function Check-Consistency {
    # le cahier et le profil du projet ne doivent pas se contredire : données protégées, documents de la feuille de route
    $out = @()
    $cf = Join-Path $RepoRoot '.flow\workflow\CAHIER.md'
    if (Test-Path -LiteralPath $cf) {
        $m = [regex]::Match((Get-Content -LiteralPath $cf -Raw -Encoding utf8), '(?s)## Données à protéger\r?\n(.*?)(?=\r?\n## |\z)')
        $inCahier = @($m.Groups[1].Value -split "\r?\n" | Where-Object { $_ -match '^- ' -and $_ -notmatch '^- \(' } | ForEach-Object { (($_ -replace '^- ', '').Trim() -replace '\\', '/').TrimEnd('/').ToLower() })
        $inCfg = @(@($Cfg.protectedPaths) | Where-Object { "$_".Trim() } | ForEach-Object { ("$_".Trim() -replace '\\', '/').TrimEnd('/').ToLower() })
        $miss = @($inCahier | Where-Object { $_ -notin $inCfg })
        if ($miss.Count) { $out += Finding 'incoherence' 'haute' "Le cahier protège des données que le profil ne protège pas : $($miss -join ', ')" 'le profil (.flow\config.json) est ce que lisent les hooks et les vérifications : sans lui, rien n''empêche de les modifier' @([pscustomobject]@{ file = '.flow\workflow\CAHIER.md'; line = 0; text = ($miss -join ', ') }) "prot|$($miss -join ',')" @('x', 'o', 'i') }
    }
    $road = Read-Roadmap
    foreach ($st in @($road.Steps)) {
        foreach ($doc in @($st.documents)) {
            $p = (($doc -replace '/', '\').Trim().TrimEnd('\'))
            if ($p -match '[\*\?<>]|^[A-Za-z]:' -or -not $p) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $p))) {
                [void](Git-In $RepoRoot @('check-ignore', '-q', $doc.Replace('\', '/')))
                if ($GitCode -eq 0) { continue }
                $out += Finding 'ref-morte' 'moyenne' "L'étape $($st.id) cite un document absent : $doc" 'feuille de route (ROADMAP.md)' @([pscustomobject]@{ file = '.flow\workflow\ROADMAP.md'; line = 0; text = "$($st.id) $doc" }) "road|$($st.id)|$doc" @('o', 'i')
            }
        }
    }
    $out
}

function Skill-Dirs {
    # dossiers de skills examinés : ceux de chaque compte et ceux du projet ; rien pendant les tests (sauf dossier d'essai explicite)
    if ($global:FlowSkillDirs) { return @($global:FlowSkillDirs) }
    if ($global:FlowNoAi) { return @() }
    $l = @(); foreach ($a in @($Accs)) { $d = Join-Path $a.Home 'skills'; if (Test-Path -LiteralPath $d) { $l += $d } }
    $pd = Join-Path $RepoRoot '.claude\skills'; if (Test-Path -LiteralPath $pd) { $l += $pd }
    @($l | Select-Object -Unique)
}

function Read-Skill([string]$dir) {
    $f = Join-Path $dir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $txt = Get-Content -LiteralPath $f -Raw -Encoding utf8
    $fm = [regex]::Match($txt, '(?s)^---\r?\n(.*?)\r?\n---')
    $name = ''; $desc = ''
    if ($fm.Success) {
        $mn = [regex]::Match($fm.Groups[1].Value, '(?m)^name:\s*(.+)$'); if ($mn.Success) { $name = $mn.Groups[1].Value.Trim().Trim('"''') }
        $md = [regex]::Match($fm.Groups[1].Value, '(?m)^description:\s*(.+)$'); if ($md.Success) { $desc = $md.Groups[1].Value.Trim().Trim('"''') }
    }
    [pscustomobject]@{ dir = $dir; file = $f; name = $name; description = $desc; hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash; flow = (Test-Path -LiteralPath (Join-Path $dir '.flow-skill')) }
}

function Check-Skills {
    $out = @(); $all = @()
    foreach ($root in @(Skill-Dirs)) { foreach ($d in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) { $s = Read-Skill $d.FullName; if ($s) { $s | Add-Member -NotePropertyName root -NotePropertyValue $root -Force; $all += $s } } }
    foreach ($s in $all) {
        if (-not $s.name -or -not $s.description) { $out += Finding 'skill-incomplet' 'moyenne' "Skill sans nom ou sans description : $(Split-Path $s.dir -Leaf)" 'Claude choisit un skill d''après sa description : sans elle il n''est jamais appelé' @([pscustomobject]@{ file = $s.file; line = 0; text = (Split-Path $s.dir -Leaf) }) "skill-inc|$($s.file)" @('o', 'i') }
    }
    foreach ($g in @($all | Where-Object { $_.name } | Group-Object name)) {
        $hashes = @($g.Group | Select-Object -ExpandProperty hash -Unique)
        if ($g.Count -gt 1 -and $hashes.Count -gt 1) { $out += Finding 'skill-double' 'moyenne' "Le skill « $($g.Name) » existe en $($g.Count) versions différentes" (@($g.Group | ForEach-Object { $_.file }) -join ' ; ') (@($g.Group | ForEach-Object { [pscustomobject]@{ file = $_.file; line = 0; text = $_.name } })) "skill-dbl|$($g.Name)|$($hashes -join ',')" @('o', 'i') }
    }
    $byRoot = $all | Where-Object { $_.name -and $_.description } | Group-Object root
    foreach ($r1 in $byRoot) {
        $arr = @($r1.Group)
        for ($i = 0; $i -lt $arr.Count; $i++) { for ($j = $i + 1; $j -lt $arr.Count; $j++) {
                if ($arr[$i].name -eq $arr[$j].name) { continue }
                $w1 = Words-Of (Norm-Text $arr[$i].description); $w2 = Words-Of (Norm-Text $arr[$j].description)
                if ($w1.Count -ge 8 -and (Jaccard $w1 $w2) -ge 0.6) { $out += Finding 'skill-chevauche' 'basse' "Deux skills aux descriptions très proches : $($arr[$i].name) et $($arr[$j].name)" 'Claude peut hésiter entre les deux ; fusionner ou préciser leurs descriptions' @($arr[$i], $arr[$j] | ForEach-Object { [pscustomobject]@{ file = $_.file; line = 0; text = $_.name } }) "skill-ovl|$($arr[$i].name)|$($arr[$j].name)" @('o', 'i') }
            } }
    }
    # skills livrés avec FLOW : copie obsolète par rapport au dossier skills\ de FLOW
    $flowHome = Split-Path $PSScriptRoot -Parent; $own = Join-Path $flowHome 'skills'
    foreach ($s in @($all | Where-Object { $_.flow })) {
        $src = Join-Path (Join-Path $own (Split-Path $s.dir -Leaf)) 'SKILL.md'
        if (Test-Path -LiteralPath $src) {
            $a = (Get-Content -LiteralPath $src -Raw -Encoding utf8).Replace('{{FLOW_ROOT}}', $flowHome).Trim(); $b2 = (Get-Content -LiteralPath $s.file -Raw -Encoding utf8).Trim()
            if ($a -ne $b2) { $out += Finding 'skill-obsolete' 'basse' "Skill de FLOW pas à jour : $($s.name)" 'sa copie dans le compte diffère de celle livrée avec FLOW' @([pscustomobject]@{ file = $s.file; line = 0; text = $s.name }) "skill-old|$($s.file)" @('x', 'o', 'i') }
        }
    }
    $out
}

function Check-Backlog {
    $out = @()
    $c = @(Read-Candidates)
    if ($c.Count -ge 40) { $out += Finding 'candidats' 'basse' "$($c.Count) candidats des hooks attendent un examen" 'le scribe les lit à la fin de chaque équipe ; une équipe de plus les consommera' @([pscustomobject]@{ file = '.flow\candidats\candidats.jsonl'; line = 0; text = "$($c.Count)" }) "cand|$([int]($c.Count / 40))" @('o', 'i') }
    $cf = Join-Path $RepoRoot 'memoire\conflits.md'
    if (Test-Path -LiteralPath $cf) {
        $n = 0
        foreach ($ln in @(Get-Content -LiteralPath $cf -Encoding utf8)) {
            $n++
            if ($ln -match '^\s*-\s+(?!\(aucun)(.{20,})$') { $out += Finding 'conflit' 'haute' 'Le scribe a trouvé deux informations qui se contredisent' $Matches[1].Trim() @([pscustomobject]@{ file = 'memoire\conflits.md'; line = $n; text = $ln.Trim() }) "conf|$($Matches[1].Trim())" @('r', 'o', 'i') }
        }
    }
    $out
}

function Scan-Project {
    # tous les contrôles mécaniques ; les points déjà ignorés n'apparaissent plus ; triés par gravité
    param([switch]$IncludeIgnored)
    $stmts = @(All-Statements)
    $f = @()
    $f += Check-DeadRefs $stmts
    $f += Check-Duplicates $stmts
    $f += Check-Index
    $f += Check-Freshness
    $f += Check-Consistency
    $f += Check-Skills
    $f += Check-Backlog
    $ign = @(Tri-Ignored)
    $rank = @{ haute = 0; moyenne = 1; basse = 2 }
    @($f | Where-Object { $_ -and ($IncludeIgnored -or $_.id -notin $ign) } | Sort-Object { $rank[$_.gravite] }, type)
}

# ───────────────────────── contradictions : Claude ─────────────────────────
function Contradictions-Prompt($stmts) {
    $lines = @($stmts | ForEach-Object { "S$($_.sid) [$($_.file)] $($_.text.Substring(0, [Math]::Min(240, $_.text.Length)))" })
    @"
Tu cherches les CONTRADICTIONS dans la mémoire et les règles d'un projet. Voici des affirmations numérotées (S1, S2…), chacune avec son fichier d'origine.
Ne signale que les VRAIES contradictions : deux affirmations qui ne peuvent pas être vraies en même temps (une décision et son contraire, deux valeurs
différentes pour la même chose, une règle et un fait qui la rend caduque). Pas les simples redites, pas les nuances, pas les sujets différents.
Pour chaque paire : les deux numéros, pourquoi elles se contredisent (une phrase), et la gravité (« haute » si Claude risque d'agir à l'envers).
N'invente aucun numéro et ne reformule pas les affirmations. S'il n'y en a pas, renvoie une liste vide.
$($lines -join "`n")
Réponds UNIQUEMENT avec un objet JSON : { "contradictions": [ { "a": "S12", "b": "S40", "pourquoi": "…", "gravite": "haute" } ] }
"@
}

function Find-Contradictions {
    # un appel (sonnet, sans accès aux fichiers) sur les affirmations du projet ; renvoie des constats, ou $null si annulé / illisible
    $stmts = @(All-Statements | Select-Object -First 250)
    if ($stmts.Count -lt 2) { return @() }
    $i = 0; foreach ($s in $stmts) { $i++; $s | Add-Member -NotePropertyName sid -NotePropertyValue $i -Force }
    $acct = Least-Loaded
    $work = Tri-Dir; New-Item -ItemType Directory -Force $work | Out-Null
    $pf = Join-Path $work 'contradictions.prompt.md'
    Set-Content -LiteralPath $pf (Contradictions-Prompt $stmts) -Encoding utf8
    $job = Start-ClaudeJob $RepoRoot $acct $pf 'sonnet' 'Read' $work
    $res = Wait-Job-Spinner $job "Claude cherche les contradictions entre $($stmts.Count) affirmations (sonnet, $($acct.Label))…"
    if ($null -eq $res) { return $null }
    Log-Call 'tri-contradictions' $acct 'sonnet' $res
    $j = Parse-ClaudeJson "$($res.Out)"
    if ($null -eq $j) { return $null }
    $byId = @{}; foreach ($s in $stmts) { $byId["S$($s.sid)"] = $s }
    $out = @()
    foreach ($c in @($j.contradictions)) {
        $a = $byId["$($c.a)".Trim().ToUpper()]; $b2 = $byId["$($c.b)".Trim().ToUpper()]
        if (-not $a -or -not $b2 -or $a -eq $b2) { continue }                          # un numéro inventé : le constat est écarté
        $pair = @($a, $b2) | Sort-Object prio, file, line
        $g = if ("$($c.gravite)".ToLower() -eq 'haute') { 'haute' } else { 'moyenne' }
        $out += Finding 'contradiction' $g "Contradiction : $($pair[0].file) et $($pair[1].file)" "$($c.pourquoi)" $pair "contra|$((Norm-Text $pair[0].text))|$((Norm-Text $pair[1].text))" @('1', '2', 'o', 'i')
    }
    $ign = @(Tri-Ignored)
    @($out | Where-Object { $_.id -notin $ign })
}

# ───────────────────────── appliquer, archiver ─────────────────────────
function Tri-Archive([string]$path) {
    # copie le fichier dans .flow\tri\archives\<date>\ avant de le modifier ; renvoie le chemin de la copie
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $rel = if ($path.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) { $path.Substring($RepoRoot.TrimEnd('\').Length + 1) } else { Split-Path $path -Leaf }
    $dest = Join-Path (Join-Path (Join-Path (Tri-Dir) 'archives') $stamp) $rel
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Copy-Item -LiteralPath $path -Destination $dest -Force
    $dest
}

function Remove-SourceLine($src) {
    # retire la ligne d'une source (retrouvée par son texte, même si elle a bougé), après archivage du fichier ; $false si elle n'est plus là
    $path = if ([IO.Path]::IsPathRooted($src.file)) { $src.file } else { Join-Path $RepoRoot $src.file }
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $raw = [IO.File]::ReadAllText($path); $crlf = $raw.Contains("`r`n")
    $lines = @($raw.Replace("`r`n", "`n") -split "`n")
    $want = "$($src.text)".Trim()
    $idx = -1
    if ($src.line -ge 1 -and $src.line -le $lines.Count -and $lines[$src.line - 1].Contains($want)) { $idx = $src.line - 1 }
    else { for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Contains($want)) { $idx = $i; break } } }
    if ($idx -lt 0) { return $false }
    [void](Tri-Archive $path)
    $new = @($lines | Select-Object -First $idx) + @($lines | Select-Object -Skip ($idx + 1))
    $txt = $new -join "`n"; if ($crlf) { $txt = $txt.Replace("`n", "`r`n") }
    Write-TextAtomic -Path $path -Text $txt
    Tri-Journal "ligne retirée de $($src.file):$($src.line) : $($want.Substring(0, [Math]::Min(90, $want.Length)))"
    $true
}

function Needs-Confirm($src) { $src.file -match '(^|[\\/])(CAHIER\.md|CLAUDE\.md)$' }

function Apply-Finding {
    # applique l'action choisie ; renvoie un message. Ne modifie JAMAIS sans que l'appelant ait obtenu la validation de l'utilisateur.
    param($Finding, [string]$Key)
    $k = $Key.ToLower()
    if ($k -eq 'i') { Add-Ignored $Finding.id; Tri-Journal "ignoré : $($Finding.titre)"; return "$Dm ignoré : ne reviendra plus$R" }
    if ($k -eq 'o') {
        foreach ($s in @($Finding.sources | Select-Object -First 3)) { $p = if ([IO.Path]::IsPathRooted($s.file)) { $s.file } else { Join-Path $RepoRoot $s.file }; if (Test-Path -LiteralPath $p) { Start-Process notepad.exe -ArgumentList "`"$p`"" } }
        return "$Dm fichier(s) ouvert(s) dans le Bloc-notes$R"
    }
    if ($k -match '^[1-4]$') {
        $keep = [int]$k - 1; $src = @($Finding.sources)
        if ($keep -ge $src.Count) { return "$Warn pas de source n°$k$R" }
        $drop = @($src | Where-Object { $_ -ne $src[$keep] })
        $n = 0
        foreach ($d in $drop) { if (Remove-SourceLine $d) { $n++ } }
        return "$Ok✓ gardé : $($src[$keep].file) · $n ligne(s) retirée(s) des autres sources (copies dans .flow\tri\archives\)$R"
    }
    if ($k -eq 'd') {
        $n = 0; foreach ($d in @($Finding.sources | Select-Object -First 1)) { if (Remove-SourceLine $d) { $n++ } }
        return $(if ($n) { "$Ok✓ ligne retirée (copie dans .flow\tri\archives\)$R" } else { "$Warn la ligne n'a pas été retrouvée$R" })
    }
    if ($k -eq 'r') {
        $n = 0; foreach ($d in @($Finding.sources | Select-Object -First 1)) { if (Remove-SourceLine $d) { $n++ } }
        return $(if ($n) { "$Ok✓ conflit marqué résolu (retiré de conflits.md, copie dans .flow\tri\archives\)$R" } else { "$Warn l'entrée n'a pas été retrouvée$R" })
    }
    if ($k -eq 'x') {
        switch ($Finding.type) {
            'index-manquant' {
                $idx = Join-Path $RepoRoot 'memoire\INDEX.md'; [void](Tri-Archive $idx)
                $name = $Finding.sources[0].text
                $row = "| [$name]($name) | (à décrire) | (mots-clés) |"
                $txt = Get-Content -LiteralPath $idx -Raw -Encoding utf8
                $m = [regex]::Match($txt, '(?ms)^\|[^\n]*\n\|[-| ]+\|\n((?:\|[^\n]*\n?)*)')
                $new = if ($m.Success) { $txt.Insert($m.Index + $m.Length, ($(if (-not $m.Value.EndsWith("`n")) { "`n" } else { '' }) + $row + "`n")) } else { $txt.TrimEnd() + "`n`n$row`n" }
                Write-TextAtomic -Path $idx -Text $new
                Tri-Journal "INDEX : $name ajouté"
                return "$Ok✓ $name ajouté à l'INDEX (à décrire à la main : O)$R"
            }
            'incoherence' {
                $add = @(@($Finding.sources[0].text -split ',\s*') | Where-Object { $_ })
                $Cfg | Add-Member -NotePropertyName protectedPaths -NotePropertyValue @(@($Cfg.protectedPaths) + $add | Where-Object { $_ } | Select-Object -Unique) -Force
                Save-ProjectConfig; [void](Sync-Hooks)
                Tri-Journal "profil aligné sur le cahier : $($add -join ', ')"
                return "$Ok✓ données protégées ajoutées au profil du projet : $($add -join ', ')$R"
            }
            'skill-obsolete' {
                $dst = $Finding.sources[0].file; $flowHome = Split-Path $PSScriptRoot -Parent
                $src = Join-Path (Join-Path $flowHome 'skills') (Join-Path (Split-Path (Split-Path $dst -Parent) -Leaf) 'SKILL.md')
                if (-not (Test-Path -LiteralPath $src)) { return "$Err✗ le skill livré avec FLOW est introuvable$R" }
                Tri-Archive $dst | Out-Null
                [IO.File]::WriteAllText($dst, (Get-Content -LiteralPath $src -Raw -Encoding utf8).Replace('{{FLOW_ROOT}}', $flowHome), [Text.UTF8Encoding]::new($false))
                Tri-Journal "skill remis à jour : $dst"
                return "$Ok✓ skill de FLOW remis à jour (ancienne copie archivée)$R"
            }
        }
        return "$Warn pas d'action automatique pour ce point : O pour ouvrir$R"
    }
    "$Warn touche inconnue$R"
}

# ───────────────────────── proposer le tri ─────────────────────────
function Tri-Offer-Due {
    # le tri est proposé quand un signal le justifie, au plus une fois par session, et pas plus d'une fois par semaine si l'utilisateur dit « plus tard »
    if (-not $RepoRoot -or $global:FlowTriOffered -or $global:FlowNoAi) { return $null }
    $st = Tri-State
    if ($st.declined -eq $true) { return $null }
    if ($st.snoozeUntil) { try { if ([datetime]$st.snoozeUntil -gt (Get-Date)) { return $null } } catch {} }
    $has = (Test-Path -LiteralPath (Join-Path $RepoRoot 'memoire')) -or (Wf-Exists) -or (Test-Path -LiteralPath (Join-Path $RepoRoot 'CLAUDE.md'))
    if (-not $has) { return $null }
    $f = @(Scan-Project)
    $hot = @($f | Where-Object { $_.gravite -eq 'haute' })
    $why = @()
    if ($hot.Count) { $why += "$($hot.Count) point(s) grave(s) (contradiction, incohérence)" }
    if ($f.Count -ge 5) { $why += "$($f.Count) points à examiner" }
    if ([int]$st.deliveries -ge 8) { $why += "$($st.deliveries) équipes livrées depuis le dernier tri" }
    if (-not $why.Count) { return $null }
    [pscustomobject]@{ Findings = $f; Why = ($why -join ' · ') }
}

function Mode-Tri {
    # l'écran du tri : les points à examiner, leurs sources, les actions ; rien ne change sans une touche de ta part
    param($Initial = $null)
    $items = if ($Initial) { @($Initial) } else { @(Scan-Project) }
    $sel = 0; $msg = ''
    Cls
    while ($true) {
        $W = [Math]::Max(40, (ConW) - 1)
        $L = [Collections.Generic.List[string]]::new()
        $L.Add(''); $L.Add("  $(Grad '⚑ TRI — garder le projet sain' 0.1)   $B$(Split-Path $RepoRoot -Leaf)$R")
        if (-not $items.Count) {
            $L.Add("  $Ok✓ Rien à trier : pas de référence morte, de doublon, de contradiction ni d'incohérence repérés.$R")
            $L.Add(''); $L.Add((Keys @('C', 'chercher les contradictions avec Claude', 'R', 'revérifier', 'Échap', 'retour')))
        } else {
            if ($sel -ge $items.Count) { $sel = $items.Count - 1 }
            $L.Add((Now "$($items.Count) point(s) à examiner. Choisis-en un avec ↑↓ puis une action : rien ne change sans ta touche"))
            $L.Add('')
            $rows = @()
            for ($i = 0; $i -lt [Math]::Min($items.Count, 12); $i++) {
                $it = $items[$i]; $mark = if ($i -eq $sel) { "$(PalC 0.1)$B▸$R" } else { ' ' }
                $gc = switch ($it.gravite) { 'haute' { $Err } 'moyenne' { $Warn } default { $Dm } }
                $rows += @{ Y = $L.Count; Row = $i }
                $L.Add("  $mark $gc●$R $(Fit $it.titre ($W - 8))")
            }
            if ($items.Count -gt 12) { $L.Add("    $Dm… et $($items.Count - 12) autre(s) (traite les premiers, la liste se met à jour)$R") }
            $cur = $items[$sel]
            $L.Add(''); $L.Add("  $B$($cur.titre)$R")
            foreach ($x in @(Chunks "$($cur.detail)" ($W - 8)) | Select-Object -First 3) { $L.Add("    $Dm$x$R") }
            $n = 0
            foreach ($s in @($cur.sources | Select-Object -First 4)) { $n++; $q = "$($s.text)" -replace '\s+', ' '; $L.Add("    $Teal$n$R  $Dm$($s.file)$(if ($s.line) { ":$($s.line)" })$R  $(Fit $q ($W - 24))") }
            $act = @()
            foreach ($a in @($cur.actions)) {
                switch -regex ($a) {
                    '^[1-4]$' { if ([int]$a -le @($cur.sources).Count) { $act += @($a, "garder $a (retirer les autres)") } }
                    '^d$' { $act += @('D', 'retirer la ligne') }
                    '^r$' { $act += @('R', 'marquer résolu') }
                    '^x$' { $act += @('X', $(switch ($cur.type) { 'index-manquant' { 'ajouter à l''INDEX' } 'incoherence' { 'aligner le profil' } 'skill-obsolete' { 'réinstaller' } default { 'corriger' } })) }
                    '^o$' { $act += @('O', 'ouvrir') }
                    '^i$' { $act += @('I', 'ignorer') }
                }
            }
            $L.Add(''); $L.Add((Keys ($act + @('C', 'contradictions (Claude)', 'M', 'doublons exacts en lot', 'Échap', 'retour'))))
            if ($cur.type -in 'contradiction', 'conflit') { $L.Add("  $Dm Règle conseillée : ce qui est dans CAHIER.md (écrit avec toi) l'emporte sur une déduction ; à défaut, le plus récent. Rien n'est tranché sans toi.$R") }
        }
        if ($msg) { $L.Add("  $msg") }
        Show-Frame $L
        if ($items.Count) { foreach ($rw in $rows) { Add-Zone $rw.Y $rw.Y 0 999 @{ Row = $rw.Row } } }
        $a2 = Read-Action -Wait
        if ($a2.Click) { $sel = $a2.Click.Row; $msg = ''; continue }
        $k = $a2.K; if (-not $k) { continue }
        $ch = "$($k.KeyChar)".ToLower()
        if ($k.Key -eq 'Escape') { $s2 = Tri-State; $s2.last = (Get-Date).ToString('o'); $s2.deliveries = 0; Save-TriState $s2; return 'quit' }
        elseif ($k.Key -eq 'UpArrow' -and $items.Count) { $sel = ($sel - 1 + $items.Count) % $items.Count; $msg = '' }
        elseif ($k.Key -eq 'DownArrow' -and $items.Count) { $sel = ($sel + 1) % $items.Count; $msg = '' }
        elseif ($ch -eq 'r' -and (-not $items.Count -or $items[$sel].actions -notcontains 'r')) { $items = @(Scan-Project); $sel = 0; $msg = "$Ok✓ revérifié$R" }
        elseif ($ch -eq 'c') {
            $found = Find-Contradictions
            Cls
            if ($null -eq $found) { $msg = "$Err✗ la recherche n'a pas abouti (annulée ou réponse illisible)$R" }
            else { $items = @($found) + @($items | Where-Object { $_.type -ne 'contradiction' }); $sel = 0; $msg = "$Ok✓ $($found.Count) contradiction(s) trouvée(s)$R" }
        }
        elseif ($ch -eq 'm') {
            $dups = @($items | Where-Object { $_.type -eq 'doublon' })
            if (-not $dups.Count) { $msg = "$Dm aucun doublon exact à traiter$R"; continue }
            $kk = Message-Screen '⚑ TRI — doublons exacts' @("$($dups.Count) affirmation(s) écrite(s) plusieurs fois : la première (cahier, puis CLAUDE.md, puis mémoire) est gardée, les autres sont retirées.", "$Ok Chaque fichier modifié est d'abord copié dans .flow\tri\archives\.$R") @('O', 'appliquer', 'Échap', 'annuler')
            Cls
            if ("$($kk.KeyChar)".ToLower() -eq 'o') { $n = 0; foreach ($d1 in $dups) { $drop = @($d1.sources | Select-Object -Skip 1); foreach ($d2 in $drop) { if ((-not (Needs-Confirm $d2)) -and (Remove-SourceLine $d2)) { $n++ } } }; $items = @(Scan-Project); $sel = 0; $msg = "$Ok✓ $n ligne(s) retirée(s)$R" }
        }
        elseif ($items.Count -and $ch -match '^[1-4dxroi]$') {
            $cur = $items[$sel]
            if ($cur.actions -notcontains $ch) { $msg = "$Dm action indisponible pour ce point$R"; continue }
            if ($ch -match '^[1-4d]$' -or $ch -eq 'r') {
                $keep = if ($ch -match '^[1-4]$') { [int]$ch - 1 } else { -1 }
                $touch = @($cur.sources | Where-Object { $keep -lt 0 -or $_ -ne @($cur.sources)[$keep] } | Select-Object -First $(if ($ch -match '^[1-4]$') { 4 } else { 1 }))
                if (@($touch | Where-Object { Needs-Confirm $_ }).Count) {
                    $kc = Message-Screen '⚑ TRI — modifier un fichier de règles ?' @("Cette action retire une ligne de $(@($touch | Where-Object { Needs-Confirm $_ } | ForEach-Object { $_.file } | Select-Object -Unique) -join ', ') : des règles écrites avec toi.", "$Ok Une copie est gardée dans .flow\tri\archives\.$R") @('O', 'appliquer', 'Échap', 'annuler')
                    Cls
                    if ("$($kc.KeyChar)".ToLower() -ne 'o') { continue }
                }
            }
            $msg = Apply-Finding $cur $ch
            if ($ch -ne 'o') { $items = @($items | Where-Object { $_.id -ne $cur.id }); Write-Event 'tri' @{ type = $cur.type; action = $ch } }
        }
    }
}
