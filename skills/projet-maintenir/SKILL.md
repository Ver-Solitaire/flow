---
name: projet-maintenir
description: Entretient un projet existant dans la durée, quel que soit son langage — mettre à jour les dépendances, corriger les failles de sécurité signalées, réparer des tests ou une intégration continue cassés, nettoyer le code mort, remettre la documentation et CLAUDE.md d'accord avec le code, préparer une nouvelle version (numéro, journal des changements, tag). À utiliser dès que l'utilisateur parle d'entretien ou de remise à niveau — « mets à jour le projet », « mets à jour les dépendances », « fais le ménage », « ça ne build plus », « remets ça au propre », « prépare une release », « vérifie que tout est à jour », « maintenance » — y compris quand il demande simplement si le projet est « en bon état ».
---

# Maintenir un projet

Entretenir, c'est garder un projet **qui marche** tout en le faisant bouger. Presque tous les
accidents de maintenance viennent du même enchaînement : trop de changements à la fois, pas de
point de comparaison, et on ne sait plus lequel a cassé quoi. Tout ce qui suit sert à éviter ça.

## 1. Partir d'un état connu

Avant de toucher à quoi que ce soit :

1. Lis `CLAUDE.md` et le README pour les commandes et les conventions du projet. S'il n'y a pas de
   `CLAUDE.md` ou si tu ne connais pas le projet, commence par le skill `projet-reprendre`.
2. `git status` : s'il y a du travail non enregistré, ne le mélange pas avec la maintenance —
   demande à l'utilisateur ce qu'il veut en faire.
3. Lance les tests et les vérifications **avant** tout changement et note le résultat. C'est ta
   référence : ce qui échouait déjà n'est pas causé par toi, ce qui passait doit encore passer.
4. Travaille sur une branche dédiée (`maintenance/…` ou selon la convention du projet) plutôt que
   sur la branche principale : tout reste annulable d'un geste.

## 2. Choisir quoi faire

Si l'utilisateur a demandé une chose précise, fais celle-là. S'il a demandé un entretien général,
fais d'abord un tour d'horizon rapide, présente ce que tu as trouvé classé par importance, et
laisse-le choisir (ou applique cet ordre, du plus urgent au moins urgent) :

1. **Ce qui est cassé** : tests ou build en échec, intégration continue rouge.
2. **Sécurité** : failles signalées dans les dépendances, secrets présents dans le dépôt.
3. **Dépendances en retard**.
4. **Ménage** : code mort, fichiers inutiles, avertissements.
5. **Documentation** : README, `CLAUDE.md`, commentaires qui ne disent plus la vérité.

Les commandes exactes pour chaque écosystème (npm, pnpm, Python, Rust, Go, .NET, PHP…) sont dans
`references/commandes.md` : lis la section du projet au moment où tu en as besoin.

## 3. La règle d'or : un changement, une vérification, un commit

Pour chaque chose que tu changes :

1. fais **un seul** changement cohérent (une dépendance, ou un groupe de dépendances liées ; un
   nettoyage ; une correction) ;
2. relance les tests et les vérifications ;
3. si tout passe, fais un commit avec un message qui dit quoi et pourquoi ;
4. si ça casse, tu sais exactement quoi : corrige, ou annule ce changement-là et note-le.

C'est plus lent que tout faire d'un coup, et c'est justement l'intérêt : chaque étape est sûre et
réversible, et l'historique raconte ce qui s'est passé.

## 4. Les travaux courants

### Mettre à jour les dépendances
- Liste d'abord ce qui est en retard, sans rien installer.
- **Correctifs et versions mineures** : en général sans risque ; fais-les par petits groupes.
- **Versions majeures** : une par une. Lis les notes de version (« breaking changes », guide de
  migration) avant, adapte le code, teste. Si une migration est lourde, ne la fais pas dans la
  foulée : décris-la et propose-la comme un travail à part.
- Mets toujours à jour le fichier de verrouillage (`package-lock.json`, `uv.lock`, `Cargo.lock`…)
  avec le reste : c'est lui qui garantit que tout le monde installe la même chose.
