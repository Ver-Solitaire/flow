# Journal des changements

## 1.5.0 — 14 novembre 2026

**Essayé avec** : PowerShell 7.7.0 · psmux 3.4.0 · Claude Code 2.1.318 · Git 2.56.0 · Pester 5.9.1.

### Installateur
- **FLOW-Setup-<version>.exe** (Inno Setup, installation par utilisateur, sans droits administrateur) : copie FLOW, puis lance `install.ps1` pour installer ce qui manque (winget) et créer le raccourci. Compilé par la CI. Pas encore essayé sur une machine vierge.

### Correctifs des tests
- `tests\run.ps1` n'écrase plus la variable `Cfg` quand la CI le lance par dot-sourcing ; `Wait-Jobs-Spinner` accepte un délai en minutes décimales.

### Banc de mesure de la qualité
- `pwsh -File tools\flow-bench.ps1 -Live` : 3 petites tâches fixes (`bench\taches.json`) confiées à un vrai Claude dans une copie jetable ; FLOW compte les vérifications automatiques réussies, le coût et la durée, et ajoute une ligne à `bench\resultats.jsonl`. Sans `-Live` : résumé des dernières mesures, avec les régressions signalées (▼). Coûte quelques centimes par tâche ; jamais lancé par les tests.

### Réglages d'équipe et parcours débutant (livraison 6)
- **Réglage d'équipe par passe** (`workflow.json`, clé `equipe`) : une étape « complète » est relue par un autre compte avant la fusion, une « légère » va plus vite sans relecture. **T** dans la feuille de route (F9) bascule le réglage de la passe de l'étape choisie ; il s'applique aux équipes liées à une étape.
- **Mode guidé activé par défaut** (public débutant) ; F7 le coupe, ton choix est retenu.
- **Écran de départ** : « Que veux-tu obtenir ? Écris-le avec tes mots » ; FLOW pose ses questions, découpe, répartit et montre le plan avant de partir.

