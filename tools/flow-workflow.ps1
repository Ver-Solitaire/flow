# flow-workflow.ps1 - le WORKFLOW d'un projet : un cahier, une feuille de route d'étapes, des règles (chargé avec « . » par flow-team.ps1).
#
# Inspiré du workflow d'un gros projet (STEPS.md, PROMPT-MAITRE.md, spec par étape) : pour chaque projet, FLOW crée avec l'utilisateur
#   .flow\workflow\CAHIER.md     vision, règles décidées, interdits, données à protéger, critère de réussite (fait foi pour tous les Claude)
#   .flow\workflow\ROADMAP.md    les étapes du projet et leur état (tableau Markdown lisible ET lu par FLOW)
#   .flow\workflow\workflow.json version, date, « validé » (tant que ce n'est pas validé, rien n'est transmis aux Claude)
#   .flow\workflow\archives\     les versions remplacées (rien n'est perdu)
# Les commandes de vérification, les chemins protégés et les garde-fous restent dans .flow\config.json (une seule source) :
# la création les y inscrit, le cahier les affiche. Les deux dossiers .flow\workflow\ et .flow\config.json peuvent être commités.

$WfStates = @('à faire', 'conception', 'en cours', 'fait', 'bloquée')
$WfPasses = @('légère', 'complète')

function Wf-Dir { Join-Path $RepoRoot '.flow\workflow' }
function Wf-File([string]$name) { Join-Path (Wf-Dir) $name }

function Wf-Meta {
    # workflow.json, ou $null
    if (-not $RepoRoot) { return $null }
    $f = Wf-File 'workflow.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop } catch { $null }
}
function Wf-Exists { [bool](Wf-Meta) }
function Wf-Validated { $m = Wf-Meta; [bool]($m -and $m.validated -eq $true) }

# ───────────────────────── la feuille de route : un tableau Markdown ─────────────────────────
function Wf-Cell([string]$s) { (("$s" -replace '\r?\n', ' ') -replace '\|', '\|').Trim() }
function Wf-Split([string]$line) {
    $t = $line.Trim()
    if ($t.StartsWith('|')) { $t = $t.Substring(1) }
    if ($t.EndsWith('|') -and -not $t.EndsWith('\|')) { $t = $t.Substring(0, $t.Length - 1) }
    @([regex]::Split($t, '(?<!\\)\|') | ForEach-Object { ($_ -replace '\\\|', '|').Trim() })
}

function ConvertFrom-Roadmap([string]$text) {
    # tableau → { Steps ; Errors } ; une ligne illisible est signalée, jamais ignorée en silence
    $steps = [Collections.Generic.List[object]]::new(); $errors = [Collections.Generic.List[string]]::new(); $seen = @{}
    $n = 0
    foreach ($ln in ("$text" -split "`r?`n")) {
        $n++
        if ($ln -notmatch '^\s*\|') { continue }
        $c = Wf-Split $ln
        if ($c.Count -ge 1 -and $c[0] -match '^(étape|etape|id)$') { continue }            # en-tête
        if ($c.Count -ge 1 -and $c[0] -match '^:?-{2,}:?$') { continue }                   # séparateur
        if ($c.Count -lt 6) { $errors.Add("ligne $n : 6 colonnes attendues (étape, titre, but, documents, passe, état), $($c.Count) trouvée(s)"); continue }
        $id = $c[0]
        if ($id -notmatch '^[A-Za-z0-9][\w\-]*$') { $errors.Add("ligne $n : identifiant d'étape invalide « $id »"); continue }
        if ($seen.ContainsKey($id.ToLower())) { $errors.Add("ligne $n : l'étape « $id » existe déjà"); continue }
        $seen[$id.ToLower()] = 1
        $state = $c[5].ToLower()
        if ($state -notin $WfStates) { $errors.Add("ligne $n : état « $($c[5]) » inconnu (attendu : $($WfStates -join ', '))"); $state = 'à faire' }
        $pass = $c[4].ToLower()
        if ($pass -notin $WfPasses) { if ($pass) { $errors.Add("ligne $n : passe « $($c[4]) » inconnue (attendu : $($WfPasses -join ', '))") }; $pass = 'complète' }
        $docs = @($c[3] -split '\s*,\s*' | Where-Object { $_ -and $_ -ne '-' })
        $steps.Add([pscustomobject][ordered]@{ id = $id; titre = $c[1]; but = $c[2]; documents = $docs; passe = $pass; etat = $state })
    }
    [pscustomobject]@{ Steps = @($steps); Errors = @($errors) }
}

