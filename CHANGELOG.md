# Journal des changements

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
