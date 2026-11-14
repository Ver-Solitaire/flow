# FLOW — Claude × psmux

Lanceur portable : un sélecteur de profils animé qui recrée tes espaces de travail psmux
(Claude, moniteur, terminaux) en un clic — avec plusieurs comptes Claude, une équipe de Claude qui se
partage une demande, et un « Bureau » où chaque agent est un petit personnage animé.

## Installation (nouvelle machine, Windows)

1. Récupère le dossier (`git clone …` ou téléchargement ZIP).
2. **Double-clique sur `install.cmd`.** Il fonctionne même sans PowerShell 7 : il vérifie chaque outil **et sa version**,
   installe ou met à jour ce qui manque avec `winget`, **revérifie ensuite chaque outil lui-même** (et pas seulement le code de sortie de winget),
   puis crée `config\accounts.json`, le raccourci « FLOW » sur le bureau, propose de configurer l'identité Git et de te connecter à Claude.
   Il ne dit « FLOW est prêt » que si tout ce qui est obligatoire est là (code de sortie 0) ; sinon il liste ce qui manque et ce qu'il faut taper.
   Si un outil vient d'être installé mais reste invisible, il te demande de fermer et rouvrir la fenêtre (le `PATH` a changé), puis de relancer `install.cmd`.
   (`install.cmd -Check` : **vérifie sans rien modifier** · `install.cmd -Yes` : sans questions · `install.cmd -WithGitHubCli` : ajoute GitHub CLI.)
3. Lance FLOW avec le raccourci du bureau. Pour découvrir sans rien risquer :
   `pwsh -File FLOW.ps1 -Demo` (Bureau et moniteur) et `pwsh -File FLOW.ps1 -TeamDemo` (fenêtre Équipe)
   et `pwsh -File FLOW.ps1 -ShareDemo` (profils partagés : deux bibliothèques, un collègue qui publie pendant la démo).

Prérequis : Windows 10/11 avec `winget` (« App Installer » du Microsoft Store).

### Dépendances

La liste, les versions minimales et les commandes d'installation vivent à **un seul endroit** : [`dependances.json`](dependances.json)
(lu par `install.cmd`, par `-Doctor`, par `tests\run.ps1` et par tous les messages « … est introuvable »). Ce tableau en est généré :
`pwsh -File tools\flow-deps.ps1 -UpdateReadme` le met à jour, et un test échoue s'il diverge.

<!-- DEPENDANCES:DEBUT -->
| Outil | Nécessaire | À quoi il sert | Version minimale |
|---|---|---|---|
| PowerShell 7 | oui | FLOW et tous ses écrans tournent sous PowerShell 7 | 7.2 (essayé avec 7.7.0) |
| psmux | oui | les sessions, les fenêtres et les panneaux (tmux pour Windows) | 3.4.0 (essayé avec 3.4.0) |
| Claude Code | oui | les Claude des panneaux et de l'équipe (options --permission-mode, --add-dir, --allowedTools, --output-format, --append-system-prompt, claude auth login ; --teammate-mode des profils n'apparaît pas dans l'aide de cette version) | 2.1.318 (essayé avec 2.1.318) |
| Git | oui | la fenêtre Équipe : une copie de travail par tâche (git worktree), fusions, livraison | 2.17 (essayé avec 2.56.0) |
| winget | non : installation | installe les autres outils (install.cmd) | aucune (essayé avec 1.29.380) |
| Windows Terminal | non : recommandé | couleurs et souris dans les écrans de FLOW ; déjà présent sur Windows 11 | - |
| GitHub CLI | non : livraison par pull request | ouvrir une pull request à la livraison d'une équipe (mode « pr ») | aucune (essayé avec 2.104.0) |
| Pester | non : développement | les tests (tests\run.ps1) | série 5 uniquement |
| Compilateur .NET Framework (csc) | non : développement | compile FLOW.exe (sans lui, FLOW reste utilisable avec FLOW.cmd) | - |
<!-- DEPENDANCES:FIN -->