function ConvertTo-Roadmap($steps, [string]$name) {
    $L = [Collections.Generic.List[string]]::new()
    $L.Add("# Feuille de route — $name"); $L.Add('')
    $L.Add("Mis à jour : $(Get-Date -Format 'dd/MM/yyyy') · tenue à jour par FLOW à chaque étape ; tu peux aussi la modifier à la main (une ligne = une étape).")
    $L.Add('')
    $L.Add('| Étape | Titre | But | Documents | Passe | État |')
    $L.Add('|---|---|---|---|---|---|')
    foreach ($s in @($steps)) {
        $docs = if (@($s.documents).Count) { (@($s.documents) | ForEach-Object { Wf-Cell $_ }) -join ', ' } else { '-' }
        $L.Add("| $(Wf-Cell $s.id) | $(Wf-Cell $s.titre) | $(Wf-Cell $s.but) | $docs | $(Wf-Cell $s.passe) | $(Wf-Cell $s.etat) |")
    }
    $L.Add('')
    $L.Add("États : $($WfStates -join ' · ') · Passes : $($WfPasses -join ' · ') (légère = relecture réduite, complète = relecture sur 5 angles, contre-vérification et juge)")
    ($L -join "`n") + "`n"
}

function Read-Roadmap {
    $f = Wf-File 'ROADMAP.md'
    if (-not (Test-Path -LiteralPath $f)) { return [pscustomobject]@{ Steps = @(); Errors = @('ROADMAP.md absent') } }
    ConvertFrom-Roadmap (Get-Content -LiteralPath $f -Raw -Encoding utf8)
}
function Write-Roadmap($steps, [switch]$Backup) {
    New-Item -ItemType Directory -Force (Wf-Dir) | Out-Null
    Write-TextAtomic -Path (Wf-File 'ROADMAP.md') -Text (ConvertTo-Roadmap $steps (Split-Path $RepoRoot -Leaf)) -Backup:$Backup
}
function Update-Step([string]$id, [scriptblock]$change) {
    # modifie une étape et réécrit le tableau. Refuse (et ne touche à rien) si ROADMAP.md contient une ligne que FLOW n'a pas pu relire :
    # la réécrire la ferait disparaître. La version précédente est gardée dans ROADMAP.md.bak.
    $road = Read-Roadmap
    if ($road.Errors.Count) { return $false }
    $s = @($road.Steps | Where-Object { $_.id -ieq $id })
    if (-not $s.Count) { return $false }
    & $change $s[0]
    Write-Roadmap $road.Steps -Backup
    $true
}
function Set-StepState([string]$id, [string]$state) {
    # change l'état d'une étape ; renvoie $false si l'étape ou l'état n'existe pas, ou si le tableau est à corriger
    if ($state -notin $WfStates) { return $false }
    $change = { param($st) $st.etat = $state }.GetNewClosure()
    Update-Step $id $change
}
function Set-StepPass([string]$id, [string]$pass) {
    if ($pass -notin $WfPasses) { return $false }
    $change = { param($st) $st.passe = $pass }.GetNewClosure()
    Update-Step $id $change
}
function Next-In([string[]]$list, [string]$cur) { $i = [array]::IndexOf($list, $cur); $list[($i + 1) % $list.Count] }
function Current-Step {
    # l'étape à poursuivre : en cours, sinon en conception, sinon la première à faire
    $st = @((Read-Roadmap).Steps)
    foreach ($e in 'en cours', 'conception', 'à faire') { $x = $st | Where-Object { $_.etat -eq $e } | Select-Object -First 1; if ($x) { return $x } }
    $null
}

# ───────────────────────── le cahier ─────────────────────────
function Wf-List($items, [string]$empty) {
    $a = @(@($items) | Where-Object { "$_".Trim() } | ForEach-Object { "- $("$_".Trim())" })
    if ($a.Count) { $a -join "`n" } else { $empty }
}

function ConvertTo-Cahier($c, [string]$name) {
    @(
        "# Cahier du projet — $name", '',
        "Mis à jour : $(Get-Date -Format 'dd/MM/yyyy') · écrit avec FLOW d'après tes réponses. **Il fait foi** pour tous les Claude du projet : ce qui y est décidé ne se remet pas en cause sans toi. Modifie-le à la main quand le projet change.", '',
        '## Vision', $(if ("$($c.vision)".Trim()) { "$($c.vision)".Trim() } else { '(à compléter)' }), '',
        '## Pour qui', $(if ("$($c.public)".Trim()) { "$($c.public)".Trim() } else { '(à compléter)' }), '',
        '## Règles décidées', (Wf-List $c.regles '- (aucune pour l''instant)'), '',
        '## Interdits', (Wf-List @(@($c.interdits) | ForEach-Object { Wf-Forbid $_ }) '- (aucun pour l''instant)'), '',
        '## Contraintes', (Wf-List $c.contraintes '- (aucune pour l''instant)'), '',
        '## Données à protéger', '(inscrites aussi dans `.flow\config.json`, réglage `protectedPaths` : c''est là qu''elles sont lues ; modifie-les depuis le profil du projet)',
        (Wf-List $c.donneesProtegees '- (aucune)'), '',
        '## Critère de réussite', $(if ("$($c.critere)".Trim()) { "$($c.critere)".Trim() } else { '(à compléter : un critère mesurable, par exemple « tous les tests passent et la page s''affiche sans erreur »)' }), '',
        '## Comment vérifier en vrai', (Wf-List $c.verification '- (à compléter)'), '',
        '## Questions ouvertes', (Wf-List $c.questionsOuvertes '- (aucune)'), ''
    ) -join "`n"
}

