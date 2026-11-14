# flow-steps.ps1 - conception et construction d'une ÉTAPE de la feuille de route (chargé avec « . » par flow-team.ps1).
#
# Inspiré des deux passes du workflow d'un gros projet :
#   CONCEPTION   (step-spec)  zones de code cartographiées EN PARALLÈLE (lecture seule, sur plusieurs comptes) → critique de complétude →
#                             spécification → relectures « fidélité au cahier » et « faisabilité » → spec finale ; les vraies décisions te sont posées.
#                             Une étape en passe LÉGÈRE saute la critique et les relectures : un seul appel.
#   CONSTRUCTION (step-build) l'équipe habituelle de FLOW (plan, ouvriers, relecture, intégration, juge), reliée à l'étape et à sa spec :
#                             la spec fait foi, ses lots deviennent les tâches, la passe de l'étape impose la passe de contrôle.
# Fichiers : .flow\workflow\etapes\<ÉTAPE>\spec.md (+ carte.md, spec.json) ; la spec est copiée dans le dossier de l'équipe (SPEC.md).
# Rien n'est construit sans que tu aies validé la spec. Les données protégées sont empreintes (SHA-256) avant l'équipe et recontrôlées à l'intégration.

function Step-Dir([string]$id) { Join-Path (Wf-Dir) "etapes\$id" }
function Spec-File([string]$id) { Join-Path (Step-Dir $id) 'spec.md' }
function Spec-MetaFile([string]$id) { Join-Path (Step-Dir $id) 'spec.json' }
function Spec-Validated([string]$id) {
    try { $m = Get-Content -LiteralPath (Spec-MetaFile $id) -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop; [bool]($m.validated -eq $true -and (Test-Path -LiteralPath (Spec-File $id))) } catch { $false }
}

