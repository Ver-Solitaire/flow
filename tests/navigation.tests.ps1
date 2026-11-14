#Requires -Version 7
# Navigation : Échap ne ferme jamais la fenêtre Équipe (retour d'un niveau, accueil à la racine).
BeforeAll { $script:src = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\flow-team.ps1') -Raw -Encoding utf8 }
Describe 'Équipe : Échap ne ferme rien' {
    It 'aucune aide ne propose de « quitter » avec Échap' { $src | Should -Not -Match "'Échap', 'quitter'" }
    It 'la boucle principale ne s''arrête jamais d''elle-même (« quit » = retour)' {
        $src | Should -Not -Match 'while \(\$mode -ne ''quit''\)'
        $src | Should -Match '\$Nav = '
    }
    It 'Échap dans le plan ne détruit plus le plan (X abandonne, avec confirmation)' {
        $src | Should -Not -Match "(?s)elseif \(\`$k\.Key -eq 'Escape'\) \{\s*\`$State\.status = 'discarded'"
        $src | Should -Match "'X', 'abandonner', 'Échap', 'retour'"
    }
}