function Cahier-Block {
    # le cahier (et l'étape en cours), tel qu'il est transmis aux Claude ; vide tant que le workflow n'est pas validé
    if (-not $RepoRoot -or -not (Wf-Validated)) { return '' }
    $f = Wf-File 'CAHIER.md'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    $t = (Get-Content -LiteralPath $f -Raw -Encoding utf8).Trim()
    if ($t.Length -gt 3500) { $t = $t.Substring(0, 3500) + "`n(… cahier tronqué : lis $f)" }
    $cur = Current-Step
    $road = if ($cur) { "`nÉtape en cours de la feuille de route (.flow\workflow\ROADMAP.md) : $($cur.id) — $($cur.titre) (but : $($cur.but))." } else { '' }
    "`n## Cahier du projet (FAIT FOI : décisions de l'utilisateur, ne les remets pas en cause ; en cas de doute, demande)`n$t`n$road`n"
}

# ───────────────────────── création guidée ─────────────────────────
function Wf-Work { $d = Join-Path $RepoRoot '.flow\runs\_workflow'; New-Item -ItemType Directory -Force $d | Out-Null; $d }

function Wf-Study-Prompt([string]$extra) {
    $more = ''
    if ($extra) { $more = "`nPRÉCISION DE L'UTILISATEUR : $extra`n" }
    $more += (Profile-Block)
    @"
Tu aides l'utilisateur à créer le WORKFLOW de son projet : une méthode de travail écrite (un cahier de règles et une feuille de route
d'étapes) que toute une équipe de Claude suivra, y compris sur un GROS projet qui durera longtemps. Projet : $RepoRoot
$more
1. Explore le projet en lecture seule (Read, Grep, Glob) : README, CLAUDE.md, memoire\, structure, tests, CI, historique. Juste assez pour le comprendre.
2. Rends un résumé de ce que tu as compris (3 phrases : ce qu'est le projet, son état, sa taille) et son type en quelques mots.
3. Pose 6 à 8 questions, courtes et concrètes, SUR CE QUE LE CODE NE DIT PAS : l'objectif réel et pour qui ; à quoi on reconnaît que c'est réussi
   (mesurable) ; les grandes étapes envisagées et leur ordre ; les contraintes (technologies, compatibilité, délais) ; ce qu'il ne faut JAMAIS casser
   ou toucher (données réelles, production) ; comment vérifier en vrai (pas seulement les tests) ; les décisions déjà prises à ne pas remettre en cause.
   Chaque question a 2 à 4 réponses proposées (la plus recommandée EN PREMIER) et une phrase « why ». Ne demande jamais ce qui se lit dans le projet.

Réponds UNIQUEMENT avec un objet JSON valide, sans texte avant ni après :
{ "type": "…", "resume": "…", "questions": [ { "question": "…", "why": "…", "options": ["recommandée", "autre"] } ] }
"@
}

function Wf-Draft-Prompt([string]$study, [string]$answers, [string]$extra) {
    $more = ''
    if ($extra) { $more = "`nCORRECTION DEMANDÉE PAR L'UTILISATEUR (respecte-la) : $extra`n" }
    @"
Tu écris le WORKFLOW d'un projet (cahier + feuille de route) d'après ce que tu as compris et les réponses de l'utilisateur. Projet : $RepoRoot

CE QUE TU AS COMPRIS DU PROJET :
$study

RÉPONSES DE L'UTILISATEUR (elles font foi) :
$answers
$more
Relis au besoin le projet (lecture seule). Puis écris :
- "cahier" : "vision" (2-3 phrases), "public", "regles" (les règles de conception DÉJÀ DÉCIDÉES, à ne pas remettre en cause),
  "interdits" (chaque interdit commence par « Ne jamais » ou « Ne pas » : il sera lu comme un ordre par chaque Claude),
  "contraintes", "donneesProtegees" (chemins relatifs de données réelles à ne jamais modifier ; vide s'il n'y en a pas),
  "critere" (UN critère de réussite MESURABLE : « tous les tests passent », « la page s'affiche sans erreur », des chiffres…),
  "verification" (comment vérifier en vrai : commandes, scénarios, captures), "questionsOuvertes" (ce qui reste à décider) ;
- "etapes" : 3 à 10 étapes dans l'ordre logique, chacune LIVRABLE et vérifiable, { "id" ("E1", "E2"…), "titre" (court), "but" (une phrase),
  "documents" (fichiers ou dossiers à lire avant), "passe" ("légère" pour une petite étape sans risque, sinon "complète") }.
N'invente rien que l'utilisateur n'ait pas dit ou que le projet ne montre pas : ce qui manque va dans "questionsOuvertes". Français, concis.

Réponds UNIQUEMENT avec un objet JSON valide, sans texte avant ni après :
{ "cahier": { "vision": "", "public": "", "regles": [], "interdits": [], "contraintes": [], "donneesProtegees": [], "critere": "", "verification": [], "questionsOuvertes": [] },
  "etapes": [ { "id": "E1", "titre": "", "but": "", "documents": [], "passe": "complète" } ] }
"@
}

function Wf-Forbid([string]$s) {
    # un interdit doit se lire comme un interdit : sans « ne jamais » / « ne pas », on l'étiquette pour qu'il ne puisse pas être pris pour un ordre
    $t = "$s".Trim()
    if (-not $t) { return '' }
    if ($t -match "^(ne |n['’]|jamais|pas |aucun|interdit|à ne )") { return $t }
    "À ne jamais faire : $t"
}

function Convert-Draft($j) {
    # la réponse de Claude → données propres (identifiants uniques, passes et états valides) ; $null si inexploitable
    if (-not $j -or -not $j.cahier -or -not @($j.etapes).Count) { return $null }
    $steps = @(); $used = @{}; $i = 0
    foreach ($e in @($j.etapes | Select-Object -First 12)) {
        $i++
        $id = "$($e.id)".Trim(); if ($id -notmatch '^[A-Za-z0-9][\w\-]*$' -or $used.ContainsKey($id.ToLower())) { $id = "E$i"; while ($used.ContainsKey($id.ToLower())) { $id = "E$i-$([guid]::NewGuid().ToString('N').Substring(0, 2))" } }
        $used[$id.ToLower()] = 1
        if (-not "$($e.titre)".Trim()) { continue }
        $pass = "$($e.passe)".Trim().ToLower(); if ($pass -notin $WfPasses) { $pass = 'complète' }
        $steps += [pscustomobject][ordered]@{ id = $id; titre = "$($e.titre)".Trim(); but = "$($e.but)".Trim(); documents = @(@($e.documents) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() }); passe = $pass; etat = 'à faire' }
    }
    if (-not $steps.Count) { return $null }
    $c = $j.cahier
    $prot = @(@($c.donneesProtegees) | Where-Object { "$_".Trim() } | ForEach-Object { ("$_".Trim() -replace '\\', '/').TrimStart('/') } | Where-Object { $_ -notmatch '^\.\.|^[A-Za-z]:' })
    [pscustomobject]@{ Cahier = $c; Steps = $steps; Protected = $prot }
}

