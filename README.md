# FLOW — Claude × psmux

Lanceur portable : un sélecteur de profils animé qui recrée tes espaces de travail psmux
(Claude, moniteur, terminaux) en un clic — avec plusieurs comptes Claude, une équipe de Claude qui se
partage une demande, et un « Bureau » où chaque agent est un petit personnage animé.

## Installation (nouvelle machine, Windows)

1. Récupère le dossier (`git clone …` ou téléchargement ZIP).
2. **Double-clique sur `install.cmd`.** Il vérifie et installe ce qui manque avec `winget` :
   PowerShell 7, psmux, Git, Claude Code, Windows Terminal ; puis il crée `config\accounts.json`,
   le raccourci « FLOW » sur le bureau, propose de configurer l'identité Git et de te connecter à Claude.
   (`install.cmd -Yes` : sans questions · `install.cmd -WithGitHubCli` : ajoute GitHub CLI.)
3. Lance FLOW avec le raccourci du bureau. Pour découvrir sans rien risquer :
   `pwsh -File FLOW.ps1 -Demo` (Bureau et moniteur) et `pwsh -File FLOW.ps1 -TeamDemo` (fenêtre Équipe)
   et `pwsh -File FLOW.ps1 -ShareDemo` (profils partagés : deux bibliothèques, un collègue qui publie pendant la démo).

Prérequis : Windows 10/11 avec `winget` (« App Installer » du Microsoft Store).

## Lancer

- **Raccourci bureau « FLOW »**, ou double-clic sur `FLOW.cmd`
- En ligne de commande :

```powershell
pwsh -File FLOW.ps1                       # sélecteur
pwsh -File FLOW.ps1 -Open standard        # lance directement un profil
pwsh -File FLOW.ps1 -Open standard -NoAttach   # construit la session en arrière-plan
pwsh -File FLOW.ps1 -InstallShortcut      # (re)crée le raccourci bureau
```

### Touches du sélecteur