### Tri du projet (livraison 5) — F10
- **Écran de tri (F10)** : FLOW examine la mémoire (`memoire\`), `CLAUDE.md`, le cahier, la feuille de route et les skills des comptes, et liste ce qui n'est pas sain : **références mortes** (fichier cité qui n'existe plus), **doublons** (identiques ou à 85 % des mots), **INDEX** incomplet ou avec liens morts, **fiches anciennes ou trop longues**, **cahier ≠ profil** (données protégées), **skills** en double, sans description, qui se chevauchent ou pas à jour, **conflits** notés par le scribe, candidats des hooks en retard.
- **Contradictions (C)** : Claude compare les affirmations deux à deux et propose les paires incompatibles ; un numéro inventé est écarté.
- **Rien n'est supprimé ni modifié sans ta validation** : chaque action archive d'abord le fichier dans `.flow\tri\archives\<date>\`, la modification d'un fichier de règles (`CLAUDE.md`, cahier) demande une confirmation de plus, « ignorer » n'est plus reproposé, tout est journalisé dans `.flow\tri\journal.md`. **M** traite en lot les doublons exacts (jamais `CLAUDE.md` ni le cahier).
- **Proposé quand c'est utile** : à l'accueil, s'il y a un point grave ou après 8 équipes livrées depuis le dernier tri (une fois par session ; « plus tard » = 7 jours, « ne plus proposer »).
- **Le scribe n'écrase plus une décision** : une information qui en contredit une est notée dans `memoire\conflits.md`, à trancher au prochain tri.

### Étapes de la feuille de route (livraison 4)
- **L (ou Entrée) dans l'écran F9 lance une étape** : conception, puis construction. La passe de l'étape (légère ou complète) règle la profondeur.
- **Passe de conception** (inspirée du workflow d'un gros projet) : le planificateur découpe la cartographie en 3 à 6 zones ; des lecteurs les explorent **en parallèle** (lecture seule, répartis sur tes comptes) ; une critique relève les manques et les contradictions ; la spec est écrite ; deux relectures (fidélité au cahier, faisabilité) la corrigent. En passe légère : un seul appel. Les vraies décisions te sont posées. Résultat : `.flow\workflow\etapes\<ÉTAPE>\spec.md` (§0 décisions de l'utilisateur qui font foi et choix par défaut « à confirmer », §1 ce qui existe, §2 lots aux fichiers disjoints, §3 tests, §4 vérifications en vrai, §5 risques) et `carte.md`.
- **Rien n'est construit sans ta validation de la spec** (Entrée = valider et construire, E modifier, R refaire, Échap plus tard).
- **Construction** : l'équipe habituelle, liée à l'étape : la spec est donnée au planificateur (ses lots deviennent les tâches), au brief des ouvriers et au juge ; la passe de l'étape est imposée au contrôle ; un point de retour Git est posé (`refs/flow-backup/<équipe>`).
- **Données protégées** : leur empreinte (SHA-256) est prise au lancement de l'équipe et recontrôlée à l'intégration (vérification « données protégées (contenu) »), même si ces données ne sont pas dans Git.
- **Enchaînement** : après une livraison qui termine l'étape, FLOW propose l'étape suivante, sauf si une vérification a échoué ou si le juge n'était pas convaincu.
- **Correction d'un défaut des versions 1.3.0 et 1.4.0** : après une première demande envoyée, l'accueil sautait la liste des équipes et préremplissait la zone de demande avec du texte parasite, et « presque : ajuster » ne repartait pas du travail précédent (une apostrophe isolée à la place de `''`). Un test et un garde-fou l'empêchent.
- Le garde-fou des variables étendu : une variable de boucle `$l` qui écrase la liste `$L` est maintenant détectée.

### Hooks de Claude Code (livraison 3)
- **Hooks installés par FLOW** dans `.claude\settings.local.json` du projet et de chaque copie de travail des ouvriers (proposés à la validation du workflow, **H** dans le profil). L'installation **fusionne** : tes autres réglages et hooks ne sont jamais touchés, seules les entrées de FLOW sont ajoutées ou retirées.
- **Protection réelle des chemins protégés** (`PreToolUse`) : l'écriture dans un chemin protégé du projet, ou une commande shell qui le modifie, est refusée **même en mode `bypassPermissions`** (vérifié avec un vrai Claude). Avant, ce n'était qu'une consigne.
- **Début de session** : la feuille de route, les règles décidées, les interdits et les pièges déjà rencontrés sont injectés dans le contexte de chaque Claude du projet.
- **Candidats** (`.flow\candidats\`) : les hooks repèrent décisions, interdictions et préférences dans tes messages, les fichiers modifiés sans mise à jour de `memoire\`, les refus et l'état avant compaction. Ils **ne modifient jamais** la mémoire : le scribe les reçoit dans sa consigne, puis ils sont archivés (rien n'est supprimé). Secrets masqués.
- Les hooks ne font jamais appel à Claude, ne bloquent jamais une session par erreur (toute erreur = on laisse faire) et coûtent environ 0,3 s par événement.

### Feuille de route vivante (livraison 2)
- **Écran « Feuille de route »** (**F9** depuis l'écran de demande) : barre d'avancement, étapes avec leur état, passe et équipes en cours, journal du projet. **S** change l'état de l'étape choisie, **P** sa passe, **E** ouvre le tableau, **J** lit le journal.
- **Une équipe est rattachée à une étape** : le planificateur voit la feuille de route et propose l'étape concernée ; **T** dans l'écran du plan la change. Au lancement du plan, l'étape passe « en cours » ; équipe abandonnée ou jetée, elle retrouve son état d'avant ; après une livraison, FLOW demande si l'étape est terminée (sans réponse explicite, elle reste en cours).
- **Journal du projet** (`.flow\workflow\journal.md`) : une ligne datée par événement (étape lancée, livrée, terminée, état changé à la main).
- **Aucune perte de données** : si `ROADMAP.md` contient une ligne que FLOW ne sait pas relire, il ne réécrit rien tant que ce n'est pas corrigé ; la version précédente est gardée dans `ROADMAP.md.bak`.
- L'écran de demande rappelle l'avancement (« 3/7 étapes faites · à poursuivre : E4 … »).

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