function Wf-Archive {
    # les fichiers actuels vont dans archives\<date> avant d'être remplacés
    $d = Wf-Dir
    $files = @('CAHIER.md', 'ROADMAP.md', 'workflow.json' | ForEach-Object { Wf-File $_ } | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $files.Count) { return $null }
    $dest = Join-Path $d "archives\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-Item -ItemType Directory -Force $dest | Out-Null
    foreach ($f in $files) { Copy-Item -LiteralPath $f -Destination $dest -Force }
    $dest
}

function Write-Workflow($draft, [bool]$validated = $false) {
    # écrit cahier, feuille de route et workflow.json ; inscrit les données protégées et les interdits dans le profil du projet
    $null = Wf-Archive
    New-Item -ItemType Directory -Force (Wf-Dir) | Out-Null
    $name = Split-Path $RepoRoot -Leaf
    Write-TextAtomic -Path (Wf-File 'CAHIER.md') -Text (ConvertTo-Cahier $draft.Cahier $name)
    Write-Roadmap $draft.Steps
    Save-WfMeta $validated
    if ($Cfg) {
        if (@($draft.Protected).Count) {
            $Cfg | Add-Member -NotePropertyName protectedPaths -NotePropertyValue @(@($Cfg.protectedPaths) + @($draft.Protected) | Where-Object { $_ } | Select-Object -Unique) -Force
        }
        $ban = @(@($draft.Cahier.interdits) | ForEach-Object { Wf-Forbid $_ } | Where-Object { $_ })
        if ($ban.Count) { $Cfg | Add-Member -NotePropertyName guardrails -NotePropertyValue @(@($Cfg.guardrails) + $ban | Where-Object { $_ } | Select-Object -Unique) -Force }
        Save-ProjectConfig
    }
}

