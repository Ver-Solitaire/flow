# Journal des changements

## 1.1.0 — 13 novembre 2026

### Ajouté
- **Connexion des comptes au lancement** : un profil à plusieurs comptes propose de connecter ceux qui manquent, dans la même fenêtre ; ajout de comptes à volonté (touche C).
- **Équipe de Claude synchronisée** : tableau partagé, annonces relayées entre ouvriers, **relecture croisée** par un Claude d'un autre compte avant la fusion.
- **Skills** installés dans chaque compte : projet-creer, projet-reprendre, projet-maintenir, taches-repartir (+ `tools\flow-plan.ps1`, Ctrl+B T).
- **Application FLOW.exe** avec choix du projet ; raccourcis qui ne dépendent plus d'un chemin de Windows Terminal.
- **`FLOW.ps1 -Doctor`** : diagnostic (outils, comptes, fichiers, sessions, journal) ; journal `config\flow.log`.
- **Tests** (Pester 5, `tests\run.ps1`) et garde-fous contre les pièges PowerShell déjà rencontrés ; `VERSION`, `CLAUDE.md`.

- **Les comptes ne sont plus liés aux profils** : les profils « Équipe — multi-comptes » et « Un Claude par compte » ouvrent un Claude par compte connecté
  (`"perAccount": true`) ; bouton « ＋ Ajouter un Claude » (Ctrl+B A, clic droit) ; les Claude répartissent d'eux-mêmes ce qui se découpe.
- Écran des comptes à la sélection du projet (connexion, doublons d'adresse, retrait d'un compte) ; CLAUDE.md de départ créé pour n'importe quel projet.

- **Équipe autonome** : toujours une équipe, même pour une petite demande (découpage par rôles : réalisateur, testeur, documentation, contre-vérification) ; messages directs entre ouvriers (`@B : …`) ; mode `auto` pour les ouvriers ; lancement automatique du plan sans risque après 20 s (`autoStart`).

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