« Essayé avec » = la version utilisée pour valider FLOW ; quand aucune version plus ancienne n'a été essayée, le minimum est cette version-là (voir `min_source` dans `dependances.json`).
Sans PowerShell 7, `FLOW.cmd`, `FLOW.exe` et un `FLOW.ps1` lancé par Windows PowerShell 5.1 disent tous la même chose : **double-clique sur `install.cmd`**.
Sans le compilateur .NET Framework, `FLOW.exe` n'est pas compilé : FLOW reste utilisable avec `FLOW.cmd` (les raccourcis le lancent).

## Dépannage

- **`install.cmd -Check`** (marche sans PowerShell 7, ne modifie rien) et **`pwsh -File FLOW.ps1 -Doctor`** : contrôlent chaque outil et sa version (voir le tableau ci-dessus), puis, pour `-Doctor`, les comptes (connectés ou non, adresse), les fichiers de configuration,
  les sessions ouvertes et les dernières lignes du journal, et dit quoi faire pour chaque point en défaut.
- **Journal** : `config\flow.log` (200 Ko au plus) : transitions des équipes, messages envoyés aux ouvriers, sauvegardes et refus.
- **Tests** : `pwsh -File tests\run.ps1` (Pester **série 5 uniquement** ; téléchargé dans `tests\.modules` s'il manque, en local comme dans la CI). Aucun test ne touche à tes sessions ni à tes comptes.
- Un Claude d'ouvrier qui ne fait rien : ouvre son panneau (fenêtre « equipe », `Ctrl+B 2`) ; s'il attend une autorisation ou une réponse, réponds-lui là.
- Version installée : affichée dans l'en-tête du sélecteur (fichier `VERSION`) ; historique dans `CHANGELOG.md`.
- Architecture : [`docs/MODELE-OSI.md`](docs/MODELE-OSI.md) projette les échanges de FLOW sur les 7 couches du modèle OSI (avec, en annexe, ses couches logicielles internes).

## Lancer

- **Application FLOW** (raccourci bureau et menu Démarrer « FLOW », épinglable à la barre des tâches) :
  une fenêtre liste tes projets (dossiers voisins de FLOW + projets récents, `●` = une session tourne déjà) ;
  Entrée ou double-clic ouvre FLOW **dans ce projet**. Boutons : *Parcourir…*, *Nouveau projet…* (dossier + `git init`),
  *Sans projet*. `FLOW.exe C:\chemin\projet` ouvre directement un projet (pratique pour un raccourci par projet).
  L'application est compilée depuis `app\FlowApp.cs` par `-InstallShortcut` (aucun outil à installer).
- Dans le sélecteur, **J** change de projet. Avec un projet, tous les profils s'ouvrent dans son dossier et leurs
  sessions sont propres au projet (`flow-standard--mon-projet`) : plusieurs projets peuvent tourner en même temps.
- Double-clic sur `FLOW.cmd` : sélecteur sans projet
- En ligne de commande :

```powershell
pwsh -File FLOW.ps1                       # sélecteur
pwsh -File FLOW.ps1 -Open standard        # lance directement un profil
pwsh -File FLOW.ps1 -Open standard -NoAttach   # construit la session en arrière-plan
pwsh -File FLOW.ps1 -Project C:\mon\projet   # sélecteur, profils ouverts dans ce projet
pwsh -File FLOW.ps1 -InstallShortcut      # compile FLOW.exe et (re)crée les raccourcis bureau + menu Démarrer
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
| Q | quitter (Échap ne ferme jamais rien : il efface la recherche ou l'aide) |

> **Session déjà ouverte avec un ancien profil ?** FLOW le détecte au lancement et propose « Garder la session » ou « Reconstruire (ferme la session actuelle) ».


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
| `Ctrl+B` `T` | fenêtre **Équipe** dans n'importe quel profil (Duo, Standard…) : une demande découpée en tâches, réparties sur les comptes Claude (aussi dans le menu `Ctrl+B` `G`) |

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

Sur une autre machine : copier le dossier, double-cliquer sur `install.cmd` (il installe et vérifie psmux, Claude Code, Git et PowerShell 7),
puis `pwsh -File FLOW.ps1 -InstallShortcut`.
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

Profil **Équipe — multi-comptes** (`profiles\equipe.json`) : la fenêtre Équipe, le moniteur, un Claude par compte connecté et le Bureau.

**Une vraie équipe, toujours.** Quelle que soit la demande, même minuscule, les Claude travaillent ensemble :
- une demande qui se découpe est répartie par morceaux ; une demande petite ou indivisible est répartie par **rôles** qui avancent en parallèle
  sur la même chose (réalisateur, testeur qui écrit les tests d'après la spécification, documentation, puis une tâche d'intégration et de
  contre-vérification qui fait passer l'ensemble) ; le brief fixe d'abord les interfaces pour que chacun avance sans attendre ;
- les ouvriers peuvent **s'écrire directement** : une ligne `@B : …` dans leurs annonces est transmise à B seul, une ligne sans `@` à tous ;
- **toutes les permissions sont accordées d'avance** (mode `bypassPermissions`) aux ouvriers et aux Claude du profil Équipe : aucun ne s'arrête pour demander une autorisation, et ils n'appellent l'utilisateur qu'en dernier recours. Chaque ouvrier reste dans sa propre copie du projet, mais ce mode n'a aucun garde-fou : pour revenir à des demandes de permission, mets `workerArgs` (panneau `team`) et `args` (panneau `claude`) à `--permission-mode auto` dans `profiles\equipe.json` ;
- le plan **démarre tout seul après 20 secondes** s'il est sans risque (aucun fichier partagé, comptes connectés) ; une touche rend la main
  (`"autoStart": 20` sur le panneau `team` du profil, `0` pour toujours attendre) ;
- les Claude ordinaires des panneaux confient eux aussi toute demande de travail à l'équipe (skill `taches-repartir`) ;
- rien n'arrive dans ton projet sans ta validation finale.

**Voir ce que les Claude s'échangent.** Le panneau **⇄ échanges** du profil Équipe affiche en direct qui parle à qui, dans la couleur de chaque
compte (`C1·A` = la tâche A, sur le compte C1) : tâches confiées, messages directs (`@B : …`), annonces, fins de tâche, **relectures croisées**
(avec les points à corriger), conseils et tes propres messages. Les mêmes lignes sont conservées dans `.flow\runs\<équipe>\echanges.jsonl`.
Le panneau est un rôle de profil comme les autres : `{ "role": "exchanges" }`.

1. **Demande** : tu écris ton prompt (Entrée = nouvelle ligne, **F5** ou **Ctrl+D** = envoyer).
2. **Plan** : un Claude planificateur (compte le moins chargé, lecture seule) explore le projet et propose
   des tâches : fichiers attribués, dépendances, critères de fin, plus un *brief* commun (contexte, conventions,
   décisions partagées). Les tâches sont réparties entre les comptes **connectés** (le moins chargé d'abord).
   Tu peux changer le compte d'une tâche (**Tab**), refaire la répartition (**A**), connecter un compte
   manquant sans quitter l'écran (**C**, ou **F4** depuis l'écran de demande), modifier le plan (**E**),
   demander un autre découpage (**R**), puis lancer (**Entrée**). Une tâche confiée à un compte non connecté
   bloque le lancement tant qu'elle n'est pas réattribuée ou le compte connecté.
3. **Ouvriers** : chaque tâche part dans un vrai Claude interactif, dans la fenêtre psmux « equipe »
   (`Ctrl+B 2` ; `Ctrl+B 1` pour revenir). Chacun a **sa copie du projet** (git worktree, branche
   `flow/<id>/<tâche>`) : même code de départ, mêmes `CLAUDE.md` / réglages, aucun mélange possible.
   Une tâche qui dépend d'une autre démarre de sa branche, une fois celle-ci finie.
   Bordure / tableau : `● travaille`, `✋ attend ta réponse` (+ notification), `✓ terminée`.
   **Synchronisation** : FLOW tient à jour un tableau partagé (`TABLEAU.md` : qui fait quoi, ce qui est fini,
   où lire le travail des autres). Un ouvrier qui prend une décision touchant les autres l'écrit dans
   `annonces\<tâche>.md` : FLOW la relaie aussitôt dans les panneaux des autres ouvriers, comme la fin de chaque tâche.
   **Relecture croisée** : dès qu'un ouvrier a fini, un Claude d'un **autre compte** relit son travail (diff,
   fiche, brief, raccord avec les autres tâches). S'il trouve un problème bloquant ou important, il est renvoyé
   à l'ouvrier, qui corrige et resoumet (2 relectures au plus par tâche ; `relectures\<tâche>.md`). Une tâche
   n'est « terminée » — et les tâches qui en dépendent ne démarrent — qu'une fois relue. **V** active ou coupe
   la relecture (écran du plan ou du suivi) ; `"review": false` sur le panneau `team` la désactive par défaut.
4. **Intégration** : les branches sont fusionnées dans une branche d'intégration (jamais directement chez toi).
   En cas de conflit : **C** lance un Claude intégrateur qui le résout. Les tests du projet sont lancés
   s'ils sont détectés (npm, pytest, cargo, go, dotnet) ou indiqués par `"testCommand"` sur le panneau.
5. **Validation** : résumé des changements, tests, comptes-rendus des ouvriers. **D** voir le diff,
   **F** fusionner dans ta branche, **J** jeter (écran de confirmation, touche **O**). Rien n'est perdu : avant de supprimer les copies et
   les branches temporaires, FLOW sauvegarde les fichiers non commités et met de côté, sous `refs/flow-archive/<équipe>/<tâche>`, toute tâche qui n'est
   pas dans le travail livré (ou toute l'équipe si tu la jettes). Pour en retrouver une : `git branch recup refs/flow-archive/<équipe>/<tâche>`.
   Si une tâche reste à l'écart (conflit abandonné, commit impossible), FLOW te le dit avant de livrer ; la livraison est refusée quand rien n'a été fusionné.

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

### Qualité : passe légère ou complète, contre-vérification, juge, mémoire

- **Passe** : le planificateur choisit la passe de contrôle. *Légère* (petite modification sans risque) : relecture sur 2 angles, ni contre-vérification ni juge. *Complète* (logique, données, plusieurs modules) : tout ce qui suit. **P** dans l'écran du plan pour changer.
- **Relecture croisée sur 5 angles** : conformité à la fiche, non-régression, données et cas limites, logique, raccord avec les autres tâches. Chaque problème doit venir avec un scénario concret.
- **Contre-vérification** (passe complète) : chaque problème grave est confié à un autre Claude qui essaie de le **réfuter**. Seuls ceux qui résistent sont renvoyés à l'ouvrier ; `relectures\<tâche>.md` garde le détail (confirmé / réfuté, et pourquoi).
- **Juge final** (passe complète) : un Claude vérifie le résultat contre la demande, le « terminé quand » de chaque tâche et les vérifications du projet, et **revérifie lui-même au moins un fait**. Son verdict s'affiche à l'écran « à valider » ; s'il n'est pas convaincu, FLOW demande une confirmation avant de livrer.
- **Garde-fous** transmis à chaque Claude de l'équipe : rien en ligne ni envoyé sans accord, rien supprimé sans comprendre, aucun secret, aucun contournement de test ou de permission, comptes rendus honnêtes (un test non lancé est « non lancé »), plus petite modification qui règle complètement le besoin. Dans `.flow\config.json` : `guardrails` (règles en plus) et `protectedPaths` (chemins de données réelles : si l'équipe en modifie un, une vérification « fichiers protégés » échoue).
- **Mémoire du projet** : **G** dans l'écran du profil crée `CLAUDE.md` et le dossier `memoire\` (`INDEX.md`, état actuel, décisions, pièges, historique) ; à commiter. À la fin de chaque équipe, un **scribe** met ces fiches à jour (il remplace l'ancien état, ajoute les pièges rencontrés et une ligne d'historique) et son commit part avec la livraison. Il ne touche à rien d'autre que `memoire\`.
- Interrupteurs dans `.flow\config.json` : `"verify": false`, `"judge": false`, `"scribe": false`.

### Mode guidé (F7 sur l'écran de demande)

Pour obtenir exactement le résultat voulu, **FLOW te pose des questions à chaque étape** au lieu de décider seul. Le réglage est retenu d'un lancement à l'autre (`config\team-prefs.json`, jamais commité).

1. **Avant le plan** : un *guide* (Claude, lecture seule) étudie ton projet et ta demande, puis te pose 4 à 8 questions sur **comment** y arriver : objectif et public, à quoi on reconnaît que c'est réussi, contraintes, choix de conception et leurs conséquences, périmètre, priorités, façon de vérifier. Un second tour (4 questions au plus) ne porte que sur ce qui reste ouvert. Il ne demande jamais ce qui se lit dans le code ou le CLAUDE.md.
2. **Au plan** : le planificateur te soumet les vraies décisions de conception encore ouvertes. Si tu t'écartes de sa recommandation, **le plan est refait** en la respectant (une seule fois).
3. **Pendant le travail** : chaque ouvrier **te pose la question** dans son panneau avant un choix qui change le résultat (structure, nom public, format, comportement visible, contenu), avec 2 ou 3 options et sa recommandation, puis attend ta réponse. Le tableau de bord affiche « ✋ attend ta réponse ». Les détails mineurs, il les décide seul.
4. **À la validation** : en appuyant sur **F**, FLOW demande « c'est bien ce que tu voulais ? » : **oui** (livrer), **presque** (une nouvelle équipe repart de ce travail avec ton retour) ou **non** (on refait avec ton retour). Ton retour est gardé dans `retours.md`.

Pour chaque question : **↑↓ ou 1-4** pour choisir (ou clic), **Entrée** pour valider, **T** pour répondre avec tes mots, **S** pour dire « décide à ma place » (la recommandation est prise), **←** pour revenir à la question précédente, **Échap** pour passer les questions. Tes réponses sont dans `precisions.md` de l'équipe et dans son brief : tous les Claude les voient. Le lancement automatique du plan est désactivé en mode guidé.

### Mémoire de ta façon de travailler (F8)

FLOW apprend **comment tu travailles** et en garde une mémoire **locale**, pour que les prochains Claude t'aident mieux sans te redemander ce que tu as déjà montré. Rien n'est envoyé ailleurs : tout est dans `%LOCALAPPDATA%\FLOW\profil\`, hors de tes projets et de Git.

| Fichier | Contenu |
|---|---|
| `profil.md` | le **profil** en langage naturel : comment tu décides, demandes, ce que tu corriges, ton rythme, ce qu'il faut proposer ou éviter, et ce qu'on ignore encore. Chaque affirmation indique sa confiance (« observé 5 fois », « une seule fois : hypothèse ») ; ce qui est démenti est remplacé. |
| `evenements.jsonl` | le **journal d'activité** : tes demandes, tes réponses aux questions guidées, les changements que tu apportes aux plans, tes messages aux ouvriers, tes retours « presque / non », les livraisons et abandons, le verdict du juge, le quota des comptes avant et après, et pour chaque appel Claude son modèle, sa durée, ses jetons et son coût. |
| `conversations\` | une copie des **conversations des Claude** de chaque équipe (jetons, outils et interventions sont aussi relevés), **secrets masqués** (clés d'API, jetons, mots de passe). |

À la fin de chaque équipe (livrée, jetée ou à ajuster), un Claude met le profil à jour à partir des nouveaux événements. Le profil est ensuite transmis au planificateur, au guide et aux ouvriers comme **hypothèses** (ils ne le citent pas, tu gardes le dernier mot) ; le guide s'en sert pour ne pas redemander ce qu'il sait déjà.

L'écran **F8** (depuis l'écran de demande) montre où ça en est (nombre d'événements, usage, taille des conversations) et permet de **lire** le profil (**L**), le **mettre à jour** (**R**), l'**éditer** à la main (**E**), **ouvrir** le dossier (**O**), **couper** le journal (**C**), les conversations (**V**) ou la transmission du profil aux Claude (**I**), et **tout effacer** (**X**, avec confirmation). Les données sont lisibles : à toi de les exploiter (Excel, scripts…).

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
| `guardrails` | — | règles de sécurité en plus des garde-fous de base |
| `protectedPaths` | — | chemins de données réelles que l'équipe ne doit pas modifier (vérification « fichiers protégés ») |

Dans l'écran du profil (**F2** depuis l'accueil) : **A** demande à Claude de lire README, CONTRIBUTING,
CLAUDE.md et la CI pour compléter le profil (commandes réelles, règles du projet) ; **L** change le mode de
livraison ; **E** édite le JSON. Le fichier peut être **commité** pour être partagé avec le projet
(seul `.flow\runs\` est exclu de Git). Un `CLAUDE.md` dans le projet aide beaucoup les ouvriers.

Options du panneau `team` dans un profil FLOW : `maxTasks`, `testCommand` (remplace les vérifications),
`workerArgs` (par défaut `--permission-mode acceptEdits` : chaque ouvrier est isolé dans sa copie).

## Skills : créer, reprendre, maintenir un projet, répartir les tâches

FLOW livre quatre skills Claude Code (dossier `skills\`) et les installe dans **chaque compte** Claude
(`<compte>\skills\`) à chaque lancement de profil : ils sont donc disponibles dans tous les projets, sans rien
ajouter au projet lui-même. Claude les utilise de lui-même quand la demande s'y prête ; on peut aussi les
appeler par leur nom (`/projet-creer`…).

| Skill | Quand | Ce qu'il fait |
|---|---|---|
| `projet-creer` | « crée-moi un projet / une appli / un site… » | choisit des outils simples et répandus selon le type de projet (web, API, ligne de commande, script, mobile, jeu, données, sans code…), construit un socle qui tourne (structure, test, README, `CLAUDE.md`, Git), vérifie en le lançant |
| `projet-reprendre` | « explique-moi ce projet », « fais le point » | explore sans rien modifier, fait tourner le projet et ses tests, écrit `CLAUDE.md`, rend un état des lieux classé par gravité |
| `projet-maintenir` | « mets à jour », « fais le ménage », « prépare une version » | dépendances, sécurité, tests cassés, nettoyage, documentation, version — par petites étapes vérifiées, un commit chacune, rien de publié sans accord |
| `taches-repartir` | « répartis le travail », « fais travailler les autres comptes » | Claude découpe la demande en tâches indépendantes et dépose le plan dans la fenêtre Équipe (`tools\flow-plan.ps1`) ; tu y vérifies comptes et modèles puis tu lances |

- Modifier un skill : édite `skills\<nom>\SKILL.md`, il est recopié au prochain lancement
  (ou tout de suite : `pwsh -File FLOW.ps1 -InstallSkills`).
- Un skill du même nom que tu aurais créé toi-même dans un compte n'est jamais remplacé.
- Dans la fenêtre Équipe, **F6** (écran de demande) affiche les plans en attente déposés par `taches-repartir`.

## Plusieurs comptes Claude

> **À lire avant de cumuler des comptes.** FLOW est un projet indépendant, **non affilié à Anthropic**. Il ne fait que lancer plusieurs
> fois Claude Code, chacun avec son propre dossier de connexion. Il ne contourne aucune limite d'usage et ne partage aucun identifiant
> entre comptes. Les conditions d'utilisation d'Anthropic s'appliquent à chaque compte : **vérifie qu'elles autorisent l'usage que tu veux en
> faire** (par exemple, plusieurs comptes à ton nom pour additionner des quotas). Un seul compte suffit pour utiliser FLOW, et la
> répartition en équipe marche aussi avec un seul compte. Deux « comptes » connectés avec la même adresse ne comptent que pour un : FLOW te le signale.
> Dans les panneaux de FLOW, les variables `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` et `CLAUDE_CODE_OAUTH_TOKEN` sont retirées, pour qu'un compte
> utilise bien sa propre connexion et pas une clé d'API héritée.

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
- **Connexion au lancement** : quand un profil utilise plusieurs comptes (Duo, Équipe…) et que l'un d'eux n'est
  pas connecté, FLOW affiche la liste des comptes avant d'ouvrir la session. Entrée sur un compte lance sa
  connexion **dans la même fenêtre** (`claude auth login` : lien à ouvrir, code à coller) ; dès que tous sont
  connectés, le profil se lance. « Lancer maintenant » passe outre.
  Si ton navigateur est déjà connecté à un autre compte, ouvre le lien dans une fenêtre privée.
- **Autant de comptes que tu veux** : touche **C** → « ＋ ajouter un compte Claude… » (aussi proposé à l'écran de
  lancement du profil Équipe). FLOW crée l'entrée dans `accounts.json` (dossier `~\.claude-compteN`) et enchaîne
  sur la connexion. Le profil Équipe répartit les tâches sur tous les comptes connectés et ouvre un Claude par compte.
- **Retirer un compte** : touche **C** → « － retirer un compte… » (aussi proposé à l'écran de connexion). Au choix : retirer **et déconnecter** le compte,
  ou le retirer de FLOW seulement. Le dossier du compte n'est jamais supprimé ; le compte par défaut de Claude Code ne se retire pas. Les profils qui
  utilisaient le compte retiré sont signalés : ils ne se lancent plus tant qu'ils n'ont pas été modifiés (touche E).
- **À la sélection du projet**, FLOW vérifie tout de suite les comptes (connectés ? deux comptes avec la même adresse ?) et propose de les corriger.
- **Connexion à tout moment** : dans le sélecteur, touche **C** → choisir le compte → Entrée.
  En ligne de commande : `pwsh -File FLOW.ps1 -Login second`.
- `"email": "moi@exemple.com"` (facultatif) sur un compte préremplit l'adresse sur la page de connexion.
- **Les comptes ne sont liés à aucun profil.** Connecte (ou ajoute) autant de comptes que tu veux, une fois, à la sélection du projet : les profils
  **Équipe — multi-comptes** et **Un Claude par compte** ouvrent alors automatiquement **un Claude par compte connecté**, et la fenêtre Équipe répartit
  les tâches sur eux tous. Dans un profil, un panneau `{ "role": "claude", "perAccount": true }` est remplacé au lancement par un panneau par compte
  connecté (sans compte connecté : un seul, sur le compte par défaut). Ctrl+B W réenregistre ce panneau sous sa forme d'origine.
- **Ajouter un Claude à tout moment** (par exemple un second Claude du même compte, ou un compte connecté après le lancement) : `Ctrl+B` puis `A`,
  ou clic droit sur un panneau → « ＋ Ajouter un Claude : <compte> » : un nouveau panneau Claude s'ouvre à côté du panneau actif, sur ce compte.
- **Forcer un compte** : `"account": "second"` sur un profil (tous ses panneaux) ou sur un panneau précis (écrase `perAccount`).

**Moniteur partagé** : dans chaque profil, le moniteur affiche un panneau COMPTES avec, pour chaque compte
activé, son état (travaille / en attente / non connecté), son contexte et ses limites semaine / session.
Le détail (contexte, outils) suit le compte actif en dernier ; `Tab` dans le moniteur choisit le compte détaillé,
`A` revient au choix automatique. Le flux d'activité mélange les deux comptes, chaque ligne marquée d'une barre
à la couleur de son compte. Pour un moniteur limité aux comptes du profil : `"allAccounts": false` sur le panneau moniteur.

FLOW branche `tools\statusline.ps1` dans le `settings.json` de chaque compte (sauf barre de statut perso) :
c'est elle qui transmet les limites d'utilisation au moniteur. Elles apparaissent après la première réponse de Claude.

L'ancien champ `claudeConfigDir` d'un profil fonctionne toujours.
