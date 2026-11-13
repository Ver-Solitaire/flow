---
name: projet-reprendre
description: Prend en main un projet existant que l'on ne connaît pas (ou plus) — le comprendre, vérifier qu'il tourne, écrire ou remettre à jour sa mémoire (CLAUDE.md, README) et dresser l'état des lieux de ce qui va et ne va pas. À utiliser dès que l'utilisateur ouvre un projet déjà commencé et veut s'y retrouver — « explique-moi ce projet », « je reprends ce code », « c'est quoi l'état de ce dépôt », « on m'a donné ce projet », « fais le point », « audit », « par où commencer » — ou avant tout travail important dans un projet qui n'a pas de CLAUDE.md.
---

# Reprendre un projet existant

Le but : passer de « un dossier plein de fichiers » à « je sais ce que c'est, comment le lancer,
dans quel état il est, et c'est écrit pour la prochaine fois ». On observe d'abord, on ne modifie
le code qu'ensuite et avec accord : un projet qu'on ne comprend pas encore se casse facilement.

## 1. Explorer sans rien changer

Lis, dans cet ordre, en t'arrêtant dès que tu as compris l'essentiel :

1. `README`, `CLAUDE.md`, `CONTRIBUTING`, dossier `docs/` — ce que les auteurs ont voulu dire.
2. Les fichiers qui décrivent le projet : `package.json`, `pyproject.toml`, `Cargo.toml`,
   `go.mod`, `*.csproj`, `Makefile`, `docker-compose.yml`… Ils donnent le langage, les
   dépendances et les commandes prévues.
3. L'arborescence (deux niveaux suffisent) et les points d'entrée : le fichier lancé en premier,
   les routes, les commandes.
4. L'historique : `git log --oneline -30`, `git status`, les branches. Il dit si le projet est
   vivant, qui y travaille, quel style de commit est utilisé, et s'il y a du travail en cours non
   enregistré — à signaler tout de suite à l'utilisateur, sans y toucher.
5. L'automatisation : `.github/workflows/` ou autre intégration continue, scripts, hooks. C'est la
   description la plus fiable de « comment on vérifie ce projet ».
6. Les tests : où ils sont, ce qu'ils couvrent en gros.

Ne lis pas tout le code : cherche la forme générale, puis approfondis seulement les parties
centrales ou surprenantes.

## 2. Le faire tourner

Comprendre sur le papier ne suffit pas. Dans la mesure du possible :

- installe les dépendances avec la commande du projet (celle du README ou de la CI) ;
- lance les tests et note le résultat exact : combien passent, combien échouent, lesquels ;
- lance le projet et regarde s'il démarre.

C'est le **point de référence** : tout ce qui échoue déjà maintenant n'est pas de ta faute plus
tard, et tout ce qui passe doit continuer à passer. Si le projet demande des secrets, une base de
données ou un service que tu n'as pas, ne les invente pas : note ce qui manque et demande.

N'exécute pas à l'aveugle un script qui supprime, déploie, migre une base ou envoie quelque chose :
lis-le d'abord.

## 3. Écrire la mémoire du projet

Crée `CLAUDE.md` s'il n'existe pas, sinon complète-le sans effacer ce que les auteurs y ont mis.
Il sera lu par chaque Claude qui ouvrira ce projet (y compris chaque ouvrier d'une équipe FLOW) :

```markdown
# Nom du projet

But en deux lignes.

## Commandes
Installer · lancer · tester · vérifier (lint, types) · construire — les commandes exactes, vérifiées.

## Organisation
Les dossiers principaux et ce que chacun contient ; où ajouter une fonctionnalité, un test.

## Conventions
Style, nommage, langue des commits et des commentaires, façon de livrer (branches, pull requests).

## À savoir
Pièges, parties fragiles, décisions surprenantes et leur raison, ce qui est en chantier.
```

N'y écris que ce que tu as constaté. Une commande non vérifiée se marque « (non vérifiée) » :
une mémoire fausse est pire que pas de mémoire.

Si le README est absent ou trompeur (commandes qui ne marchent plus), propose sa mise à jour.

## 4. Rendre l'état des lieux

Réponds à l'utilisateur dans le fil de la conversation, en langage courant, sans jargon inutile :

- **Ce que c'est** : à quoi sert le projet, avec quoi il est fait, sa taille.
- **Son état** : il démarre ou non, résultat des tests, date de la dernière activité.
- **Ce qui pose problème**, du plus grave au moins grave. Pour chaque point : ce que c'est, ce que
  ça risque de provoquer, et l'effort pour le corriger (petit / moyen / gros). Regarde notamment :
  secrets présents dans le dépôt, dépendances très anciennes ou abandonnées, absence de tests sur
  les parties centrales, code mort ou dupliqué, documentation fausse, travail non commité.
- **Ce que tu proposes de faire ensuite**, dans l'ordre.

Un secret trouvé dans le dépôt (clé d'API, mot de passe) se signale en premier, sans recopier sa
valeur : il faudra le révoquer, pas seulement l'effacer.

## 5. S'arrêter là, sauf accord

L'état des lieux est le livrable. Ne commence pas les corrections de ta propre initiative : c'est à
l'utilisateur de choisir quoi traiter. S'il te demande ensuite d'entretenir ou de remettre le
projet à niveau, le skill `projet-maintenir` décrit comment procéder par petites étapes sûres.

Seule exception : `CLAUDE.md` (et le README si l'utilisateur est d'accord), que tu peux écrire
tout de suite — sans commiter à sa place sauf s'il le demande.