# ───────────────────────── données protégées : empreintes avant / après ─────────────────────────
function Data-Files {
    # fichiers sous les chemins protégés du projet (dossier principal), avec un plafond pour rester rapide
    $out = [Collections.Generic.List[object]]::new(); $capped = $false
    foreach ($pt in @(@($Cfg.protectedPaths) | Where-Object { "$_".Trim() -and "$_" -notmatch '[\*\?\[]' })) {
        $p = Join-Path $RepoRoot (("$pt" -replace '/', '\').Trim().TrimEnd('\'))
        if (Test-Path -LiteralPath $p -PathType Leaf) { $out.Add((Get-Item -LiteralPath $p)) }
        elseif (Test-Path -LiteralPath $p -PathType Container) { foreach ($f in Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue) { if ($out.Count -ge 3000) { $capped = $true; break }; $out.Add($f) } }
    }
    [pscustomobject]@{ Files = @($out); Capped = $capped }
}

function Data-Manifest {
    $d = Data-Files; $map = [ordered]@{}; $total = 0L; $skipped = 0
    foreach ($f in $d.Files) {
        $total += $f.Length
        if ($total -gt 300MB) { $skipped++; continue }
        try { $map[$f.FullName.Substring($RepoRoot.TrimEnd('\').Length + 1).Replace('\', '/')] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } catch { $skipped++ }
    }
    [pscustomobject]@{ files = $map; skipped = $skipped; capped = $d.Capped }
}

function Write-DataManifest {
    # empreintes des données protégées au lancement de l'équipe
    if (-not $RunDir -or -not @(@($Cfg.protectedPaths) | Where-Object { "$_".Trim() }).Count) { return }
    try { Write-JsonAtomic (Data-Manifest) (Join-Path $RunDir 'donnees-avant.json') -Depth 4 } catch { Write-FlowLog "empreintes des données protégées impossibles : $($_.Exception.Message)" 'WARN' }
}

function Data-Check {
    # à l'intégration : les données protégées ont-elles changé depuis le lancement ? $null s'il n'y avait rien à comparer
    $f = if ($RunDir) { Join-Path $RunDir 'donnees-avant.json' } else { $null }
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { return $null }
    try { $before = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json } catch { return $null }
    $now = Data-Manifest
    $diff = @()
    $was = @{}; foreach ($pr in $before.files.PSObject.Properties) { $was[$pr.Name] = $pr.Value }
    foreach ($k in $was.Keys) { if (-not $now.files.Contains($k)) { $diff += "supprimé : $k" } elseif ($now.files[$k] -ne $was[$k]) { $diff += "modifié : $k" } }
    foreach ($k in $now.files.Keys) { if (-not $was.ContainsKey($k)) { $diff += "ajouté : $k" } }
    $note = @(); if ($before.capped -or $now.capped -or $before.skipped -or $now.skipped) { $note += '(contrôle partiel : trop de fichiers ou de données)' }
    [pscustomobject]@{ name = 'données protégées (contenu)'; cmd = 'empreintes SHA-256 avant / après'; ok = ($diff.Count -eq 0); ran = $true; tail = @(@($diff | Select-Object -First 8) + $note) }
}

# ───────────────────────── prompts de la conception ─────────────────────────
function Step-Common($step) {
    $docs = if (@($step.documents).Count) { @($step.documents) -join ', ' } else { '(aucun indiqué)' }
    @"
Projet : $RepoRoot
ÉTAPE $($step.id) — $($step.titre). But : $($step.but). Documents à lire d'abord : $docs.
$(Cahier-Block)$(Profile-Block)
Réponds en français, précis (fichiers, fonctions, formats), sans remplissage. Conception « plus petite modification qui règle COMPLÈTEMENT le besoin » :
réutilise l'existant ; pas d'abstraction ni d'option non demandée. LECTURE SEULE : ne modifie aucun fichier du projet.
"@
}

function Step-Zones-Prompt($step) {
    @"
$(Step-Common $step)
Ton rôle : découper la CARTOGRAPHIE du code nécessaire à cette étape en 3 à 6 zones indépendantes (par exemple : modules concernés, données et formats,
tests existants, configuration, ce que l'étape ne doit pas casser). Pour chaque zone : une clé courte et une consigne précise pour un lecteur
(ce qu'il doit trouver : emplacements exacts où brancher, formats, ce qui existe déjà et peut être réutilisé, pièges).
Réponds UNIQUEMENT avec un objet JSON : { "zones": [ { "key": "…", "consigne": "…" } ] }
"@
}

function Step-Reader-Prompt($step, $zone) {
    @"
$(Step-Common $step)
Zone à cartographier : $($zone.key).
$($zone.consigne)
Cite des fichiers et des fonctions RÉELS (vérifie-les). Ce que tu n'as pas trouvé, dis-le.
Réponds UNIQUEMENT avec un objet JSON : { "zone": "$($zone.key)", "constats": "ta cartographie en Markdown (liste, avec chemins:lignes)" }
"@
}

function Step-Critic-Prompt($step, [string]$maps) {
    @"
$(Step-Common $step)
Voici la CARTE du code produite par des lecteurs. Critique de complétude : ce qui MANQUE pour réaliser l'étape sans surprise, les contradictions entre lecteurs
(vérifie toi-même dans le code et donne la bonne réponse), les pièges oubliés, et les décisions de conception que ni le cahier ni le code ne tranchent.
$maps
Réponds UNIQUEMENT avec un objet JSON : { "manques": ["…"], "contradictions": ["…"], "pieges": ["…"], "decisions_ouvertes": [ { "point": "…", "options": ["recommandée", "autre"] } ] }
"@
}

$SpecSchema = @'
{ "resume": "ce que l'étape fait, en 3 phrases",
  "decisions": [ { "point": "…", "choix": "…" } ],
  "questions": [ { "question": "…", "why": "…", "options": ["recommandée", "autre"] } ],
  "emplacements": [ { "sujet": "…", "ou": "chemin exact", "constat": "…" } ],
  "lots": [ { "nom": "…", "fichiers": ["chemins"], "consigne": "ce que ce lot fait, précisément" } ],
  "tests": ["scénario précis avec la valeur attendue"],
  "verifications": ["comment vérifier en vrai : commandes, scénarios, captures"],
  "risques": ["…"] }
'@

function Step-Spec-Prompt($step, [string]$carte, [string]$critique, [bool]$Light) {
    $src = if ($Light) { "Explore toi-même le projet (lecture seule) juste assez pour décrire l'étape." } else { "CARTE DU CODE :`n$carte`n`nCRITIQUE DE LA CARTE :`n$critique" }
    @"
$(Step-Common $step)
Écris la SPÉCIFICATION d'implémentation de l'étape, exploitable par des agents sans autre contexte.
$src
- "decisions" : les choix que tu prends toi-même (les plus fidèles au cahier et au code) ;
- "questions" : seulement les VRAIES décisions de goût, de contenu ou de conception qui reviennent à l'utilisateur (pas les choix techniques évidents ; 0 à 5) ;
- "lots" : 1 à 4 lots aux fichiers DISJOINTS (deux lots ne modifient jamais le même fichier), avec la liste exacte des fichiers de chacun ;
- "tests" : ce qu'il faut vérifier, avec des valeurs attendues ; "verifications" : la vérification en vrai (le cahier dit comment) ;
- les étapes déjà faites de la feuille de route et leurs specs (dossier .flow\workflow\etapes\) sont à respecter.
Réponds UNIQUEMENT avec un objet JSON valide :
$SpecSchema
"@
}

function Step-Review-Prompt($step, [string]$kind, [string]$specText) {
    $angle = if ($kind -eq 'fidelite') { 'FIDÉLITÉ : écart avec le cahier du projet et les décisions de l''utilisateur, oubli, invention non justifiée, question posée à l''utilisateur qui est déjà tranchée par le cahier.' } else { 'FAISABILITÉ : chaque emplacement de code cité existe-t-il (vérifie) ? les lots sont-ils vraiment disjoints ? les tests prévus sont-ils exécutables ? manque-t-il une étape technique ?' }
    @"
$(Step-Common $step)
Relis cette spécification sous l'angle $angle
SPÉCIFICATION :
$specText
Réponds UNIQUEMENT avec un objet JSON : { "corrections": ["correction concrète, avec l'endroit de la spec concerné"] } (liste vide s'il n'y a rien à corriger).
"@
}

function Step-Final-Prompt($step, [string]$specText, [string]$corrections) {
    @"
$(Step-Common $step)
Voici la spécification et les corrections demandées par deux relectures. Applique celles qui sont justifiées (vérifie chacune ; écarte celles qui sont fausses) et rends la spécification FINALE, au même format.
SPÉCIFICATION :
$specText
CORRECTIONS DEMANDÉES :
$corrections
Réponds UNIQUEMENT avec un objet JSON valide :
$SpecSchema
"@
}

# ───────────────────────── exécution : appels en parallèle ─────────────────────────
function Wait-Jobs-Spinner($jobs, [string]$label, [double]$TimeoutMin = 15) {
    # attend plusieurs tâches de fond avec un indicateur ; Échap annule (renvoie $null) ; au-delà du délai, les tâches non rendues sont arrêtées ($null à leur place)
    Cls
    $t0 = Get-Date
    while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count) {
        $el = ((Get-Date) - $t0)
        if ($el.TotalMinutes -ge $TimeoutMin) { foreach ($jb in $jobs) { if ($jb.State -eq 'Running') { Stop-Job $jb -ErrorAction SilentlyContinue } }; Write-FlowLog "tâches de fond : délai de $TimeoutMin minutes dépassé ($label)" 'ERREUR'; break }
        $n = @($jobs | Where-Object { $_.State -ne 'Running' }).Count
        Show-Frame @('', "  $(Grad '⚑ ÉTAPE' 0.1)", '', "  $(PalC ($script:Tick * 0.02))$($Spin[$script:Tick % 10])$R $label $Dm$($el.ToString('mm\:ss')) · $n/$(@($jobs).Count) terminé(s)$R", '', (Keys @('Échap', 'annuler')))
        $script:Tick++
        $act = Read-Action
        if ($act.K -and $act.K.Key -eq 'Escape') { foreach ($jb in $jobs) { Stop-Job $jb -ErrorAction SilentlyContinue; Remove-Job $jb -Force -ErrorAction SilentlyContinue }; return $null }
        Start-Sleep -Milliseconds 120
    }
    # une liste explicite : un « $null » émis dans une sous-expression disparaîtrait, et les résultats se décaleraient d'un cran
    $res = [Collections.Generic.List[object]]::new()
    foreach ($jb in $jobs) { if ($jb.State -eq 'Completed') { $res.Add((Receive-Job $jb)) } else { $res.Add($null) }; Remove-Job $jb -Force -ErrorAction SilentlyContinue }
    , $res.ToArray()
}

function Run-Json([string]$role, [string]$stepId, [string]$name, [string]$prompt, [string]$model, $acct, [string]$label) {
    # un appel Claude (lecture seule) dont la réponse est un JSON ; renvoie l'objet, ou $null (annulé ou illisible)
    $dir = Join-Path (Step-Dir $stepId) 'prompts'; New-Item -ItemType Directory -Force $dir | Out-Null
    $pf = Join-Path $dir "$name.md"
    Set-Content -LiteralPath $pf $prompt -Encoding utf8
    $job = Start-ClaudeJob $RepoRoot $acct $pf $model 'Read,Grep,Glob' (Wf-Dir)
    $res = Wait-Job-Spinner $job $label
    if ($null -eq $res) { return $null }
    Log-Call $role $acct $model $res
    Set-Content -LiteralPath (Join-Path $dir "$name.sortie.txt") "$($res.Out)" -Encoding utf8
    Parse-ClaudeJson "$($res.Out)"
}

function Run-JsonParallel([string]$role, [string]$stepId, $items, [string]$label) {
    # plusieurs appels en même temps, répartis sur les comptes connectés ; renvoie un tableau d'objets (ou $null pour un appel raté), ou $null si annulé
    $accts = @(Usable-Accounts); $jobs = @(); $i = 0
    $dir = Join-Path (Step-Dir $stepId) 'prompts'; New-Item -ItemType Directory -Force $dir | Out-Null
    foreach ($it in @($items)) {
        $acct = $accts[$i % $accts.Count]; $i++
        $pf = Join-Path $dir "$($it.Name).md"; Set-Content -LiteralPath $pf $it.Prompt -Encoding utf8
        $jobs += Start-ClaudeJob $RepoRoot $acct $pf $it.Model 'Read,Grep,Glob' (Wf-Dir)
    }
    $res = Wait-Jobs-Spinner $jobs $label
    if ($null -eq $res) { return $null }
    $out = @(); $k = 0
    foreach ($r1 in $res) { $it = @($items)[$k]; $k++
        if ($null -eq $r1) { $out += $null; continue }
        Log-Call $role ($accts[($k - 1) % $accts.Count]) $it.Model $r1
        Set-Content -LiteralPath (Join-Path $dir "$($it.Name).sortie.txt") "$($r1.Out)" -Encoding utf8
        $out += (Parse-ClaudeJson "$($r1.Out)")
    }
    , $out
}

# ───────────────────────── la spécification ─────────────────────────
function Convert-Spec($j) {
    # réponse de Claude → spécification propre ; $null si inexploitable (pas de lot)
    if (-not $j -or -not @($j.lots).Count) { return $null }
    $lots = @(); $used = @{}; $i = 0
    foreach ($l in @($j.lots | Select-Object -First 4)) {
        $i++
        $name = ("$($l.nom)".Trim() -replace '^(?i)lot\s*\d+\s*[—:–-]\s*', '').Trim(); if (-not $name) { $name = "Lot $i" }   # le modèle écrit souvent « Lot 1 — … » : le numéro est ajouté à l'affichage
        if ($used.ContainsKey($name.ToLower())) { $name = "$name ($i)" }; $used[$name.ToLower()] = 1
        $lots += [pscustomobject]@{ nom = $name; fichiers = @(@($l.fichiers) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() }); consigne = "$($l.consigne)".Trim() }
    }
    $clean = { param($x) @(@($x) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() }) }
    [pscustomobject]@{
        resume = "$($j.resume)".Trim()
        decisions = @(@($j.decisions) | Where-Object { $_ -and "$($_.point)".Trim() } | ForEach-Object { [pscustomobject]@{ point = "$($_.point)".Trim(); choix = "$($_.choix)".Trim() } })
        questions = @(Valid-Questions $j.questions | Select-Object -First 5)
        emplacements = @(@($j.emplacements) | Where-Object { $_ -and "$($_.sujet)".Trim() } | ForEach-Object { [pscustomobject]@{ sujet = "$($_.sujet)".Trim(); ou = "$($_.ou)".Trim(); constat = "$($_.constat)".Trim() } })
        lots = $lots; tests = (& $clean $j.tests); verifications = (& $clean $j.verifications); risques = (& $clean $j.risques)
    }
}

function Find-Overlaps($spec) {
    # deux lots ne doivent jamais modifier le même fichier : renvoie les fichiers en conflit
    $seen = @{}; $dup = @()
    foreach ($l in $spec.lots) { foreach ($f in $l.fichiers) { $k = ($f -replace '\\', '/').ToLower(); if ($seen.ContainsKey($k) -and $seen[$k] -ne $l.nom) { $dup += "$f ($($seen[$k]) et $($l.nom))" } else { $seen[$k] = $l.nom } } }
    @($dup | Select-Object -Unique)
}

function ConvertTo-Spec($spec, $step, [string]$userDecisions) {
    $L = [Collections.Generic.List[string]]::new()
    $L.Add("# $($step.id) — $($step.titre) (spécification)"); $L.Add('')
    $L.Add("Date : $(Get-Date -Format 'dd/MM/yyyy') · Passe : $($step.passe) · Statut : spec écrite, construction à faire."); $L.Add('')
    $L.Add($spec.resume); $L.Add('')
    $L.Add('## §0 Décisions'); $L.Add('')
    $L.Add('### Décisions de l''utilisateur (font foi)')
    $L.Add($(if ("$userDecisions".Trim()) { $userDecisions } else { '- (aucune question n''a été nécessaire)' })); $L.Add('')
    $L.Add('### Choix par défaut (à confirmer)')
    if (@($spec.decisions).Count) { foreach ($d in $spec.decisions) { $L.Add("- **$($d.point)** : $($d.choix) *(choix par défaut, à confirmer)*") } } else { $L.Add('- (aucun)') }
    $L.Add('')
    $L.Add('## §1 Ce qui existe (étude)'); $L.Add('')
    if (@($spec.emplacements).Count) { $L.Add('| Sujet | Où | Constat |'); $L.Add('|---|---|---|'); foreach ($em in $spec.emplacements) { $L.Add("| $(Wf-Cell $em.sujet) | $(Wf-Cell $em.ou) | $(Wf-Cell $em.constat) |") } } else { $L.Add('(rien de particulier)') }
    $L.Add('')
    $L.Add('## §2 Lots d''implémentation (fichiers disjoints)'); $L.Add('')
    $i = 0; foreach ($lot in $spec.lots) { $i++; $L.Add("### Lot $i — $($lot.nom)"); $L.Add("Fichiers : $(if (@($lot.fichiers).Count) { @($lot.fichiers) -join ', ' } else { '(à déterminer)' })"); $L.Add(''); $L.Add($lot.consigne); $L.Add('') }
    $L.Add('## §3 Tests'); $L.Add(''); $L.Add((Wf-List $spec.tests '- (à définir)')); $L.Add('')
    $L.Add('## §4 Vérifications en vrai'); $L.Add(''); $L.Add((Wf-List $spec.verifications '- (selon le cahier du projet)')); $L.Add('')
    $L.Add('## §5 Risques'); $L.Add(''); $L.Add((Wf-List $spec.risques '- (aucun relevé)')); $L.Add('')
    ($L -join "`n")
}

function Spec-Block {
    # pour le planificateur : la spécification de l'étape liée à l'équipe
    if (-not $State -or -not "$($State.specPath)".Trim() -or -not (Test-Path -LiteralPath $State.specPath)) { return '' }
    $t = (Get-Content -LiteralPath $State.specPath -Raw -Encoding utf8).Trim()
    if ($t.Length -gt 7000) { $t = $t.Substring(0, 7000) + "`n(… spec tronquée : lis $($State.specPath))" }
    "`n## SPÉCIFICATION DE L'ÉTAPE (FAIT FOI : décisions §0 de l'utilisateur, lots, tests ; le plan DOIT reprendre ses lots — un lot = une tâche, mêmes fichiers — sauf raison écrite dans le brief)`n$t`n"
}

function Show-SpecDraft($spec, $step, [string]$msg) {
    $W = [Math]::Max(40, (ConW) - 1)
    $L = [Collections.Generic.List[string]]::new()
    $L.Add(''); $L.Add("  $(Grad '⚑ ÉTAPE — vérifie la spécification' 0.1)   $B$($step.id)$R $($step.titre)")
    $L.Add((Now 'Entrée = valider et CONSTRUIRE · E = modifier à la main · R = refaire avec une précision · Échap = plus tard'))
    $L.Add('')
    foreach ($x in @(Chunks $spec.resume ($W - 6)) | Select-Object -First 4) { $L.Add("    $x") }
    $L.Add('')
    $L.Add("  $B Lots$R  $Dm(chacun devient une tâche)$R")
    $i = 0; foreach ($lot in $spec.lots) { $i++; $L.Add("    $Teal$i$R  $(Fit $lot.nom 28)  $Dm$(Fit (@($lot.fichiers) -join ', ') ($W - 40))$R") }
    $L.Add("  $B Tests$R $Dm$(@($spec.tests).Count)$R   $B Vérifications en vrai$R $Dm$(@($spec.verifications).Count)$R   $B Risques$R $Dm$(@($spec.risques).Count)$R   $B Décisions par défaut$R $Dm$(@($spec.decisions).Count)$R")
    foreach ($o in @(Find-Overlaps $spec)) { $L.Add("  $Warn⚠ fichier dans deux lots : $o$R") }
    $L.Add('')
    $L.Add("  $Dm Fichier : $(Spec-File $step.id)$R")
    $L.Add((Keys @('Entrée', 'construire', 'E', 'modifier', 'R', 'refaire', 'Échap', 'plus tard')))
    if ($msg) { $L.Add("  $msg") }
    Show-Frame $L
}

function Invoke-StepDesign {
    # la passe de conception d'une étape. Renvoie @{ Mode = 'build' | 'later' | 'cancel' | 'error' ; Msg }
    param($Step, [switch]$Redo)
    $id = $Step.id; $dir = Step-Dir $id; New-Item -ItemType Directory -Force $dir | Out-Null
    $prev = $Step.etat
    $full = ($Step.passe -ne 'légère')
    if ($prev -eq 'à faire') { [void](Set-StepState $id 'conception') }
    Wf-Journal "$id — conception lancée (passe $($Step.passe))"
    $undo = { param($why) if ($prev -eq 'à faire') { [void](Set-StepState $id 'à faire') }; Wf-Journal "$id — conception $why" }
    $acct = Least-Loaded
    $spec = $null; $carte = ''; $critique = ''
    if ($full) {
        # 1) zones à cartographier (au plus 5 : chaque zone est un lecteur, donc un appel)
        $z = Run-Json 'etape-zones' $id 'carte-plan' (Step-Zones-Prompt $Step) 'opus' $acct "FLOW prépare la cartographie de l'étape $id (opus, $($acct.Label))…"
        $zones = @(@($z.zones) | Where-Object { $_ -and "$($_.key)".Trim() } | Select-Object -First 5)
        if (-not $zones.Count) { & $undo 'abandonnée (zones illisibles)'; return @{ Mode = 'error'; Msg = "$Err✗ la cartographie de l'étape n'a pas pu être préparée (réponse illisible ou annulée)$R" } }
        # 2) lecteurs en parallèle (lecture seule), répartis sur les comptes
        $items = @($zones | ForEach-Object { @{ Name = "lecteur-$(("$($_.key)" -replace '[^\w\-]', '_'))"; Prompt = (Step-Reader-Prompt $Step $_); Model = 'sonnet' } })
        $reads = Run-JsonParallel 'etape-lecteur' $id $items "$($zones.Count) lecteur(s) cartographient le code en parallèle (sonnet)…"
        if ($null -eq $reads) { & $undo 'annulée'; return @{ Mode = 'cancel'; Msg = "$Dm conception annulée$R" } }
        # une carte trop longue gonfle toutes les consignes suivantes (critique, spec, relectures) : au plus 5000 caractères par zone, le reste est dans prompts\
        $carte = (@($reads | Where-Object { $_ } | ForEach-Object { $cz = "$($_.constats)"; if ($cz.Length -gt 5000) { $cz = $cz.Substring(0, 5000) + "`n(… zone tronquée : le détail est dans prompts\lecteur-*.sortie.txt)" }; "## Zone $($_.zone)`n$cz" }) -join "`n`n")
        if (-not $carte.Trim()) { & $undo 'abandonnée (aucune carte)'; return @{ Mode = 'error'; Msg = "$Err✗ aucun lecteur n'a rendu de carte exploitable$R" } }
        Write-TextAtomic -Path (Join-Path $dir 'carte.md') -Text "# Carte du code — $id $($Step.titre)`n`n$carte`n"
        # 3) critique de complétude
        $c = Run-Json 'etape-critique' $id 'critique' (Step-Critic-Prompt $Step $carte) 'opus' $acct "la critique de complétude de la carte (opus, $($acct.Label))…"
        $critique = if ($c) { $c | ConvertTo-Json -Depth 6 } else { '(critique indisponible)' }
    }
    # 4) la spécification
    $j = Run-Json 'etape-spec' $id $(if ($full) { 'spec' } else { 'spec-legere' }) (Step-Spec-Prompt $Step $carte $critique (-not $full)) 'opus' $acct "FLOW écrit la spécification de l'étape $id (opus, $($acct.Label))…"
    $spec = Convert-Spec $j
    if (-not $spec) { & $undo 'abandonnée (spec inexploitable)'; return @{ Mode = 'error'; Msg = "$Err✗ la spécification est inexploitable (aucun lot) : réessaie avec L, sortie dans $dir\prompts$R" } }
    # 5) relectures « fidélité » et « faisabilité » en parallèle, puis spec finale (passe complète)
    if ($full) {
        $tmp = ConvertTo-Spec $spec $Step ''
        $revs = Run-JsonParallel 'etape-revue' $id @(@{ Name = 'revue-fidelite'; Prompt = (Step-Review-Prompt $Step 'fidelite' $tmp); Model = 'sonnet' }, @{ Name = 'revue-faisabilite'; Prompt = (Step-Review-Prompt $Step 'faisabilite' $tmp); Model = 'sonnet' }) 'deux relectures de la spécification : fidélité au cahier, faisabilité (sonnet)…'
        if ($null -eq $revs) { & $undo 'annulée'; return @{ Mode = 'cancel'; Msg = "$Dm conception annulée$R" } }
        $corr = @($revs | Where-Object { $_ } | ForEach-Object { @($_.corrections) } | Where-Object { "$_".Trim() } | ForEach-Object { "- $_" })
        if ($corr.Count) {
            $fj = Run-Json 'etape-final' $id 'spec-final' (Step-Final-Prompt $Step $tmp ($corr -join "`n")) 'opus' $acct "la spécification est corrigée d'après les relectures (opus, $($acct.Label))…"
            $final = Convert-Spec $fj
            if ($final) { $spec = $final }
        }
    }
    # 6) les vraies décisions te reviennent
    $decisions = ''
    $qs = @($spec.questions)
    if ($qs.Count) {
        $ans = Ask-Questions $qs "⚑ ÉTAPE $id — décisions à prendre" "$($Step.titre)"
        if ($null -ne $ans) { Log-Answers $qs $ans 'etape'; $decisions = Format-Answers $qs $ans }
    }
    $extra = ''
    while ($true) {
        Write-TextAtomic -Path (Spec-File $id) -Text (ConvertTo-Spec $spec $Step $decisions)
        Write-JsonAtomic ([ordered]@{ version = 1; validated = $false; updated = (Get-Date).ToString('o') }) (Spec-MetaFile $id)
        $note = ''
        while ($true) {
            Show-SpecDraft $spec $Step $note
            $k = Read-KeyOrHint; $ch = "$($k.KeyChar)".ToLower()
            if ($k.Key -eq 'Enter') {
                Write-JsonAtomic ([ordered]@{ version = 1; validated = $true; updated = (Get-Date).ToString('o') }) (Spec-MetaFile $id)
                Wf-Journal "$id — conception terminée : spec validée ($(@($spec.lots).Count) lot(s))"
                Write-Event 'etape_conception' @{ etape = $id; passe = $Step.passe; lots = @($spec.lots).Count; questions = $qs.Count }
                return @{ Mode = 'build'; Msg = "$Ok✓ spécification validée : $(Spec-File $id)$R" }
            }
            elseif ($k.Key -eq 'Escape') { Wf-Journal "$id — spec gardée en brouillon"; return @{ Mode = 'later'; Msg = "$Warn spécification gardée en brouillon : L sur l'étape pour la reprendre$R" } }
            elseif ($ch -eq 'e') { Start-Process notepad.exe -ArgumentList "`"$(Spec-File $id)`"" -Wait; $note = "$Ok✓ spécification relue$R"; Cls }
            elseif ($ch -eq 'r') {
                $extra = Read-Line "⚑ ÉTAPE $id — refaire" 'Qu''est-ce qui ne va pas dans cette spécification ?'
                Cls
                if ($extra) {
                    $fj = Run-Json 'etape-final' $id 'spec-refaite' (Step-Final-Prompt $Step (ConvertTo-Spec $spec $Step $decisions) "- Demande de l'utilisateur : $extra") 'opus' $acct "la spécification est refaite d'après ta remarque (opus, $($acct.Label))…"
                    $new = Convert-Spec $fj
                    if ($new) { $spec = $new; break } else { $note = "$Err✗ la correction n'a pas abouti : la spécification actuelle est gardée$R" }
                }
            }
        }
    }
}

# ───────────────────────── lancer une étape, l'enchaîner ─────────────────────────
function Start-StepBuild($Step) {
    # construction : l'équipe de FLOW, liée à l'étape et à sa spécification ; la passe de l'étape impose celle du contrôle
    $req = "Construire l'étape $($Step.id) — $($Step.titre).`nBut : $($Step.but)`nSuis la spécification de l'étape (fait foi : décisions §0, lots, tests)."
    Start-Run $req '' $Step.id (Spec-File $Step.id) $(if ($Step.passe -eq 'légère') { 'light' } else { 'full' })
}

function Invoke-StepLaunch([string]$id) {
    # concevoir (si besoin) puis construire une étape ; renvoie le mode suivant de FLOW ('plan' ou 'home')
    $road = Read-Roadmap
    if ($road.Errors.Count) { [void](Message-Screen '⚑ ÉTAPE' @("$Warn ROADMAP.md contient des lignes à corriger : FLOW ne lance rien tant que ce n'est pas réglé.$R", "$Dm(E dans l'écran de la feuille de route)$R") @('Entrée', 'retour')); return 'home' }
    $step = @($road.Steps | Where-Object { $_.id -ieq $id }) | Select-Object -First 1
    if (-not $step) { return 'home' }
    if ($step.etat -eq 'fait') {
        $k = Message-Screen "⚑ ÉTAPE $($step.id) — déjà faite" @("« $($step.titre) » est marquée faite.", 'La relancer créerait une nouvelle équipe sur cette étape.') @('O', 'relancer quand même', 'Échap', 'retour')
        if ("$($k.KeyChar)".ToLower() -ne 'o') { return 'home' }
    }
    $redo = $false
    if (Spec-Validated $step.id) {
        $k = Message-Screen "⚑ ÉTAPE $($step.id) — spécification prête" @("Une spécification validée existe pour « $($step.titre) ».", "$Dm$(Spec-File $step.id)$R") @('Entrée', 'construire', 'R', 'refaire la conception', 'Échap', 'retour')
        if ($k.Key -eq 'Escape') { return 'home' }
        if ("$($k.KeyChar)".ToLower() -eq 'r') { $redo = $true } else { Cls; Wf-Journal "$($step.id) — construction lancée"; return (Start-StepBuild $step) }
    }
    $design = Invoke-StepDesign $step -Redo:$redo
    Cls
    if ($design.Mode -ne 'build') { [void](Message-Screen "⚑ ÉTAPE $($step.id)" @($design.Msg) @('Entrée', 'continuer')); return 'home' }
    Wf-Journal "$($step.id) — construction lancée"
    Start-StepBuild (@((Read-Roadmap).Steps | Where-Object { $_.id -ieq $id }) | Select-Object -First 1)
}

function Offer-NextStep {
    # après une étape terminée et livrée : propose d'enchaîner la suivante, sauf si une vérification a échoué ou si le juge n'était pas convaincu
    param([bool]$Clean)
    if (-not (Roadmap-Active)) { return $null }
    $next = @((Read-Roadmap).Steps | Where-Object { $_.etat -eq 'à faire' }) | Select-Object -First 1
    if (-not $next) { [void](Message-Screen '⚑ FEUILLE DE ROUTE' @("$Ok✓ Plus aucune étape à faire : la feuille de route est terminée.$R") @('Entrée', 'continuer')); return $null }
    if (-not $Clean) { [void](Message-Screen '⚑ FEUILLE DE ROUTE' @("$Warn Une vérification a échoué ou le juge n'était pas convaincu : FLOW n'enchaîne pas l'étape suivante.$R", "$Dm Suivante : $($next.id) — $($next.titre) (F9 pour la lancer quand tu veux)$R") @('Entrée', 'continuer')); return $null }
    $k = Message-Screen '⚑ FEUILLE DE ROUTE — enchaîner ?' @("Étape suivante : $B$($next.id)$R — $($next.titre)", "$Dm But : $($next.but)$R", "$Dm Passe : $($next.passe)$R", '', 'FLOW commence par la conception (cartographie, spécification) puis te pose les vraies décisions.') @('Entrée', 'enchaîner maintenant', 'Échap', 'plus tard')
    if ($k.Key -eq 'Enter') { return $next.id }
    $null
}