function Save-WfMeta([bool]$validated) {
    $old = Wf-Meta
    $o = [ordered]@{ version = 1; created = $(if ($old -and $old.created) { $old.created } else { (Get-Date).ToString('o') }); validated = $validated }
    if ($validated) { $o['validatedAt'] = (Get-Date).ToString('o') }
    Write-JsonAtomic $o (Wf-File 'workflow.json')
}

function Show-WorkflowDraft([string]$msg) {
    # l'écran de validation : le cahier en résumé, la feuille de route ; Entrée / E / R / Échap
    $W = [Math]::Max(40, (ConW) - 1)
    $L = [Collections.Generic.List[string]]::new()
    $L.Add(''); $L.Add("  $(Grad '⚑ WORKFLOW — vérifie avant de valider' 0.1)   $B$(Split-Path $RepoRoot -Leaf)$R")
    $L.Add((Now 'lis le cahier et la feuille de route. Entrée = valider · E = modifier à la main · R = refaire avec une précision'))
    $L.Add('')
    $cahier = Get-Content -LiteralPath (Wf-File 'CAHIER.md') -Raw -Encoding utf8
    foreach ($sec in 'Vision', 'Critère de réussite') {
        $m = [regex]::Match($cahier, "(?s)## $sec\n(.*?)(?=\n## |\z)")
        if ($m.Success) { $L.Add("  $B$sec$R"); foreach ($x in @(Chunks $m.Groups[1].Value.Trim() ($W - 6)) | Select-Object -First 3) { $L.Add("    $Dm$x$R") } }
    }
    foreach ($sec in 'Règles décidées', 'Interdits', 'Données à protéger') {
        $m = [regex]::Match($cahier, "(?s)## $sec\n(.*?)(?=\n## |\z)")
        $n = if ($m.Success) { @($m.Groups[1].Value -split "`n" | Where-Object { $_ -match '^- ' -and $_ -notmatch '^- \(' }).Count } else { 0 }
        $L.Add("  $B$sec$R  $Dm$n point(s)$R")
    }
    $L.Add('')
    $road = Read-Roadmap
    $L.Add("  $B Feuille de route$R  $Dm$(@($road.Steps).Count) étape(s)$R")
    foreach ($st in $road.Steps) { $L.Add("    $Teal$($st.id)$R  $(Fit $st.titre ($W - 30))  $Dm$($st.passe)$R") }
    foreach ($er in $road.Errors) { $L.Add("  $Warn⚠ $er$R") }
    $L.Add('')
    $L.Add("  $Dm Fichiers : $(Wf-Dir)$R")
    $L.Add((Keys @('Entrée', 'valider', 'E', 'modifier', 'R', 'refaire', 'Échap', 'plus tard')))
    if ($msg) { $L.Add("  $msg") }
    Show-Frame $L
}

