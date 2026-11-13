# FLOW — consignes pour les Claude qui modifient ce projet

FLOW est un lanceur Windows : plusieurs Claude Code dans des panneaux psmux (tmux natif), sur plusieurs comptes, avec une fenêtre « Équipe »
qui découpe une demande en tâches, les confie à des Claude séparés (une copie Git par tâche), les fait se relire, puis fusionne après validation.
PowerShell 7 + une petite application C# (app\FlowApp.cs → FLOW.exe). L'utilisateur n'est pas développeur : tout doit rester simple à lancer et à dépanner.

## Avant de modifier
- `pwsh -File tests\run.ps1` (Pester 5, ~10 s) : doit rester vert. Ajoute un test pour tout défaut corrigé (dépôts Git jetables, faux Claude : jamais de vrai appel).
- `pwsh -File FLOW.ps1 -Doctor` : état de la machine. Journal : `config\flow.log` (écris-y avec `Write-FlowLog`).
- Ne lance jamais de commande psmux sur le serveur `flow` (`psmux -L flow …` : `kill-server`, `kill-session`, `send-keys`) : l'utilisateur y a peut-être des Claude au travail.
  Pour tester, utilise une autre socket (`-L flowtest`) et ferme-la ensuite.

## Carte
| Fichier | Rôle |
|---|---|
| FLOW.ps1 | sélecteur de profils, projets, comptes (connexion, ajout), construction des sessions psmux, skills, `-Doctor`, `-InstallShortcut` |
| tools\flow-team.ps1 | fenêtre Équipe : plan → ouvriers → relecture croisée → intégration → validation → livraison |
| tools\flow-plan.ps1 | dépose un plan écrit par un Claude (skill taches-repartir) dans l'Équipe |
| tools\flow-pane.ps1 | actions des raccourcis psmux (déplacer un panneau, enregistrer la disposition, Ctrl+B T) |
| tools\flow-common.ps1 | `Q` (protection des textes), `Write-JsonAtomic`, `Write-FlowLog`, `Auth-Strip` — à utiliser plutôt que de recopier |
| tools\flow-input.ps1 | clavier + souris des écrans texte |
| tools\claude-monitor.ps1, statusline.ps1 | moniteur temps réel (lit les transcripts de Claude Code) et limites d'usage |
| tools\flow-office.ps1, flow-sprites.ps1 | « Bureau » animé |
| tools\*-demo.ps1 | démonstrations simulées |
| app\FlowApp.cs | choix du projet (compilé par `-InstallShortcut`) |
| skills\ | 4 skills installés dans chaque compte Claude (`{{FLOW_ROOT}}` y est remplacé) |
| profiles\*.json, config\ | dispositions de panneaux ; réglages locaux (comptes, état, projets, journal : jamais commités) |

## Contrats entre processus (un changement d'un côté casse l'autre sans erreur visible)
- Options psmux posées par FLOW, lues par le moniteur et le sélecteur : `@flow_role`, `@flow_base`, `@flow_spec`, `@flow_acct`, `@flow_state`, `@flow_ctx`, `@flow_status`,
  `@flow_profile`, `@flow_cwd`, `@flow_accounts`, `@flow_task`.
- Chaîne des comptes (`-Accounts`) : `id|libellé|couleur|dossier|court` séparés par `;` — ni `|` ni `;` dans un libellé.
- `.flow\runs\<id>\state.json` : écrit par flow-team.ps1 ET flow-plan.ps1 (même schéma ; `Use-Run` complète les champs manquants). Toujours via `Write-JsonAtomic`.
- Consignes des ouvriers : `taches\<id>.prompt.md` ; compte-rendu = `resultats\<id>.md` (sa présence signale « fini »).

## Pièges déjà rencontrés (chacun a un test ou une règle)
1. PowerShell ne distingue pas `$ok` de `$Ok` : ne nomme jamais une variable locale comme une couleur (`$Ok $Err $Info $Warn $Dm $Teal`, ni `$r`/`$b` si `$R`/`$B` servent) — `tests\garde-fous.tests.ps1`.
2. Arguments de `claude` : **la consigne d'abord**, jamais après une option à valeurs multiples (`--add-dir`, `--allowedTools`, `--tools`, `--mcp-config`…), sinon elle est prise pour une valeur.
3. `Q` double aussi les apostrophes typographiques (‘ ’ ‚ ‛) : toute chaîne qui finit dans une commande passe par `Q`.
4. `$LASTEXITCODE` / `$GitCode` : lis-les juste après l'appel, jamais après un pipeline coupé par `Select-Object -First`.
5. La sortie d'une commande native appelée dans une fonction devient sa valeur de retour : `[void](…)` ou `| Out-Null`.
6. `Cls` est masqué par l'alias `cls` (Clear-Host) : ne compte pas dessus pour masquer le curseur.
7. Rien n'est supprimé sans sauvegarde : copies et branches d'équipe passent par `Cleanup-Run` (refs/flow-archive/…). Pas de `branch -D` / `worktree remove --force` ailleurs.
8. Écritures JSON : `Write-JsonAtomic` (jamais `Set-Content` sur un fichier d'état).

## Conventions
- Français (messages, commentaires, commits). Commits courts : quoi + pourquoi. Une étape = un commit, testée.
- Ne pousse rien sur GitHub, ne publie aucune version, ne choisis pas une licence sans que l'utilisateur le demande.
- Options de Claude Code vérifiées dans l'aide de la version installée (`claude --help`) avant d'être utilisées ; les transcripts JSONL sont un format interne (susceptible de changer).
