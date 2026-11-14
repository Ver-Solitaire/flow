#Requires -Version 7
# Garde-fous contre les familles de défauts déjà rencontrées dans FLOW (analyse du code, sans rien exécuter).

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent

    # PowerShell ne distingue pas les majuscules des minuscules dans les noms de variables : une variable locale « $ok » masque la couleur « $Ok »
    # (et celle de toutes les fonctions appelées), « $r » masque « $R » (réinitialisation des couleurs), etc.
    function Find-ShadowedColors([string]$Path) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $always = 'ok', 'err', 'info', 'warn', 'dm', 'teal'        # jamais comme variable locale dans ces scripts
        foreach ($fn in $fns) {
            $locals = $fn.FindAll({ param($n)
                    ($n -is [System.Management.Automation.Language.ParameterAst]) -or
                    ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst]) -or
                    ($n -is [System.Management.Automation.Language.ForEachStatementAst]) }, $true)
            foreach ($l in $locals) {
                $name = if ($l -is [System.Management.Automation.Language.ParameterAst]) { $l.Name.VariablePath.UserPath }
                elseif ($l -is [System.Management.Automation.Language.AssignmentStatementAst]) { $l.Left.VariablePath.UserPath }
                else { $l.Variable.VariablePath.UserPath }
                if ($name -in $always) { "$([IO.Path]::GetFileName($Path)):$($l.Extent.StartLineNumber) $($fn.Name)() : `$$name masque la couleur" }
                elseif ($name -in 'r', 'b') {
                    $upper = $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -ceq $name.ToUpper() }, $true)
                    if ($upper.Count) { "$([IO.Path]::GetFileName($Path)):$($l.Extent.StartLineNumber) $($fn.Name)() : `$$name masque `$$($name.ToUpper())" }
                }
            }
        }
    }
}

Describe 'Pièges PowerShell' {
    It 'aucune fonction de FLOW.ps1, de flow-team.ps1 ni des modules qu''il charge ne masque une couleur d''affichage' {
        $found = foreach ($f in 'FLOW.ps1', 'tools\flow-team.ps1', 'tools\flow-workflow.ps1', 'tools\flow-profile.ps1', 'tools\flow-deps.ps1') { Find-ShadowedColors (Join-Path $script:Root $f) }
        @($found) | Should -BeNullOrEmpty
    }

    It 'tous les scripts se chargent sans erreur de syntaxe' {
        $errs = foreach ($f in Get-ChildItem $script:Root -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\\.modules\\|\\\.git\\|sources-cache' }) {
            $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
            foreach ($x in $e) { "$($f.Name):$($x.Extent.StartLineNumber) $($x.Message)" }
        }
        @($errs) | Should -BeNullOrEmpty
    }
}