function Invoke-WorkflowCreation {
    # étudie le projet, pose ses questions, écrit un brouillon, le fait valider. Renvoie un message pour l'écran appelant.
    param([switch]$Redo)
    $acct = Least-Loaded
    $work = Wf-Work
    $extra = ''
    # 1) étude et questions
    $pf = Join-Path $work 'etude.prompt.md'
    Set-Content -LiteralPath $pf (Wf-Study-Prompt '') -Encoding utf8
    $job = Start-ClaudeJob $RepoRoot $acct $pf 'opus' 'Read,Grep,Glob' $work
    $res = Wait-Job-Spinner $job "FLOW étudie ton projet ($($acct.Label), opus) pour préparer ses questions…"
    if ($null -eq $res) { return "$Dm création du workflow annulée$R" }
    Log-Call 'workflow-etude' $acct 'opus' $res
    $study = Parse-ClaudeJson "$($res.Out)"
    if (-not $study) { return "$Err✗ l'étude du projet n'a pas abouti (réponse illisible) : réessaie avec W$R" }
    $qs = @(Valid-Questions $study.questions)
    $answers = ''
    if ($qs.Count) {
        $ans = Ask-Questions $qs '⚑ WORKFLOW — comprenons ton projet' "$($study.type) — $($study.resume)"
        if ($null -eq $ans) { return "$Dm création du workflow annulée (aucun fichier écrit)$R" }
        Log-Answers $qs $ans 'workflow'
        $answers = Format-Answers $qs $ans
    }
    $studyText = "Type : $($study.type)`n$($study.resume)"
    # 2) brouillon, puis validation (autant de fois que l'utilisateur le demande)
    while ($true) {
        $df = Join-Path $work 'brouillon.prompt.md'
        Set-Content -LiteralPath $df (Wf-Draft-Prompt $studyText $answers $extra) -Encoding utf8
        $job = Start-ClaudeJob $RepoRoot $acct $df 'opus' 'Read,Grep,Glob' $work
        $res = Wait-Job-Spinner $job "FLOW écrit le cahier et la feuille de route ($($acct.Label), opus)…"
        if ($null -eq $res) { return "$Dm création du workflow annulée$R" }
        Log-Call 'workflow-brouillon' $acct 'opus' $res
        $draft = Convert-Draft (Parse-ClaudeJson "$($res.Out)")
        if (-not $draft) { return "$Err✗ le brouillon du workflow est inexploitable : réessaie avec W (sortie : $work)$R" }
        Write-Workflow $draft $false
        $note = ''
        while ($true) {
            Show-WorkflowDraft $note
            $k = Read-KeyOrHint; $ch = "$($k.KeyChar)".ToLower()
            if ($k.Key -eq 'Enter') {
                Save-WfMeta $true
                Write-Event 'workflow_cree' @{ etapes = @($draft.Steps).Count; protege = @($draft.Protected).Count; refait = [bool]$Redo }
                return "$Ok✓ workflow validé : $(Wf-Dir) — à commiter pour le partager avec le projet$R"
            }
            elseif ($k.Key -eq 'Escape') { return "$Warn workflow gardé en brouillon (non validé, donc pas encore transmis aux Claude) : W pour le reprendre$R" }
            elseif ($ch -eq 'e') {
                foreach ($fn in 'CAHIER.md', 'ROADMAP.md') { Start-Process notepad.exe -ArgumentList "`"$(Wf-File $fn)`"" -Wait }
                $note = if ((Read-Roadmap).Errors.Count) { "$Warn la feuille de route a des lignes à corriger (E pour les rouvrir)$R" } else { "$Ok✓ fichiers relus$R" }
                Cls
            }
            elseif ($ch -eq 'r') {
                $extra = Read-Line '⚑ WORKFLOW — refaire' 'Qu''est-ce qui ne va pas ? (étapes, règles, critère…)'
                Cls
                if ($extra) { break }
            }
        }
    }
}

function Workflow-Offer-Due {
    # proposer la création : projet sans workflow, pas refusé, pas déjà proposé dans cette session
    [bool]($RepoRoot -and -not (Wf-Exists) -and -not ($Cfg -and $Cfg.workflowDeclined -eq $true) -and -not $global:FlowWfOffered -and -not $global:FlowNoAi)
}

# ───────────────────────── la feuille de route vivante ─────────────────────────
function Roadmap-Active { [bool]($RepoRoot -and (Wf-Validated) -and @((Read-Roadmap).Steps).Count) }

function Wf-Journal([string]$text) {
    # journal daté du projet : une ligne par événement important (étape lancée, livrée, terminée…) ; ne gêne jamais l'équipe
    if (-not (Wf-Validated)) { return }
    try { Add-Content -LiteralPath (Wf-File 'journal.md') -Value "- $(Get-Date -Format 'dd/MM/yyyy HH:mm') — $(("$text" -replace '\s+', ' ').Trim())" -Encoding utf8 } catch {}
}

function Roadmap-Summary {
    # « 3/7 étapes faites · en cours : E4 Titre » ; $null sans feuille de route
    if (-not (Roadmap-Active)) { return $null }
    $steps = @((Read-Roadmap).Steps)
    $done = @($steps | Where-Object { $_.etat -eq 'fait' }).Count
    $cur = Current-Step
    "$done/$($steps.Count) étapes faites$(if ($cur) { " · à poursuivre : $($cur.id) $($cur.titre)" } else { ' · tout est fait' })"
}

function Roadmap-Prompt-Block {
    # pour le planificateur : la feuille de route, pour qu'il rattache la demande à une étape
    if (-not (Roadmap-Active)) { return '' }
    $lines = @((Read-Roadmap).Steps | ForEach-Object { "- $($_.id) [$($_.etat)] $($_.titre) : $($_.but)" })
    "`n## Feuille de route du projet (.flow\workflow\ROADMAP.md)`n$($lines -join "`n")`nSi la demande de l'utilisateur correspond à UNE de ces étapes, donne son identifiant dans `"etape`" ; sinon laisse-le vide. N'invente aucune étape.`n"
}

function Valid-StepId([string]$id) {
    if (-not "$id".Trim() -or -not (Roadmap-Active)) { return '' }
    $s = @((Read-Roadmap).Steps | Where-Object { $_.id -ieq "$id".Trim() })
    if ($s.Count) { $s[0].id } else { '' }
}

function Step-Choices { @('') + @((Read-Roadmap).Steps | ForEach-Object { $_.id }) }

function Step-Begin {
    # le plan est validé : l'étape liée passe « en cours » (l'état d'avant est gardé pour pouvoir revenir en arrière)
    if (-not $State -or -not "$($State.step)".Trim()) { return }
    $id = "$($State.step)"
    $road = Read-Roadmap
    $s = @($road.Steps | Where-Object { $_.id -ieq $id })
    if (-not $s.Count -or $road.Errors.Count) { return }
    $State | Add-Member -NotePropertyName stepPrev -NotePropertyValue $s[0].etat -Force
    if ($s[0].etat -in 'à faire', 'conception', 'bloquée') {
        if (Set-StepState $id 'en cours') { $State | Add-Member -NotePropertyName stepStarted -NotePropertyValue $true -Force }
    }
    Wf-Journal "$id — équipe $($State.id) lancée : $($State.summary)"
}

function Step-Revert([string]$why) {
    # l'équipe est abandonnée ou jetée : l'étape retrouve son état d'avant, si c'est encore elle qui l'a fait passer « en cours »
    if (-not $State -or -not "$($State.step)".Trim()) { return }
    $id = "$($State.step)"
    $s = @((Read-Roadmap).Steps | Where-Object { $_.id -ieq $id })
    if ($s.Count -and $State.stepStarted -eq $true -and $s[0].etat -eq 'en cours' -and "$($State.stepPrev)") { [void](Set-StepState $id "$($State.stepPrev)") }
    Wf-Journal "$id — équipe $($State.id) $why : $($State.summary)"
}

function Ask-StepDone {
    # après une livraison : l'étape est-elle terminée ? Réponse « oui » seulement par un choix explicite ; sinon elle reste en cours.
    if (-not $State -or -not "$($State.step)".Trim() -or -not (Roadmap-Active)) { return $null }
    $id = "$($State.step)"
    $s = @((Read-Roadmap).Steps | Where-Object { $_.id -ieq $id })
    if (-not $s.Count) { return $null }
    $k = Message-Screen '⚑ FEUILLE DE ROUTE — étape terminée ?' @("Cette équipe travaillait sur l'étape $B$($s[0].id)$R — $($s[0].titre).", "$Dm But : $($s[0].but)$R", '', 'Après cette livraison, l''étape est-elle terminée ?') @('O', 'oui : l''étape est faite', 'Entrée', 'pas encore, elle reste en cours')
    if ("$($k.KeyChar)".ToLower() -eq 'o') {
        if (Set-StepState $id 'fait') { Wf-Journal "$id — terminée après la livraison de l'équipe $($State.id) : $($State.summary)"; return 'fait' }
        return $null
    }
    Wf-Journal "$id — livraison de l'équipe $($State.id) (l'étape reste en cours) : $($State.summary)"
    'en cours'
}

function Step-Icon([string]$etat) {
    switch ($etat) { 'fait' { "$Ok✓$R" } 'en cours' { "$Warn▶$R" } 'conception' { "$Info✎$R" } 'bloquée' { "$Err■$R" } default { "$Dm○$R" } }
}

function Mode-Roadmap {
    # l'avancement du projet : étapes, états, équipes en cours, journal ; S change l'état, P la passe, E modifie, J lit le journal
    $sel = 0; $msg = ''
    Cls
    while ($true) {
        $W = [Math]::Max(40, (ConW) - 1)
        $road = Read-Roadmap; $steps = @($road.Steps)
        if ($sel -ge $steps.Count) { $sel = [Math]::Max(0, $steps.Count - 1) }
        $L = [Collections.Generic.List[string]]::new()
        $L.Add(''); $L.Add("  $(Grad '⚑ FEUILLE DE ROUTE' 0.1)   $B$(Split-Path $RepoRoot -Leaf)$R")
        if (-not (Wf-Validated)) {
            $L.Add("  $Warn Pas de workflow validé pour ce projet : crée-le avec W dans le profil du projet (F2).$R")
            $L.Add(''); $L.Add((Keys @('Échap', 'retour')))
            Show-Frame $L; $k = Read-KeyOrHint
            if ($k.Key -eq 'Escape') { return 'quit' }
            continue
        }
        $done = @($steps | Where-Object { $_.etat -eq 'fait' }).Count
        $bar = if ($steps.Count) { $n = [int][Math]::Round(20 * $done / $steps.Count); "$Ok$('█' * $n)$R$Dm$('░' * (20 - $n))$R" } else { '' }
        $L.Add("  $bar  $B$done$R sur $($steps.Count) étape(s) faites")
        $L.Add($(if ($road.Errors.Count) { "  $Warn⚠ ROADMAP.md a $($road.Errors.Count) ligne(s) à corriger (E pour la modifier) : FLOW ne change rien tant que ce n'est pas réglé.$R" } else { (Now 'S change l''état de l''étape choisie · P sa passe · J lit le journal') }))
        $L.Add('')
        $teams = @(Open-Runs)
        $rows = @()
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $st = $steps[$i]
            $mark = if ($i -eq $sel) { "$(PalC 0.1)$B▸$R" } else { ' ' }
            $eq = @($teams | Where-Object { "$($_.step)" -ieq $st.id }).Count
            $rows += @{ Y = $L.Count; Row = $i }
            $L.Add("  $mark $(Step-Icon $st.etat) $B$($st.id)$R  $(Fit $st.titre ($W - 44))  $Dm$($st.passe)$R  $($st.etat)$(if ($eq) { "  $Info⚑ $eq équipe(s)$R" })")
        }
        if ($steps.Count) {
            $cur = $steps[$sel]
            $L.Add('')
            foreach ($x in @(Chunks "But : $($cur.but)" ($W - 8)) | Select-Object -First 3) { $L.Add("    $x") }
            if (@($cur.documents).Count) { $L.Add("    $Dm à lire : $(@($cur.documents) -join ', ')$R") }
            foreach ($tm in @($teams | Where-Object { "$($_.step)" -ieq $cur.id })) { $L.Add("    $Info⚑ équipe $($tm.id) · $($tm.status) · $(@($tm.tasks).Count) tâche(s) : $($tm.summary)$R") }
        }
        $jf = Wf-File 'journal.md'
        if (Test-Path -LiteralPath $jf) {
            $L.Add(''); $L.Add("  $B Journal$R $Dm(derniers événements)$R")
            foreach ($j in @(Get-Content -LiteralPath $jf -Encoding utf8 -Tail 5)) { $L.Add("    $Dm$(Fit $j ($W - 8))$R") }
        }
        $L.Add('')
        $L.Add((Keys @('↑↓', 'choisir', 'S', 'état suivant', 'P', 'passe', 'E', 'modifier', 'J', 'lire le journal', 'Échap', 'retour')))
        if ($msg) { $L.Add("  $msg") }
        Show-Frame $L
        foreach ($rw in $rows) { Add-Zone $rw.Y $rw.Y 0 999 @{ Row = $rw.Row } }
        $act = Read-Action -Wait
        if ($act.Click) { $sel = $act.Click.Row; $msg = ''; continue }
        $k = $act.K; if (-not $k) { continue }
        $ch = "$($k.KeyChar)".ToLower()
        if ($k.Key -eq 'Escape') { return 'quit' }
        elseif ($k.Key -eq 'UpArrow' -and $steps.Count) { $sel = ($sel - 1 + $steps.Count) % $steps.Count; $msg = '' }
        elseif ($k.Key -eq 'DownArrow' -and $steps.Count) { $sel = ($sel + 1) % $steps.Count; $msg = '' }
        elseif ($ch -eq 's' -and $steps.Count) {
            $to = Next-In $WfStates $steps[$sel].etat
            if (Set-StepState $steps[$sel].id $to) { Wf-Journal "$($steps[$sel].id) — état changé à la main : $($steps[$sel].etat) → $to"; Write-Event 'etape_etat' @{ etape = $steps[$sel].id; de = $steps[$sel].etat; vers = $to }; $msg = "$Ok✓ $($steps[$sel].id) : $to$R" }
            else { $msg = "$Err✗ ROADMAP.md est à corriger d'abord (E)$R" }
        }
        elseif ($ch -eq 'p' -and $steps.Count) {
            $to = Next-In $WfPasses $steps[$sel].passe
            $msg = if (Set-StepPass $steps[$sel].id $to) { "$Ok✓ $($steps[$sel].id) : passe $to$R" } else { "$Err✗ ROADMAP.md est à corriger d'abord (E)$R" }
        }
        elseif ($ch -eq 'e') { Start-Process notepad.exe -ArgumentList "`"$(Wf-File 'ROADMAP.md')`"" -Wait; $msg = "$Ok✓ feuille de route relue$R"; Cls }
        elseif ($ch -eq 'j') {
            if (Test-Path -LiteralPath $jf) { Open-TextWindow 'journal' @(Get-Content -LiteralPath $jf -Encoding utf8); $msg = "$Dm journal ouvert dans la fenêtre « journal » (q puis une touche pour la fermer)$R" } else { $msg = "$Dm pas encore de journal$R" }
        }
    }
}