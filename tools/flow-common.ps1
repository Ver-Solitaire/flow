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