| Touche | Action |
|---|---|
| ↑ ↓ / PgPréc PgSuiv | choisir (la liste défile si elle est longue) |
| 1-9 | lancer directement |
| Entrée | lancer le profil (ou se rattacher s'il est déjà ouvert ●) |
| / | chercher (filtre sur le nom / la description ; Échap efface) |
| N | nouveau profil : choix d'une disposition, du nom et du dossier |
| D | dupliquer le profil |
| F2 | renommer |
| E | éditer le JSON (notepad) — rechargé automatiquement à l'enregistrement |
| Suppr (×2) | supprimer (déplacé dans `profiles\.corbeille`) — **U** juste après pour annuler |
| Maj+↑ / Maj+↓ (ou +/− du pavé num.) | réordonner |
| S | capturer une session psmux en cours → nouveau profil |
| K (×2) / Maj+K (×2) | fermer la session du profil / toutes les sessions FLOW |
| C | comptes Claude : état, connexion d'un compte |
| P | publier le profil dans une bibliothèque partagée (voir plus bas) |
| B | gérer les bibliothèques partagées (ajouter un dossier ou un dépôt Git, synchroniser) |
| O | profil partagé : changer son dossier de travail sur cette machine |
| R | recharger les profils et synchroniser les bibliothèques Git |
| ? | afficher toutes les touches |
| Q / Échap | quitter |

Le sélecteur se place sur le dernier profil lancé (`config\state.json`).

### Réorganiser les panneaux

| Touche | Action |
|---|---|
| `Alt+Maj+←→↑↓` | échanger le panneau actif avec son voisin dans cette direction |
| `Ctrl+B` puis `G`, ou clic droit sur un panneau | menu « Agencer » (déplacer, agrandir, enregistrer) |
| `Ctrl+B` puis `W` | **enregistrer** la disposition dans le profil : au prochain lancement, les panneaux reviennent dans cet ordre (l'ancienne version est gardée en `.bak`) |

Les panneaux gardent leur rôle (Claude et son compte, moniteur, Bureau, équipe…) quand on les déplace.

### Dans une session

| Touche | Action |
|---|---|
| `Ctrl+B` `D` ou `Ctrl+B` `F` | revenir au sélecteur (la session continue de tourner) |
| `Alt`+flèches | changer de panneau |
| `Alt+Z` | agrandir / rétablir le panneau courant |

Chaque panneau affiche son rôle dans sa bordure (« ✦ claude », « ◉ moniteur »…). Pour les panneaux Claude,
le moniteur y ajoute l'état en direct : `● travaille`, `✓ à toi` (bordure **verte** : Claude a fini et attend ta réponse),
`○ en attente`, et le contexte utilisé (`ctx 45%`).
La barre d'état psmux affiche à droite les limites de chaque compte : `C1 sem 97% 5h 40% │ C2 sem 12% 5h 5%`
(`⚠` au-delà de 90 %).

### Personnages et Bureau

Chaque Claude est un petit personnage animé selon ce qu'il fait réellement (outil en cours) :

| Animation | Activité | | Animation | Activité |
|---|---|---|---|---|
| livre `[≡]`, yeux qui lisent | **lit** (Read) | | crayon `~~✎` | **écrit** (Edit, Write) |
| loupe `⌕` qui balaie | **cherche** (Grep, Glob) | | terminal `>_▮` | **exécute** (commandes) |
| globe `◐◓◑◒` | **web** | | bulles `·∘○` | **réfléchit** |
| flèches `→→→` | **délègue** (agents, workflow) | | clavier `▙▟▙` | **au travail** (agent sans détail) |
| `?` | **à toi** (attend ta réponse) | | `zZ` | **en pause** |
| sablier `⧗` | **attend** une autre tâche | | `✓` / `✗` | **fini** / **erreur** |

- **Moniteur** : un personnage par Claude suivi dans l'en-tête, et l'action en cours à côté de l'état
  (« ● travaille · lit facture.ts »).
- **Bureau** (panneau en bas à gauche des profils Standard, Duo et Équipe ; rôle `office`) :
  - pièce **⌂ Bureau** : un personnage par Claude (un par compte) ;
  - pièce **◆ Agents · <compte>** : un personnage nommé par sous-agent lancé par ce Claude ;
  - pièce **⚙ Workflow · <nom>** : un personnage par agent du workflow (noms tirés du script) ;
  - pièce **⚑ Équipe · <résumé>** : un personnage par tâche d'une équipe FLOW, avec son activité réelle.
  Trop petit pour tout dessiner : une ligne par pièce ; `Alt+Z` agrandit le panneau.

**Bulles** : au-dessus de chaque personnage, ce qu'il pense — le dernier message ou raisonnement de Claude
(sinon son action : « Je lis facture.ts… »). Pensée longue : la bulle tourne ses pages (n/N).

**Couleurs d'avancement** (tête et pastille ●) : gris *à faire* · jaune *en cours* · rose *attend une réponse* ·
rouge *bloqué* (erreur, ou conseiller appelé) · vert *fini*.

**Interagir dans le Bureau** : `Tab` / `←` `→` choisir un personnage (entouré d'un cadre vert), `↑` `↓` changer
de pièce, `Entrée` aller à son panneau (même dans une autre session), `M` lui écrire, `Échap` fermer.
Un sous-agent ou un agent de workflow n'a pas de panneau à lui : le message est écrit au Claude qui l'a lancé,
qui le relaie.

### Souris

Tout ce qui se choisit au clavier se clique aussi (dans les panneaux psmux, la souris est transmise aux écrans FLOW) :

| Écran | Clic | 2e clic / double-clic |
|---|---|---|
| Bureau | choisir un personnage (cadre vert) | aller à son panneau |
| Moniteur | un compte ou son personnage : le détailler · **son modèle : le changer** (`/model` envoyé à son Claude, opus → sonnet → haiku) | — |
| Équipe — plan | une tâche : la choisir · **◇ modèle** / **◆ compte** : le changer | — |
| Équipe — tableau de bord | un ouvrier : le choisir | aller à son panneau |
| Sélecteur, listes | un profil / une ligne : le choisir | le lancer / le valider |

Partout, les aides du bas (« Entrée lancer », « M lui écrire », « Échap annuler »…) sont cliquables.
Le module commun est `tools\flow-input.ps1`.

**Démo** : `pwsh -File FLOW.ps1 -Demo` ouvre une fenêtre avec une activité simulée (2 comptes, sous-agents,
workflow, équipe) sur un serveur psmux séparé ; arrêt : `psmux -L flowdemo kill-server`.

Limites : l'activité détaillée d'un sous-agent n'est connue que si Claude Code enregistre son historique
à part ; sinon il est affiché « au travail ». Les agents d'un workflow sont toujours « au travail ».

### Alertes

- **Fin de tour** : notification Windows « ✓ Compte 2 a terminé » quand Claude finit une tâche de plus de 20 s.
  Réglage sur le panneau moniteur du profil : `"notifyAfter": 60` (secondes) ou `"notify": false`.
- **Limites** : au-delà de 90 % (semaine ou session), le moniteur propose l'autre compte s'il est sous 80 %
  (« ⚠ semaine à 95 % → passe sur Compte 2 (10 %) ») et envoie une notification une seule fois.

Dans le sélecteur, un profil ouvert montre aussi son état : `● ouverte · lancée il y a 2 h  ◆ C1 ✓ à toi 48%  ◆ C2 ● travaille 15%`.

## Contenu

```
FLOW/
├─ FLOW.ps1            sélecteur + construction des sessions
├─ FLOW.cmd            lanceur double-clic
├─ config/psmux.conf   config psmux de FLOW (couleurs, barre d'état)
├─ profiles/*.json     un fichier par profil
├─ tools/
│  ├─ claude-monitor.ps1   moniteur animé
│  └─ statusline.ps1       barre de statut + limites d'utilisation pour le moniteur
└─ assets/flow.ico
```

FLOW utilise un serveur psmux isolé (`psmux -L flow`) : il n'interfère pas avec tes autres
sessions. Pour s'y rattacher à la main : `psmux -L flow attach -t flow-standard`.

## Format d'un profil

```json
{
  "name": "Standard",
  "description": "texte affiché dans le sélecteur",
  "order": 1,
  "session": "flow-standard",
  "window": "claude",
  "cwd": "..",                 // relatif au dossier FLOW → portable
  "account": "principal",      // compte Claude (config\accounts.json) ; aussi possible par panneau
  "rows": [                    // lignes de haut en bas, hauteurs en %
    { "height": 75, "panes": [ // colonnes de gauche à droite, largeurs en %
        { "role": "monitor", "width": 50 },
        { "role": "claude",  "width": 50, "args": "--teammate-mode tmux", "focus": true }
    ]},
    { "height": 25, "panes": [
        { "role": "shell", "width": 50 },
        { "role": "command", "width": 50, "command": "git status", "cwd": "../autre-projet", "title": "▶ git" }
    ]}
  ]
}
```

Rôles : `claude`, `monitor`, `shell`, `command` (exécute `command`).
`title` (facultatif) remplace le titre affiché dans la bordure du panneau.

Le moniteur suit la conversation Claude lancée dans le dossier du profil (et pas celle d'un autre
projet) ; la taille de la fenêtre de contexte (200k / 1M) est détectée automatiquement via la barre de statut.

## Portabilité

Sur une autre machine : copier le dossier, installer `psmux` (`winget install marlocarlo.psmux`),
Claude Code et PowerShell 7, puis `pwsh -File FLOW.ps1 -InstallShortcut`.
Au lancement, FLOW branche `tools/statusline.ps1` dans `settings.json` du compte Claude utilisé
(sauf si une barre de statut personnelle existe déjà).

## Partager des profils (bibliothèques)

Une **bibliothèque** est un endroit commun où l'équipe dépose ses profils. Deux types, déclarés
avec la touche **B** (enregistrés dans `config\sources.json`, propre à chaque machine) :

| Type | Exemple | Fonctionnement |
|---|---|---|
| Dossier partagé | `~\OneDrive - Entreprise\FLOW-profils`, `\\serveur\partage\flow` | lu et écrit directement |
| Dépôt Git | `https://github.com/mon-equipe/flow-profils` | cloné dans `config\sources-cache\`, mis à jour au lancement du sélecteur et avec **R** ; publier = commit + push. Les profils sont lus dans `profiles\` s'il existe, sinon à la racine. |

Dans le sélecteur, les profils des bibliothèques apparaissent sous **⇄ partagés**, avec leur auteur.

- **P** publie le profil sélectionné. La version publiée est *portable* : sans dossier de travail
  (remplacé par un indice, ex. « boutique »), sans nom de session, ordre ni `claudeConfigDir`, sans
  chemins absolus dans les panneaux. Disposition, rôles, comptes (par identifiant), arguments,
  commandes et titres sont gardés. Si le nom existe déjà : remplacer ou publier sous un autre nom.
- **Entrée** lance un profil partagé. La première fois, FLOW demande le dossier de travail sur
  ta machine (il en propose un s'il trouve un dossier du même nom) et le retient
  (`config\shared-local.json` ; **O** pour le changer). Un compte inconnu chez toi
  (ex. `second` alors que tu n'as qu'un compte) est remplacé par ton compte par défaut.
- **D** sur un profil partagé en fait **ta copie** locale, modifiable (E, F2, réordonner…).
  Les profils partagés eux-mêmes ne s'éditent pas sur place : republie avec **P**.
- **Suppr** (×2) retire le profil de la bibliothèque, pour tout le monde (dossier : **U** annule ;
  dépôt Git : le retrait est poussé).

Pour un dépôt Git privé, chacun doit y avoir accès (invitation sur GitHub) ; la connexion se fait
avec le gestionnaire d'identifiants de Git ou `gh auth login` puis `gh auth setup-git`.

## Équipe : un prompt, plusieurs Claude en parallèle

Profil **Équipe — multi-comptes** (`profiles\equipe.json`) : à gauche la fenêtre Équipe, à droite le moniteur.

1. **Demande** : tu écris ton prompt (Entrée = nouvelle ligne, **F5** ou **Ctrl+D** = envoyer).
2. **Plan** : un Claude planificateur (compte le moins chargé, lecture seule) explore le projet et propose
   des tâches : fichiers attribués, dépendances, critères de fin, plus un *brief* commun (contexte, conventions,
   décisions partagées). Tu peux changer le compte d'une tâche (**Tab**), modifier le plan (**E**),
   demander un autre découpage (**R**), puis lancer (**Entrée**).
3. **Ouvriers** : chaque tâche part dans un vrai Claude interactif, dans la fenêtre psmux « equipe »
   (`Ctrl+B 2` ; `Ctrl+B 1` pour revenir). Chacun a **sa copie du projet** (git worktree, branche
   `flow/<id>/<tâche>`) : même code de départ, mêmes `CLAUDE.md` / réglages, aucun mélange possible.
   Une tâche qui dépend d'une autre démarre de sa branche, une fois celle-ci finie.
   Bordure / tableau : `● travaille`, `✋ attend ta réponse` (+ notification), `✓ terminée`.
4. **Intégration** : les branches sont fusionnées dans une branche d'intégration (jamais directement chez toi).
   En cas de conflit : **C** lance un Claude intégrateur qui le résout. Les tests du projet sont lancés
   s'ils sont détectés (npm, pytest, cargo, go, dotnet) ou indiqués par `"testCommand"` sur le panneau.
5. **Validation** : résumé des changements, tests, comptes-rendus des ouvriers. **D** voir le diff,
   **F** fusionner dans ta branche, **J** jeter. Après fusion, copies et branches temporaires sont supprimées.

**Modèles** : le planificateur (Opus) choisit pour chaque tâche le modèle adapté — *haiku* pour le simple et
mécanique, *sonnet* pour le standard, *opus* pour le complexe — avec sa justification ; **M** dans le plan
pour le changer. Chaque ouvrier démarre avec `claude --model <modèle>`.

**Conseiller** : chaque ouvrier a un conseiller, un modèle un cran au-dessus (haiku → sonnet, sonnet/opus → opus),
appelé quand la tâche se complique :
- l'ouvrier écrit sa question dans `aide\<tâche>.md` (ses consignes le lui expliquent) ;
- ou il enchaîne 3 erreurs d'outils (au plus un appel automatique toutes les 5 min) ;
- ou tu appuies sur **C** dans le tableau de bord.
Le conseiller (lecture seule) étudie la fiche, l'historique et le diff de l'ouvrier, écrit son diagnostic et un
plan dans `conseils\<tâche>.md`, et l'ouvrier reçoit un message dans son panneau. **M** dans le tableau de bord
écrit directement à un ouvrier.

Communication entre Claude : par fichiers, dans `.flow\runs\<id>\` (exclu de Git) — `BRIEF.md`,
`taches\<X>.md` (fiche de chaque ouvrier), `resultats\<X>.md` (compte-rendu, qui signale aussi la fin).
Une équipe interrompue se reprend au prochain lancement.

Prérequis : **Git**, et un projet sous Git (sinon la fenêtre propose `git init` + premier commit).

### Sur n'importe quel projet

```powershell
pwsh -File FLOW.ps1 -Team C:\chemin\du\projet     # une session Équipe par projet (plusieurs en même temps)
```

Ou, dans la fenêtre Équipe : **F3** pour changer de projet (liste des projets récents).

### S'adapter au workflow du projet : `.flow\config.json`

Au premier passage dans un projet, l'outil **détecte son workflow** et te le montre pour validation :

| Réglage | Détecté depuis | Utilisé pour |
|---|---|---|
| `setup` | lockfiles (npm/pnpm/yarn/bun, uv/poetry, composer, bundler…) | préparer chaque copie neuve, visiblement, avant Claude |
| `copyFiles` | fichiers locaux ignorés par Git (`.env`, `*.local`…) | recopiés dans chaque copie (jamais commités) |
| `checks` | scripts `package.json`, ruff/mypy/pytest, cargo, go, dotnet, Maven/Gradle, Makefile | consignes des ouvriers + vérifications sur la branche d'intégration |
| `branchPrefix` | branches existantes (`feature/`, `feat/`…) | noms des branches de l'équipe |
| `commitStyle` | historique (Conventional Commits ou libre) | messages des ouvriers et commit final |
| `deliver` | historique et remote (pull requests GitHub, merges, linéaire) | livraison : `merge`, `squash`, `pr` (gh), `branch` |
| `targetBranch` | — (vide = branche actuelle) | point de départ et cible de la livraison |
| `instructions` | — | règles du projet transmises à chaque Claude |

Dans l'écran du profil (**F2** depuis l'accueil) : **A** demande à Claude de lire README, CONTRIBUTING,
CLAUDE.md et la CI pour compléter le profil (commandes réelles, règles du projet) ; **L** change le mode de
livraison ; **E** édite le JSON. Le fichier peut être **commité** pour être partagé avec le projet
(seul `.flow\runs\` est exclu de Git). Un `CLAUDE.md` dans le projet aide beaucoup les ouvriers.

Options du panneau `team` dans un profil FLOW : `maxTasks`, `testCommand` (remplace les vérifications),
`workerArgs` (par défaut `--permission-mode acceptEdits` : chaque ouvrier est isolé dans sa copie).

## Plusieurs comptes Claude

Les comptes sont déclarés dans `config\accounts.json` :

```json
{ "accounts": [
  { "id": "principal", "label": "Compte 1", "short": "C1", "dir": null,                "color": "#ff8a5c", "enabled": true },
  { "id": "second",    "label": "Compte 2", "short": "C2", "dir": "~/.claude-compte2", "color": "#54baff", "enabled": true }
]}
```

- `dir: null` = compte par défaut (`~\.claude`) ; sinon le dossier passé à Claude via `CLAUDE_CONFIG_DIR`
  (identifiants, réglages et historique de ce compte y sont rangés, séparés du compte principal).
  Garde ce dossier **hors** du dossier FLOW pour ne pas copier tes identifiants avec FLOW.
- **Connexion** : dans le sélecteur, touche **C** → choisir le compte → Entrée. Une fenêtre Claude s'ouvre
  avec ce compte : connecte-toi (ou `/login`), puis `/exit`. En ligne de commande : `pwsh -File FLOW.ps1 -Login second`.
- **Choisir le compte** : `"account": "second"` sur un profil (tous ses panneaux) ou sur un panneau précis.
  Le profil **Duo — 2 comptes** (`profiles\duo.json`) ouvre un Claude par compte côte à côte.

**Moniteur partagé** : dans chaque profil, le moniteur affiche un panneau COMPTES avec, pour chaque compte
activé, son état (travaille / en attente / non connecté), son contexte et ses limites semaine / session.
Le détail (contexte, outils) suit le compte actif en dernier ; `Tab` dans le moniteur choisit le compte détaillé,
`A` revient au choix automatique. Le flux d'activité mélange les deux comptes, chaque ligne marquée d'une barre
à la couleur de son compte. Pour un moniteur limité aux comptes du profil : `"allAccounts": false` sur le panneau moniteur.

FLOW branche `tools\statusline.ps1` dans le `settings.json` de chaque compte (sauf barre de statut perso) :
c'est elle qui transmet les limites d'utilisation au moniteur. Elles apparaissent après la première réponse de Claude.

L'ancien champ `claudeConfigDir` d'un profil fonctionne toujours.