- Une dépendance abandonnée par ses auteurs se signale ; son remplacement est une décision à
  prendre avec l'utilisateur.

### Sécurité
- Lance l'audit de l'écosystème et traite d'abord ce qui est grave **et** réellement utilisé par le
  projet. Une alerte dans un outil de développement n'a pas le poids d'une alerte dans le code
  exposé aux utilisateurs : explique la différence plutôt que d'afficher un nombre brut.
- Évite les corrections automatiques forcées (`npm audit fix --force` et équivalents) : elles
  installent des versions majeures sans prévenir.
- Un secret trouvé dans le dépôt (clé, mot de passe, jeton) : dis-le tout de suite, sans recopier
  sa valeur. Le retirer du fichier ne suffit pas, il reste dans l'historique : il doit être révoqué
  et remplacé par l'utilisateur.

### Réparer des tests ou un build cassés
- Reproduis l'échec, lis le message jusqu'au bout, cherche la cause — ne modifie pas un test pour
  qu'il passe sans avoir compris pourquoi il échouait. Un test qui échoue a peut-être raison.
- Si un test est vraiment périmé, dis-le explicitement dans le commit.
- Ne désactive pas une vérification pour faire passer le reste, sauf accord, et alors laisse une
  note visible dans le code.

### Faire le ménage
- Avant de supprimer du code « mort », cherche tous ses usages, y compris par nom dans des
  chaînes, des fichiers de configuration ou des scripts. En cas de doute, ne supprime pas.
- Un nettoyage ne change pas le comportement : s'il faut aussi corriger quelque chose, c'est un
  autre commit.
- Ne reformate pas tout le projet au passage : ça noie les vrais changements dans l'historique.

### Remettre la documentation d'accord avec le code
- Rejoue les commandes du README et de `CLAUDE.md` ; corrige celles qui ne marchent plus.
- Mets à jour `CLAUDE.md` quand la maintenance a changé une commande, une convention ou une
  version d'outil : c'est ce que liront les prochaines sessions.

### Préparer une version
1. Tout est commité, les tests passent sur la branche à livrer.
2. Choisis le numéro selon ce qui a changé depuis la dernière version (versions sémantiques) :
   correctif → `x.y.Z`, nouveauté compatible → `x.Y.0`, changement qui casse l'usage → `X.0.0`.
3. Mets le numéro à jour partout où il figure (fichier du projet, éventuellement le code).
4. Rédige le journal des changements (`CHANGELOG.md`) à partir de `git log` depuis le dernier
   tag, regroupé par nature (ajouts, corrections, changements) et écrit pour un utilisateur, pas
   pour un développeur.
5. Commit, puis tag (`vX.Y.Z`).
6. **Arrête-toi là** : pousser, publier un paquet ou créer la release sur GitHub sont des actions
   visibles de l'extérieur et difficiles à défaire. Montre ce qui est prêt et attends l'accord.

## 5. Rendre compte

Termine par un bilan court et honnête :

- ce qui a été fait (une ligne par commit suffit) ;
- le résultat des tests avant et après ;
- ce que tu as volontairement laissé de côté et pourquoi (migration lourde, décision à prendre) ;
- ce qui reste à surveiller ;
- comment tout annuler si besoin (la branche, ou les commits concernés).

Si une vérification n'a pas pu être faite, dis-le : « non vérifié » est une information utile,
« ça devrait marcher » ne l'est pas.

## Garde-fous

- Rien de visible de l'extérieur sans accord explicite : pas de `git push`, de publication, de
  déploiement, de fermeture de tickets.
- Pas de réécriture de l'historique partagé (`push --force`, `rebase` d'une branche publiée).
- Pas de suppression de fichiers non suivis par Git sans les avoir regardés : ils n'ont pas de copie.
- Une migration de base de données ou de données se prépare et se montre avant de s'exécuter, et
  jamais sur des données réelles sans sauvegarde confirmée.
