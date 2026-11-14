#Requires -Version 7
# Génération du CLAUDE.md de départ (tools\flow-claudemd.ps1) pour différents débuts de projet.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'tools\flow-common.ps1')
    . (Join-Path $script:Root 'tools\flow-claudemd.ps1')
    $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('flowmd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    function New-Proj([string]$Name) { $d = Join-Path $script:Base $Name; New-Item -ItemType Directory -Force $d | Out-Null; $d }
}

AfterAll { Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'New-ClaudeMd' {
    It 'crée un modèle exploitable pour un projet entièrement vide' {
        $d = New-Proj 'vide'
        $f = New-ClaudeMd $d
        $f | Should -Be (Join-Path $d 'CLAUDE.md')
        $t = Get-Content $f -Raw -Encoding utf8
        $t | Should -Match '^# vide'
        $t | Should -Match 'créé automatiquement par FLOW'
        $t | Should -Match '## Commandes'
        $t | Should -Match '\(à compléter'
    }

    It 'ne remplace jamais un CLAUDE.md existant, sauf -Force' {
        $d = New-Proj 'existant'
        Set-Content (Join-Path $d 'CLAUDE.md') 'mes consignes'
        New-ClaudeMd $d | Should -BeNullOrEmpty
        (Get-Content (Join-Path $d 'CLAUDE.md') -Raw).Trim() | Should -Be 'mes consignes'
        New-ClaudeMd $d -Force | Should -Not -BeNullOrEmpty
    }

    It 'détecte un projet Node : outil, scripts, dossiers, but tiré du README' {
        $d = New-Proj 'noeud'
        Set-Content (Join-Path $d 'package.json') '{ "scripts": { "dev": "vite", "build": "vite build", "test": "vitest", "lint": "eslint ." } }'
        Set-Content (Join-Path $d 'pnpm-lock.yaml') ''
        Set-Content (Join-Path $d 'README.md') "# Ma boutique`n`nUne boutique en ligne pour vendre des bougies.`n"
        New-Item -ItemType Directory -Force (Join-Path $d 'src'), (Join-Path $d 'node_modules') | Out-Null
        $t = Get-Content (New-ClaudeMd $d) -Raw -Encoding utf8
        $t | Should -Match 'JavaScript / TypeScript'
        $t | Should -Match 'pnpm install'
        $t | Should -Match 'pnpm run dev'
        $t | Should -Match 'pnpm run test'
        $t | Should -Match 'Une boutique en ligne pour vendre des bougies'
        $t | Should -Match 'src/'
        $t | Should -Not -Match 'node_modules'
    }

    It 'détecte un projet Python (uv, pytest, ruff) et lit le style des commits' {
        $d = New-Proj 'python'
        Set-Content (Join-Path $d 'pyproject.toml') "[project]`nname='x'`n[tool.ruff]`nline-length=100`n[tool.pytest.ini_options]`n"
        Set-Content (Join-Path $d 'uv.lock') ''
        New-Item -ItemType Directory -Force (Join-Path $d 'tests') | Out-Null
        & git -C $d init -q -b main
        foreach ($m in 'feat: a', 'fix: b', 'docs: c', 'feat: d', 'chore: e') { & git -C $d -c user.name=t -c user.email=t@t commit -q --allow-empty -m $m }
        $t = Get-Content (New-ClaudeMd $d) -Raw -Encoding utf8
        $t | Should -Match 'uv sync'
        $t | Should -Match 'uv run python -m pytest'
        $t | Should -Match 'uv run ruff check'
        $t | Should -Match 'Conventional Commits'
        $t | Should -Match 'Branche principale : `main`'
    }

    It 'crée aussi la mémoire du projet (memoire\) et les sections Mémoire et Garde-fous' {
        $d = New-Proj 'memoire'
        $t = Get-Content (New-ClaudeMd $d) -Raw -Encoding utf8
        $t | Should -Match '## Mémoire du projet'
        $t | Should -Match 'memoire/INDEX.md'
        $t | Should -Match '## Garde-fous'
        foreach ($f in 'INDEX.md', 'etat-actuel.md', 'decisions.md', 'pieges.md', 'historique.md') { Test-Path (Join-Path $d "memoire\$f") | Should -BeTrue }
        (Get-Content (Join-Path $d 'memoire\INDEX.md') -Raw -Encoding utf8) | Should -Match 'REMPLAÇANT l''ancien état'
    }

    It 'New-ProjectMemory ne remplace jamais une fiche existante et ne recrée que ce qui manque' {
        $d = New-Proj 'memoire2'
        New-Item -ItemType Directory -Force (Join-Path $d 'memoire') | Out-Null
        Set-Content (Join-Path $d 'memoire\pieges.md') 'mes pièges'
        $made = @(New-ProjectMemory $d)
        $made.Count | Should -Be 4
        (Get-Content (Join-Path $d 'memoire\pieges.md') -Raw).Trim() | Should -Be 'mes pièges'
        @(New-ProjectMemory $d).Count | Should -Be 0
    }

    It 'reconnaît un site statique' {
        $d = New-Proj 'site'
        Set-Content (Join-Path $d 'index.html') '<html></html>'
        (Get-Content (New-ClaudeMd $d) -Raw -Encoding utf8) | Should -Match 'Site statique'
    }
}
