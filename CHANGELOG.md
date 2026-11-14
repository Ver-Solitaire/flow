# Journal des changements

## Non publié

**Essayé avec** : PowerShell 7.7.0 · psmux 3.4.0 · Claude Code 2.1.318 · Git 2.56.0 · Pester 5.9.1.

### Workflow du projet (livraison 1)
- **Un workflow par projet**, créé avec toi au premier lancement (ou par **W** dans le profil) : FLOW étudie le projet, te pose 6 à 8 questions sur ce que le code ne dit pas, écrit un brouillon, puis te le fait valider (Entrée, **E** pour modifier, **R** pour refaire avec une précision). Inspiré du workflow d'un gros projet : cahier de règles et feuille de route d'étapes.
- **`.flow\workflow\`** : `CAHIER.md` (vision, règles décidées, interdits, données à protéger, critère de réussite mesurable), `ROADMAP.md` (tableau d'étapes et de leur état, lu et écrit par FLOW), `workflow.json`, `archives\` (rien n'est perdu quand on refait). Les commandes de vérification, les chemins protégés et les garde-fous restent dans `.flow\config.json` : une seule source.
- Le cahier et l'étape en cours sont **transmis au planificateur, au guide, aux ouvriers et aux relecteurs**, seulement une fois le workflow **validé**.
- Les interdits sont toujours écrits comme des interdits (« Ne jamais… » ou « À ne jamais faire : … ») pour ne pas être pris pour des ordres.
- Le garde-fou contre les variables qui masquent une couleur (`$r` / `$R`) surveille maintenant aussi les modules chargés dans la fenêtre Équipe : un `$r` dans l'écran du workflow rendait l'affichage illisible sans qu'aucun test ne le voie.

## 1.4.0 — 14 novembre 2026

**Essayé avec** : PowerShell 7.7.0 · psmux 3.4.0 · Claude Code 2.1.318 · Git 2.56.0 · Pester 5.9.1 (les versions des anciennes éditions n'ont pas été consignées).

### Dépendances
- **Une seule déclaration** : `dependances.json` (nom, commande, identifiant winget, obligatoire ou non, rôle, version minimale et son origine, version essayée). `install.cmd`, `-Doctor`, `tests\run.ps1` et tous les messages « … est introuvable » la lisent ; le tableau du README en est généré. Un test échoue si un identifiant winget est recopié ailleurs.
- **Versions minimales contrôlées** par l'installation et le diagnostic (version trouvée, attendue, commande de mise à jour). Minimums : PowerShell 7.2 (`$PSStyle`), Git 2.17 (`git worktree remove`) ; psmux 3.4.0 et Claude Code 2.1.318 = versions essayées (aucune version plus ancienne n'a été essayée).
- **`install.cmd -Check`** : vérifie sans rien modifier, sous Windows PowerShell 5.1.
- **Une installation qui ne ment pas** : chaque outil est revérifié après winget (et non le seul code de sortie) ; « FLOW est prêt » n'apparaît que si tout l'obligatoire est là, code de sortie 1 sinon ; un outil installé mais encore invisible demande de rouvrir la fenêtre ; le `PATH` est complété et non plus remplacé.
- **Sans PowerShell 7** : `FLOW.cmd`, `FLOW.exe` et `FLOW.ps1` (lancé par Windows PowerShell 5.1) disent tous « double-clique sur install.cmd » ; `FLOW.ps1` est désormais en UTF-8 avec BOM, sans quoi 5.1 le lisait en ANSI et échouait avec 123 erreurs de syntaxe.
- **Pester borné à la série 5** : les tests tournaient en réalité sous Pester 6.2.0 (minimum sans maximum, tri des versions comme du texte) ; `tests\run.ps1` compare maintenant des versions et refuse hors série 5, en local comme dans la CI.
- **FLOW.exe sans compilateur** : le dit, et renvoie vers `FLOW.cmd` (les raccourcis le lancent).

### Ajouté- **Mémoire de ta façon de travailler** (F8) : journal d'activité local (demandes, réponses guidées, changements de plan, retours, livraisons, usage et coût de chaque appel Claude, quota des comptes), copie des conversations des Claude avec secrets masqués, et **profil de travail** en langage naturel mis à jour à la fin de chaque équipe puis transmis aux Claude comme hypothèses. Tout reste sur le PC (`%LOCALAPPDATA%\FLOW\profil\`) ; chaque partie se coupe, et tout s'efface depuis l'écran.

## 1.3.0 — 14 novembre 2026

### Ajouté
- **Mode guidé** (F7 sur l'écran de demande) : FLOW pose des questions avant le plan (guide), pour les décisions du plan (plan refait si tu t'écartes de la recommandation), via chaque ouvrier pendant le travail, et à la validation (« c'est bien ce que tu voulais ? » : livrer, ajuster ou refaire avec ton retour).
- Un clic sur une aide « F4 », « F6 », « F7 »… donne la bonne touche (avant : la lettre f).

## 1.2.0 — 14 novembre 2026

### Ajouté
- **Passe légère ou complète** choisie par le planificateur (P pour changer) : la complète fait relire sur 5 angles, contre-vérifier chaque problème grave et juger le résultat.
- **Contre-vérification** : un autre Claude essaie de réfuter chaque problème signalé en relecture ; seuls les problèmes qui résistent sont renvoyés à l'ouvrier.
- **Juge final** : verdict sur le résultat (critères, vérifications, un fait revérifié) affiché à la validation ; confirmation avant de livrer s'il n'est pas convaincu.
- **Garde-fous** transmis à chaque Claude, réglages `guardrails` et `protectedPaths` (vérification « fichiers protégés »).
- **Mémoire du projet** (`memoire\` : INDEX, état actuel, décisions, pièges, historique) créée avec le CLAUDE.md (touche G) et tenue à jour par un **scribe** à la fin de chaque équipe.

## 1.1.0 — 13 novembre 2026

### Ajouté
- **Session obsolète détectée** : une session ouverte avec un ancien profil (ou avant l'ajout d'un compte) est comparée au profil actuel ; FLOW propose de la garder ou de la reconstruire.
- **Échap ne ferme jamais rien** : dans la fenêtre Équipe il revient d'un niveau (à l'accueil il ne fait rien) ; dans le plan il ne détruit plus le plan (X pour l'abandonner) ; dans le sélecteur, Q quitte.
- **Fil d'étapes et ligne « À toi »** sur chaque écran de l'Équipe ; **V** lit le résultat dans une fenêtre où la molette défile.
- **Connexion des comptes au lancement** : un profil à plusieurs comptes propose de connecter ceux qui manquent, dans la même fenêtre ; ajout de comptes à volonté (touche C).
- **Équipe de Claude synchronisée** : tableau partagé, annonces relayées entre ouvriers, **relecture croisée** par un Claude d'un autre compte avant la fusion.
- **Skills** installés dans chaque compte : projet-creer, projet-reprendre, projet-maintenir, taches-repartir (+ `tools\flow-plan.ps1`, Ctrl+B T).
- **Application FLOW.exe** avec choix du projet ; raccourcis qui ne dépendent plus d'un chemin de Windows Terminal.
- **`FLOW.ps1 -Doctor`** : diagnostic (outils, comptes, fichiers, sessions, journal) ; journal `config\flow.log`.
- **Tests** (Pester 5, `tests\run.ps1`) et garde-fous contre les pièges PowerShell déjà rencontrés ; `VERSION`, `CLAUDE.md`.

- **Les comptes ne sont plus liés aux profils** : les profils « Équipe — multi-comptes » et « Un Claude par compte » ouvrent un Claude par compte connecté
  (`"perAccount": true`) ; bouton « ＋ Ajouter un Claude » (Ctrl+B A, clic droit) ; les Claude répartissent d'eux-mêmes ce qui se découpe.
- Écran des comptes à la sélection du projet (connexion, doublons d'adresse, retrait d'un compte) ; CLAUDE.md de départ créé pour n'importe quel projet.

- **Équipe autonome** : toujours une équipe, même pour une petite demande (découpage par rôles : réalisateur, testeur, documentation, contre-vérification) ; messages directs entre ouvriers (`@B : …`) ; toutes les permissions accordées d'avance aux ouvriers et aux Claude du profil Équipe (`bypassPermissions`) ; lancement automatique du plan sans risque après 20 s (`autoStart`).

- **Panneau « échanges »** dans le profil Équipe : ce que les Claude s'écrivent (messages directs, annonces, relectures, conseils), en direct, par compte ; journal `echanges.jsonl`.

### Corrigé
- Les ouvriers de l'équipe ne démarraient pas seuls : la consigne passait après `--add-dir` et était prise pour un dossier.
- Livraison, abandon et nettoyage ne détruisent plus de travail : sauvegarde des fichiers non commités, branches des tâches non intégrées conservées sous `refs/flow-archive/…`.
- Un conflit de fusion abandonné n'est plus compté comme « résolu » ; le commit de rattrapage d'un ouvrier est contrôlé.
- Le clic droit n'ouvre plus le menu « Agencer » au lancement (commande chaînée coupée par psmux).
- Les textes passés à PowerShell protègent aussi les apostrophes typographiques (injection possible par un titre de tâche).
- Les variables d'authentification héritées (clé d'API, jetons) sont retirées des panneaux : chaque compte utilise sa propre connexion.
- Écritures de fichiers d'état atomiques (profils, comptes, projets, état d'équipe).

## 1.0.0 — 13 novembre 2026
Première version publiée : profils psmux, moniteur, multi-comptes, équipe, Bureau animé, bibliothèques de profils partagés.
