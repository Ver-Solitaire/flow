# flow-common.ps1 — fonctions partagées par FLOW.ps1 et les outils (chargé avec « . »). N'exécute rien à son chargement.

function Write-TextAtomic {
    <#
      Écrit un fichier texte sans jamais laisser un fichier à moitié écrit : le texte va dans un fichier temporaire voisin,
      puis remplace l'original en une seule opération. -Backup garde la version précédente dans « <fichier>.bak ».
      Si le remplacement est refusé (un lecteur tient le fichier ouvert un instant), repli sur une écriture directe.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$Backup)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $enc = [Text.UTF8Encoding]::new($false)
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $Text, $enc)
    try {
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, $(if ($Backup) { "$Path.bak" } else { $null }), $true) }
        else { [IO.File]::Move($tmp, $Path) }
    } catch {
        try { [IO.File]::WriteAllText($Path, $Text, $enc) } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-JsonAtomic {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Path, [int]$Depth = 12, [switch]$Backup)
    Write-TextAtomic -Path $Path -Text ($Object | ConvertTo-Json -Depth $Depth) -Backup:$Backup
}

function Q([string]$s) {
    # Chaîne PowerShell entre apostrophes. PowerShell traite aussi les apostrophes typographiques (‘ ’ ‚ ‛) comme des guillemets
    # simples : elles sont doublées comme les apostrophes droites, sinon un texte comme « l’été » sortirait de la chaîne
    # (un titre de tâche forgé pourrait alors exécuter une commande).
    "'" + [regex]::Replace($s, "['‘’‚‛]", '$0$0') + "'"
}

function Auth-Strip {
    # Retire de l'environnement d'un panneau les variables qui imposeraient une authentification autre que le compte choisi :
    # une clé d'API ou un jeton hérité ferait passer TOUS les « comptes » par la même identité (et la facturation à l'usage).
    'Remove-Item Env:ANTHROPIC_API_KEY, Env:ANTHROPIC_AUTH_TOKEN, Env:CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue; '
}

function Write-FlowLog {
    # Journal de FLOW (config\flow.log, 200 Ko au plus, l'ancien est gardé en .1). Ne lève jamais d'erreur.
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARN', 'ERREUR')][string]$Level = 'INFO')
    $f = $global:FlowLogFile
    if (-not $f) { return }
    try {
        $dir = Split-Path -Parent $f
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 200KB) { Move-Item -LiteralPath $f "$f.1" -Force }
        Add-Content -LiteralPath $f -Encoding utf8 -Value ("{0} [{1}] {2,-6} {3}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $PID, $Level, ($Message -replace '\s+', ' '))
    } catch {}
}
