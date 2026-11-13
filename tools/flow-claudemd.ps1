# flow-claudemd.ps1 — crée un CLAUDE.md de départ pour n'importe quel projet (chargé avec « . »). N'exécute rien à son chargement.
# Le fichier est construit SANS appeler Claude (gratuit, immédiat) à partir de ce qui est détecté dans le dossier : langages, commandes,
# organisation, style des commits. Il est clairement marqué « à relire » : les Claude qui travailleront dans le projet (et les ouvriers
# d'une équipe FLOW) le lisent au début de chaque session.

function New-ClaudeMd {
    <# Renvoie le chemin du fichier créé, ou $null s'il existe déjà (sauf -Force). #>
    param([Parameter(Mandatory)][string]$Dir, [switch]$Force)
    $target = Join-Path $Dir 'CLAUDE.md'
    if ((Test-Path -LiteralPath $target) -and -not $Force) { return $null }
    $bt = [char]96
    $name = Split-Path $Dir.TrimEnd('\', '/') -Leaf
    $has = { param($p) Test-Path -LiteralPath (Join-Path $Dir $p) }
    $kinds = [Collections.Generic.List[string]]::new()
    $cmd = [Collections.Generic.List[string]]::new()

    if (& $has 'package.json') {
        $kinds.Add('JavaScript / TypeScript')
        $pm = if (& $has 'pnpm-lock.yaml') { 'pnpm' } elseif (& $has 'yarn.lock') { 'yarn' } elseif ((& $has 'bun.lockb') -or (& $has 'bun.lock')) { 'bun' } else { 'npm' }
        $inst = switch ($pm) { 'pnpm' { 'pnpm install' } 'yarn' { 'yarn install' } 'bun' { 'bun install' } default { if (& $has 'package-lock.json') { 'npm ci' } else { 'npm install' } } }
        $cmd.Add("Installer : $bt$inst$bt")
        $pj = $null
        try { $pj = Get-Content -LiteralPath (Join-Path $Dir 'package.json') -Raw -Encoding utf8 | ConvertFrom-Json } catch {}
        foreach ($pair in @(@('Lancer en développement', @('dev', 'start', 'serve')), @('Construire', @('build')), @('Tester', @('test')), @('Vérifier le style', @('lint')), @('Vérifier les types', @('typecheck', 'type-check', 'tsc')))) {
            foreach ($k in $pair[1]) {
                $v = if ($pj -and $pj.scripts) { $pj.scripts.$k } else { $null }
                if ($v -and $v -notmatch 'no test specified') { $cmd.Add("$($pair[0]) : $bt$pm run $k$bt"); break }
            }
        }
    }
    if ((& $has 'pyproject.toml') -or (& $has 'requirements.txt') -or (& $has 'setup.py')) {
        $kinds.Add('Python')
        $run = ''
        if (& $has 'uv.lock') { $cmd.Add("Installer : ${bt}uv sync$bt"); $run = 'uv run ' }
        elseif (& $has 'poetry.lock') { $cmd.Add("Installer : ${bt}poetry install$bt"); $run = 'poetry run ' }
        elseif (& $has 'requirements.txt') { $cmd.Add("Installer : ${bt}pip install -r requirements.txt$bt (dans un environnement virtuel : ${bt}python -m venv .venv$bt)") }
        else { $cmd.Add("Installer : ${bt}pip install -e .$bt (dans un environnement virtuel)") }
        $py = if (& $has 'pyproject.toml') { Get-Content -LiteralPath (Join-Path $Dir 'pyproject.toml') -Raw -ErrorAction SilentlyContinue } else { '' }
        if ($py -match 'pytest' -or (& $has 'pytest.ini') -or (& $has 'tests')) { $cmd.Add("Tester : $bt${run}python -m pytest -q$bt") }
        if ($py -match '\[tool\.ruff' -or (& $has 'ruff.toml')) { $cmd.Add("Vérifier le style : $bt${run}ruff check .$bt") }
        if ($py -match '\[tool\.mypy' -or (& $has 'mypy.ini')) { $cmd.Add("Vérifier les types : $bt${run}mypy .$bt") }
    }
    if (& $has 'Cargo.toml') { $kinds.Add('Rust'); $cmd.Add("Construire : ${bt}cargo build$bt"); $cmd.Add("Tester : ${bt}cargo test$bt") }
    if (& $has 'go.mod') { $kinds.Add('Go'); $cmd.Add("Construire : ${bt}go build ./...$bt"); $cmd.Add("Tester : ${bt}go test ./...$bt") }
    if (Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.sln', '.csproj', '.fsproj' } | Select-Object -First 1) {
        $kinds.Add('.NET'); $cmd.Add("Construire : ${bt}dotnet build$bt"); $cmd.Add("Tester : ${bt}dotnet test$bt")
    }
    if (& $has 'pom.xml') { $kinds.Add('Java (Maven)'); $cmd.Add("Tester : ${bt}mvn -q test$bt") }
    if ((& $has 'build.gradle') -or (& $has 'build.gradle.kts')) { $kinds.Add('Java / Kotlin (Gradle)'); $cmd.Add("Tester : ${bt}.\gradlew.bat test$bt") }
    if (& $has 'composer.json') { $kinds.Add('PHP'); $cmd.Add("Installer : ${bt}composer install$bt") }
    if (& $has 'Gemfile') { $kinds.Add('Ruby'); $cmd.Add("Installer : ${bt}bundle install$bt") }
    if ((& $has 'tests\run.ps1')) { $kinds.Add('PowerShell'); $cmd.Add("Tester : ${bt}pwsh -File tests\run.ps1$bt") }
    if (-not $cmd.Count -and (& $has 'Makefile')) {
        $mk = Get-Content -LiteralPath (Join-Path $Dir 'Makefile') -Raw -ErrorAction SilentlyContinue
        foreach ($tg in 'build', 'test', 'lint', 'run') { if ($mk -match "(?m)^${tg}:") { $cmd.Add("$tg : ${bt}make $tg$bt") } }
        if ($cmd.Count) { $kinds.Add('Makefile') }
    }
    if (-not $kinds.Count -and (& $has 'index.html')) { $kinds.Add('Site statique (HTML)'); $cmd.Add("Voir : ouvrir ${bt}index.html$bt, ou ${bt}python -m http.server$bt puis http://localhost:8000") }

    # but : première phrase utile du README
    $but = ''
    foreach ($rd in 'README.md', 'README.txt', 'README') {
        $rp = Join-Path $Dir $rd
        if (Test-Path -LiteralPath $rp) {
            $but = (Get-Content -LiteralPath $rp -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and $_ -notmatch '^\s*(#|\[!|!\[|<|---|===)' } | Select-Object -First 2) -join ' '
            break
        }
    }

    # organisation : dossiers de premier niveau
    $skip = '^(\.git|node_modules|\.venv|venv|__pycache__|dist|build|bin|obj|target|\.next|\.idea|\.vscode|\.flow|\.pytest_cache|\.ruff_cache|\.mypy_cache)$'
    $dirs = @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $skip } | Select-Object -First 15 -ExpandProperty Name)

    # conventions : branche et style des commits, d'après l'historique
    $branch = ''; $style = ''
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if ($git -and (Test-Path -LiteralPath (Join-Path $Dir '.git'))) {
        $branch = "$(& $git -C $Dir rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)".Trim()
        $subjects = @(& $git -C $Dir log -n 40 --no-merges --format=%s 2>$null | Where-Object { $_ })
        if ($subjects.Count -ge 4) {
            $conv = @($subjects | Where-Object { $_ -match '^(feat|fix|chore|docs|refactor|test|perf|build|ci|style|revert)(\([^)]*\))?!?: ' }).Count
            $style = if ($conv -ge $subjects.Count * 0.5) { 'Conventional Commits (feat:, fix:, docs:…)' } else { 'messages libres, courts : quoi et pourquoi' }
        }
    }

    $L = [Collections.Generic.List[string]]::new()
    $L.Add("# $name")
    $L.Add('')
    $L.Add("> Fichier de consignes pour Claude Code, **créé automatiquement par FLOW le $(Get-Date -Format 'dd/MM/yyyy')** d'après ce qui a été détecté dans le dossier. **À relire et compléter** : plus il est précis, mieux Claude (et chaque ouvrier d'une équipe FLOW) travaillera. Les passages « (à compléter) » attendent ton avis.")
    $L.Add('')
    $L.Add('## But')
    $L.Add($(if ($but) { $but } else { '(à compléter : à quoi sert ce projet, et pour qui ? Deux lignes.)' }))
    if ($kinds.Count) { $L.Add(''); $L.Add("Technologies détectées : $($kinds -join ', ').") }
    $L.Add('')
    $L.Add('## Commandes')
    if ($cmd.Count) { foreach ($c in $cmd) { $L.Add("- $c") } } else { $L.Add('- (à compléter : comment installer, lancer, tester et vérifier le projet ?)') }
    $L.Add('')
    $L.Add('## Organisation')
    if ($dirs.Count) { foreach ($d in $dirs) { $L.Add("- $bt$d/$bt : (à compléter)") } } else { $L.Add('- (le projet est encore vide : décris ici la structure prévue.)') }
    $L.Add('')
    $L.Add('## Conventions')
    $L.Add('- Langue des messages, commentaires et commits : (à compléter)')
    if ($branch) { $L.Add("- Branche principale : $bt$branch$bt") }
    if ($style) { $L.Add("- Commits : $style") }
    $L.Add('- Avant de terminer une tâche : lancer les tests et les vérifications ci-dessus, et corriger ce qu''on a cassé.')
    $L.Add('')
    $L.Add('## À savoir')
    $L.Add('- (à compléter : décisions prises et leur raison, pièges connus, choses à ne jamais faire dans ce projet, secrets à ne pas commiter.)')
    $L.Add('')
    Write-TextAtomic -Path $target -Text ($L -join "`n")
    $target
}
